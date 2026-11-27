import BeepbarCore
import CryptoKit
import Darwin
import Foundation
import MachO

struct TerminalResponse: Codable, Sendable {
    static let schemaVersion = 1
    let exitCode: Int32
    let json: Data

    static func failure(code: String, message: String, exitCode: Int32) -> Self {
        let data = (try? JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "error": ["code": code, "message": message]])) ?? Data("{}".utf8)
        return Self(exitCode: exitCode, json: data)
    }
}

private enum TerminalWire {
    static let limit = 1_048_576

    // Bundle.main can infer a different directory when a PATH symlink starts the executable.
    // Resolve the executable first so the CLI and the GUI select the same endpoint and bundle.
    static func appBundleURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        let executable = path.withUnsafeBufferPointer { bytes in
            let filename = FileManager.default.string(withFileSystemRepresentation: bytes.baseAddress!, length: strlen(bytes.baseAddress!))
            return URL(fileURLWithPath: filename).resolvingSymlinksInPath()
        }
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension.lowercased() == "app" else {
            return nil
        }
        return app
    }

    // Scope the endpoint to this bundle so a development build cannot control the installed app.
    static func paths() -> (String, String)? {
        guard let bundle = appBundleURL() else { return nil }
        let hash = SHA256.hash(data: Data(bundle.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let dir = "/tmp/beepbar-\(getuid())-\(hash)"
        if mkdir(dir, 0o700) != 0 && errno != EEXIST { return nil }
        var info = stat()
        guard lstat(dir, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                    info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { return nil }
        return (dir + "/socket", dir + "/lock")
    }

    static func address(_ path: String) -> sockaddr_un? {
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: result.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &result.sun_path) { $0.copyBytes(from: bytes) }
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return result
    }

    static func configure(_ fd: Int32) -> Bool {
        var flag: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout.size(ofValue: flag))) == 0
            && fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            && fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func transfer(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int, writing: Bool, deadline: UInt64) -> Bool {
        var offset = 0
        var pollFD = pollfd(fd: fd, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
        while offset < count {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = (deadline - now + 999_999) / 1_000_000
            let ready = poll(&pollFD, 1, Int32(clamping: remaining))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return false }
            let n = writing ? Darwin.write(fd, buffer.advanced(by: offset), count - offset)
                                            : Darwin.read(fd, buffer.advanced(by: offset), count - offset)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    static func send(_ fd: Int32, _ data: Data) -> Bool {
        guard data.count <= limit else { return false }
        let deadline = (DispatchTime.now() + .seconds(5)).uptimeNanoseconds
        var size = UInt32(data.count).bigEndian
        guard withUnsafeMutableBytes(of: &size, { transfer(fd, $0.baseAddress!, $0.count, writing: true, deadline: deadline) }) else { return false }
        var bytes = data
        return bytes.withUnsafeMutableBytes {
            $0.isEmpty || transfer(fd, $0.baseAddress!, $0.count, writing: true, deadline: deadline)
        }
    }

    static func receive(_ fd: Int32, limit: Int, timeout: Int) -> Data? {
        let deadline = (DispatchTime.now() + .seconds(timeout)).uptimeNanoseconds
        var size: UInt32 = 0
        guard withUnsafeMutableBytes(of: &size, { transfer(fd, $0.baseAddress!, $0.count, writing: false, deadline: deadline) }) else { return nil }
        let count = Int(UInt32(bigEndian: size))
        guard (1...limit).contains(count) else { return nil }
        var data = Data(count: count)
        return data.withUnsafeMutableBytes { transfer(fd, $0.baseAddress!, $0.count, writing: false, deadline: deadline) } ? data : nil
    }

    static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard configure(fd) else { close(fd); return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, sameUser(fd) else { close(fd); return nil }
        return fd
    }
}

@MainActor final class TerminalServer {
    private let state: State

    private final class State: @unchecked Sendable {
        let listener: Int32
        let lock: Int32
        let path: String
        let handler: @MainActor @Sendable ([String]) async -> TerminalResponse
        let source: any DispatchSourceRead
        let slots = DispatchSemaphore(value: 16)
        let mutex = NSLock()
        var stopped = false

        init(listener: Int32, lock: Int32, path: String, handler: @escaping @MainActor @Sendable ([String]) async -> TerminalResponse) {
            self.listener = listener
            self.lock = lock
            self.path = path
            self.handler = handler
            self.source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "BeepBar terminal listener"))
        }

        func stop() {
            mutex.lock()
            defer { mutex.unlock() }
            guard !stopped else { return }
            stopped = true
            source.cancel()
            unlink(path)
            flock(lock, LOCK_UN)
            close(lock)
        }

        func start() {
            source.setEventHandler { [weak self] in self?.acceptClients() }
            let fd = listener
            source.setCancelHandler { close(fd) }
            source.activate()
        }

        private func acceptClients() {
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard slots.wait(timeout: .now()) == .success else { close(fd); continue }
                guard TerminalWire.configure(fd) else { close(fd); slots.signal(); continue }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    guard TerminalWire.sameUser(fd), let data = TerminalWire.receive(fd, limit: 16_384, timeout: 5),
                                let arguments = try? JSONDecoder().decode([String].self, from: data),
                                arguments.count <= 16 else {
                        close(fd)
                        slots.signal()
                        return
                    }
                    Task { @MainActor [handler, slots] in
                        let response = await handler(arguments)
                        DispatchQueue.global(qos: .userInitiated).async {
                            defer { close(fd); slots.signal() }
                            let fallback = TerminalResponse.failure(code: "response_too_large", message: tr("Richiedi una pagina più piccola.", "Request a smaller page."), exitCode: 1)
                            guard let encoded = try? JSONEncoder().encode(response) else { return }
                            if encoded.count <= TerminalWire.limit { _ = TerminalWire.send(fd, encoded) }
                            else if let error = try? JSONEncoder().encode(fallback) { _ = TerminalWire.send(fd, error) }
                        }
                    }
                }
            }
        }
    }

    init?(handler: @escaping @MainActor @Sendable ([String]) async -> TerminalResponse) {
        guard let (path, lockPath) = TerminalWire.paths(), var address = TerminalWire.address(path) else { return nil }
        let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { return nil }
        guard fcntl(lock, F_SETFD, FD_CLOEXEC) == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lock); return nil }
        guard TerminalWire.configure(fd) else { close(fd); close(lock); return nil }
        unlink(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd); unlink(path); close(lock); return nil
        }
        let state = State(listener: fd, lock: lock, path: path, handler: handler)
        self.state = state
        state.start()
    }

    func stop() { state.stop() }
    deinit { state.stop() }
}

enum TerminalClient {
    static func run(arguments: [String]) -> Int32 {
        AppLanguage.current = AppLanguage.preferred(from: Locale.preferredLanguages)
        func fail(_ message: String) -> Int32 {
            let response = TerminalResponse.failure(code: "transport_error", message: message, exitCode: 1)
            FileHandle.standardOutput.write(response.json + Data([10]))
            return response.exitCode
        }
        guard let bundle = TerminalWire.appBundleURL(), let (path, _) = TerminalWire.paths(),
              let request = try? JSONEncoder().encode(arguments), request.count <= 16_384 else {
            return fail(tr("Impossibile preparare la richiesta da Terminale", "Cannot prepare terminal request"))
        }
        var fd = TerminalWire.connect(path)
        if fd == nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-gj", bundle.path, "--args", "--terminal-launch"]
            do { try process.run() } catch { return fail(tr("Impossibile avviare BeepBar", "Cannot launch BeepBar")) }
            let deadline = DispatchTime.now() + .seconds(15)
            while fd == nil && DispatchTime.now() < deadline {
                if !process.isRunning && process.terminationStatus != 0 { return fail(tr("Impossibile avviare BeepBar", "Cannot launch BeepBar")) }
                Thread.sleep(forTimeInterval: 0.1)
                fd = TerminalWire.connect(path)
            }
        }
        guard let fd else { return fail(tr("BeepBar non è diventata disponibile", "BeepBar did not become available")) }
        defer { close(fd) }
        // Once bytes may have been sent, retrying could execute a mutation twice.
        let timeout = arguments.first == "sync" && arguments.contains("--wait") ? 3_600 : 60
        guard TerminalWire.send(fd, request), let data = TerminalWire.receive(fd, limit: TerminalWire.limit, timeout: timeout),
                    let response = try? JSONDecoder().decode(TerminalResponse.self, from: data) else {
            return fail(tr("BeepBar non ha risposto. La richiesta potrebbe essere stata eseguita", "BeepBar did not return a response; the request may have executed"))
        }
        FileHandle.standardOutput.write(response.json + Data([10]))
        return response.exitCode
    }
}
