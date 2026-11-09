import AppKit
import CryptoKit
import BeepbarCore
import OSLog

/// Where one lecture's enhanced copy stands, as the player's menu shows it.
enum AudioEnhancementState: Equatable, Sendable {
    /// No ffmpeg where package managers install it: the menu says how to get it.
    case needsFFmpeg
    /// Nothing made yet for this lecture.
    case idle
    /// ffmpeg is reading the stream; `fraction` is nil while the length is unknown.
    case processing(fraction: Double?)
    /// The copy is ready; `inUse` says whether the player is playing it now.
    case ready(inUse: Bool)
    /// The last attempt failed (ffmpeg's exit status, a missing audio track, the disk): the menu
    /// offers to try again. The message is already bilingual.
    case failed(BilingualText)
}

/// What the player's Audio menu shows for one state: pure, so tests check every state's text
/// and action without a window.
struct AudioMenuPresentation: Equatable {
    struct Item: Equatable {
        let title: String
        /// nil: shown disabled.
        let action: PlayerAudioAction?
        var checked = false
    }
    let main: Item
    /// A second line: "Annulla" while a copy is made, why the last attempt failed; nil for none.
    let detail: Item?
}

extension RecordingPlayerPolicy {
    /// The Audio menu for `state`, in the current language; nil hides the section.
    static func audioMenu(_ state: AudioEnhancementState?) -> AudioMenuPresentation? {
        guard let state else { return nil }
        switch state {
        case .needsFFmpeg:
            return AudioMenuPresentation(main: .init(title: tr("Audio migliorato: installa ffmpeg (brew install ffmpeg)", "Enhanced audio: install ffmpeg (brew install ffmpeg)"), action: nil), detail: nil)
        case .idle:
            return AudioMenuPresentation(main: .init(title: tr("Crea versione con audio migliorato", "Create an enhanced-audio version"), action: .create), detail: nil)
        case .processing(let fraction):
            let title = fraction.map { tr("Creazione audio migliorato… \(Int($0 * 100))%", "Creating enhanced audio… \(Int($0 * 100))%") }
                ?? tr("Creazione audio migliorato…", "Creating enhanced audio…")
            return AudioMenuPresentation(main: .init(title: title, action: nil), detail: .init(title: tr("Annulla", "Cancel"), action: .cancel))
        case .ready(let inUse):
            return AudioMenuPresentation(main: .init(title: tr("Audio migliorato", "Enhanced audio"), action: .useEnhanced(!inUse), checked: inUse), detail: nil)
        case .failed(let message):
            return AudioMenuPresentation(main: .init(title: tr("Riprova a creare l'audio migliorato", "Try creating the enhanced audio again"), action: .create),
                                         detail: .init(title: message.text, action: nil))
        }
    }
}

/// Runs the student's ffmpeg to make enhanced copies of lectures (`AudioEnhancement`), one at a
/// time, in BeepBar's Caches folder, and knows which copies exist.
///
/// Lifetime: created on first use (a lecture opening in the player), never at launch, and idle
/// unless the student asked for a copy: no timer, no folder scan until then. Cancelled jobs and
/// failures leave no partial copy behind; one left by a quit or a crash is removed before the
/// next job (`AudioEnhancement.evictions`).
///
/// Identity: a copy's file name is a hash of the WeBeep account and the lecture's identity
/// (`RecordingsStudyState.identity`), so another account never finds it, and nothing in the
/// name says which lecture it is. "Forget this account's study data" deletes them all
/// (`removeAll`).
///
/// Quit: ffmpeg is a child process, which would outlive BeepBar. While one runs, a
/// `willTerminateNotification` observer sends it SIGTERM synchronously, a single syscall, with
/// no file or main-actor work (the hard rules on quitting). Nothing is added to
/// `applicationShouldTerminate` or to `prepareForMenuQuit`.
@MainActor final class AudioEnhancer {
    private static let log = Logger(subsystem: "io.github.tvaccari.beepbar", category: "AudioEnhancer")

    /// Called on the main actor whenever a lecture's state changes, with its key (`copyKey`).
    var onChange: ((String) -> Void)?

    private let locateFFmpeg: () -> URL?
    private let directory: () -> URL
    private let fileManager: FileManager
    private let makeProcess: () -> Process
    private let resolveInput: @Sendable (URL) async -> URL

    /// A copy underway. It first finds what ffmpeg should read (`resolving`, a short playlist
    /// fetch, `process` still nil), then runs ffmpeg (`process` set, `resolving` nil).
    private struct Job {
        let key: String
        var process: Process?
        var resolving: Task<Void, Never>?
        let partial: URL
        let final: URL
        let duration: TimeInterval?
        var fraction: Double?
        var cancelled = false
        var terminationObserver: NSObjectProtocol?
    }
    private var job: Job?
    /// The last failure per key, until the next attempt.
    private var failures: [String: BilingualText] = [:]

    init(locateFFmpeg: @escaping () -> URL? = { AudioEnhancement.locateFFmpeg() },
         directory: @escaping () -> URL = AudioEnhancer.defaultDirectory,
         fileManager: FileManager = .default,
         makeProcess: @escaping () -> Process = { Process() },
         resolveInput: @escaping @Sendable (URL) async -> URL = AudioEnhancer.resolveInput) {
        self.locateFFmpeg = locateFFmpeg
        self.directory = directory
        self.fileManager = fileManager
        self.makeProcess = makeProcess
        self.resolveInput = resolveInput
    }

    /// What ffmpeg reads for `stream`: the single file behind a byte-range playlist
    /// (`AudioEnhancement.singleMediaFile`, the Webex case), otherwise the playlist itself. Any
    /// failure here (network, an unexpected answer) falls back to the playlist, which is what
    /// ffmpeg read before: this step can make a copy faster, never fail one.
    ///
    /// Bounded: an ephemeral session (no cookies or cache written), 15 s, at most 4 MB of
    /// playlist (a 2.5-hour lecture's is about 40 KB). The address is never logged.
    nonisolated static func resolveInput(_ stream: URL) async -> URL {
        guard stream.scheme == "https" else { return stream }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let limit = 4 * 1024 * 1024
        guard let (bytes, response) = try? await session.bytes(from: stream),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(limit) else { return stream }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return stream }
            }
        } catch { return stream }
        guard let text = String(data: data, encoding: .utf8) else { return stream }
        return AudioEnhancement.singleMediaFile(playlist: text, at: response.url ?? stream) ?? stream
    }

    /// `~/Library/Caches/<bundle id>/EnhancedAudio`: a cache, since every copy can be made again
    /// from the stream, and excluded from backups by macOS.
    nonisolated static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // No fallback to BeepBar's own id: an unbundled process (a test runner) must never reach the
        // installed app's copies.
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Beepbar-unbundled", isDirectory: true)
            .appendingPathComponent("EnhancedAudio", isDirectory: true)
    }

    /// The name a lecture's copy goes under, for `owner`'s account: a hash, so the folder doesn't
    /// list what the student watches, and another account's lecture never matches.
    nonisolated static func copyKey(owner: Int, identity: String) -> String {
        let digest = SHA256.hash(data: Data("\(owner)\u{0}\(identity)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func finalURL(_ key: String) -> URL { directory().appendingPathComponent(key + AudioEnhancement.copySuffix) }

    /// The finished copy for `key`, or nil.
    func copy(for key: String) -> URL? {
        let url = finalURL(key)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// What the menu shows for `key`; `inUse` is the caller's (it knows what the player plays).
    func state(for key: String, inUse: Bool) -> AudioEnhancementState {
        if let job, job.key == key { return .processing(fraction: job.fraction) }
        if copy(for: key) != nil { return .ready(inUse: inUse) }
        if let failure = failures[key] { return .failed(failure) }
        return locateFFmpeg() == nil ? .needsFFmpeg : .idle
    }

    var isRunning: Bool { job != nil }

    /// Starts making `key`'s copy from `stream`, replacing a job for another lecture (only one
    /// at a time: each reads a whole stream). Does nothing when that copy exists or is underway.
    func start(key: String, stream: URL, duration: TimeInterval?) {
        if job?.key == key || copy(for: key) != nil { return }
        cancel()
        failures[key] = nil
        guard let ffmpeg = locateFFmpeg() else {
            onChange?(key)
            return
        }
        let folder = directory()
        let partial = folder.appendingPathComponent(key + AudioEnhancement.partialSuffix)
        let final = finalURL(key)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            evict(keeping: [key + AudioEnhancement.copySuffix])
        } catch {
            fail(key, BilingualText("Non è stato possibile preparare la cartella per l'audio migliorato.", "Couldn't prepare the folder for enhanced audio."))
            return
        }
        let resolving = Task { @MainActor [weak self, resolveInput] in
            let input = await resolveInput(stream)
            guard !Task.isCancelled else { return }
            self?.launch(key: key, ffmpeg: ffmpeg, input: input)
        }
        job = Job(key: key, process: nil, resolving: resolving, partial: partial, final: final, duration: duration, fraction: duration == nil ? nil : 0)
        Self.log.notice("Enhanced audio started")
        onChange?(key)
    }

    /// Second step of `start`: runs ffmpeg on `input` for the job still waiting on it.
    private func launch(key: String, ffmpeg: URL, input: URL) {
        guard var current = job, current.key == key, current.process == nil, !current.cancelled else { return }
        current.resolving = nil
        let partial = current.partial
        let process = makeProcess()
        process.executableURL = ffmpeg
        process.arguments = AudioEnhancement.arguments(input: input, output: partial)
        process.standardInput = FileHandle.nullDevice
        // stderr is discarded on purpose: ffmpeg's errors repeat the input address, which carries
        // the student's sign-in. Only the exit status is kept.
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                handle.readabilityHandler = nil
                return
            }
            let seconds = text.split(whereSeparator: \.isNewline).compactMap { AudioEnhancement.progressSeconds(line: String($0)) }.last
            guard let seconds else { return }
            Task { @MainActor [weak self] in self?.progressed(key: key, seconds: seconds) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor [weak self] in self?.finished(key: key, status: status, reason: reason) }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            job = nil
            fail(key, BilingualText("Non è stato possibile avviare ffmpeg.", "Couldn't start ffmpeg."))
            return
        }
        let pid = process.processIdentifier
        // Synchronous on the posting thread (queue nil): one kill, nothing else.
        current.terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            kill(pid, SIGTERM)
        }
        current.process = process
        job = current
    }

    /// Stops the running job, if any; its partial file is removed when ffmpeg has exited.
    func cancel() {
        guard var current = job, !current.cancelled else { return }
        guard let process = current.process else {
            // Still finding the input: nothing written yet, so the job just ends here.
            current.resolving?.cancel()
            job = nil
            onChange?(current.key)
            return
        }
        current.cancelled = true
        job = current
        process.terminate()
    }

    /// Cancels the job and deletes every copy: "Forget this account's study data", or the
    /// account going away.
    func removeAll() {
        if let current = job {
            current.resolving?.cancel()
            if let observer = current.terminationObserver { NotificationCenter.default.removeObserver(observer) }
            current.process?.terminationHandler = nil
            (current.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            current.process?.terminate()
            job = nil
            onChange?(current.key)
        }
        failures.removeAll()
        try? fileManager.removeItem(at: directory())
    }

    /// Deletes `key`'s finished copy: it failed to play, so it is made again only on request.
    func discard(_ key: String) {
        try? fileManager.removeItem(at: finalURL(key))
        onChange?(key)
    }

    /// Marks `key`'s copy as just used, so eviction keeps it longest.
    func touch(_ key: String) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL(key).path)
    }

    private func progressed(key: String, seconds: TimeInterval) {
        guard var current = job, current.key == key, !current.cancelled else { return }
        let fraction = AudioEnhancement.fraction(written: seconds, duration: current.duration)
        // A redraw of the menu per whole percent at most.
        if let old = current.fraction, let fraction, Int(old * 100) == Int(fraction * 100) { return }
        current.fraction = fraction
        job = current
        onChange?(key)
    }

    private func finished(key: String, status: Int32, reason: Process.TerminationReason) {
        guard let current = job, current.key == key else { return }
        job = nil
        if let observer = current.terminationObserver { NotificationCenter.default.removeObserver(observer) }
        (current.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if current.cancelled || reason != .exit || status != 0 {
            try? fileManager.removeItem(at: current.partial)
            if !current.cancelled {
                Self.log.notice("Enhanced audio failed status=\(status, privacy: .public) reason=\(reason == .exit ? "exit" : "signal", privacy: .public)")
                failures[key] = BilingualText("ffmpeg non è riuscito a creare l'audio migliorato. Riprova più tardi.", "ffmpeg couldn't create the enhanced audio. Try again later.")
            }
            onChange?(key)
            return
        }
        do {
            // Atomic: the copy appears whole or not at all.
            if fileManager.fileExists(atPath: current.final.path) { try fileManager.removeItem(at: current.final) }
            try fileManager.moveItem(at: current.partial, to: current.final)
            Self.log.notice("Enhanced audio ready")
        } catch {
            try? fileManager.removeItem(at: current.partial)
            failures[key] = BilingualText("Non è stato possibile salvare l'audio migliorato.", "Couldn't save the enhanced audio.")
        }
        onChange?(key)
    }

    private func fail(_ key: String, _ message: BilingualText) {
        failures[key] = message
        onChange?(key)
    }

    /// Leftover partial files and the least recently used copies beyond the limit.
    private func evict(keeping: Set<String>) {
        let folder = directory()
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        let files = names.map { name in
            let date = (try? fileManager.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
            return AudioEnhancement.CachedCopy(name: name, lastUsed: date)
        }
        for name in AudioEnhancement.evictions(files, keeping: keeping) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
