import Foundation

// "Audio migliorato": a copy of a lecture with cleaner, steadier speech, made by the student's
// own ffmpeg (Homebrew or MacPorts), on request, one lecture at a time.
//
// Why a copy and not a live filter: the lecture is an HLS stream, and AVFoundation never hands an
// HLS item's audio to an `MTAudioProcessingTap` (probed on macOS 27 on 2026-11-09 against Apple's
// public HLS sample: the tap was attached and received 0 frames while the item played), so there
// is no native way to filter what AVPlayer plays. ffmpeg reads the stream once, copies the video
// as is and re-encodes only the audio through `filterChain`; the player then switches between the
// stream and the copy at the same position, in either direction, whenever the student chooses.
//
// ffmpeg isn't bundled (licence, size and signing of a third-party binary): BeepBar only looks for
// it where package managers install it, and says how to get it when it isn't there.
//
// Everything here is pure, so Swift Testing covers it without running ffmpeg.

public enum AudioEnhancement {
    /// Where Homebrew (Apple silicon, Intel) and MacPorts install ffmpeg, in that order. A fixed
    /// list on purpose: never `PATH`, which an app launched from Finder doesn't inherit anyway and
    /// which would let any directory shadow the binary.
    public static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    /// The first candidate that is an executable file, or nil.
    public static func locateFFmpeg(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        ffmpegCandidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// The audio filters, in order, for a lecture recorded by a room microphone:
    /// - `highpass` / `lowpass`: cut rumble (ventilation, desk knocks, mains hum) below 80 Hz and
    ///   hiss above 12 kHz, outside the voice;
    /// - `afftdn`: spectral noise reduction that follows the room's steady noise (`tn`), mild
    ///   (12 dB) so the voice doesn't turn metallic;
    /// - `equalizer` ×2: −2 dB around 250 Hz (the boom of a lecture hall) and +3 dB around
    ///   3 kHz, where consonants make speech intelligible;
    /// - `dynaudnorm`: evens out the volume over a few seconds, so a teacher walking away from the
    ///   microphone stays as loud as one next to it, without pumping on pauses;
    /// - a second, gentler `afftdn`: the normalizer also raises the room noise in the pauses, and
    ///   this pass removes it there;
    /// - `alimiter`: keeps the boosted peaks from clipping.
    ///
    /// Chosen on 2026-11-09 with ffmpeg 9.0.2 against synthetic speech (macOS `say`) mixed with
    /// brown noise and 50 Hz hum, a quiet and a loud half: against the single-pass chain it
    /// replaced, the same speed (~70x real time on an M2) and quiet/loud balance (−17.6/−16.5
    /// LUFS from −27.4/−15.7), with the noise floor in the pauses far lower and clean speech's
    /// level unchanged. Rejected there: `loudnorm` with a stronger normalizer (pauses got
    /// noisier), a gate (no better than the second pass), `anlmdn` (3x slower, no gain),
    /// `arnndn` (needs a model file ffmpeg doesn't ship).
    public static let filterChain = "highpass=f=80,lowpass=f=12000,afftdn=nr=12:nf=-40:tn=1,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3,dynaudnorm=f=250:g=15:p=0.9:m=12,afftdn=nr=8:nf=-45:tn=1,alimiter=limit=0.95"

    /// The protocols ffmpeg may open while reading the stream: the network ones HLS over https
    /// needs. Not `file`, so a playlist can't make ffmpeg read a local file into the copy.
    public static let protocolWhitelist = "https,tls,tcp,crypto"

    /// ffmpeg's command line, without the executable. `input` is the stream (short-lived, tied to
    /// the student's sign-in: never logged); `output` the partial file, renamed by the caller only
    /// after a clean exit. Progress goes to stdout as `key=value` lines (`progressSeconds`);
    /// stdin is closed so ffmpeg never waits for a key.
    public static func arguments(input: URL, output: URL) -> [String] {
        [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-protocol_whitelist", protocolWhitelist,
            "-i", input.absoluteString,
            // The first video track if there is one (a voice-only recording has none), and the
            // first audio track, which must exist.
            "-map", "0:v:0?", "-map", "0:a:0",
            "-c:v", "copy",
            "-af", filterChain,
            // 192 kb/s at 48 kHz: the filtered audio is encoded once more, so it gets a rate well
            // above the stream's own (typically 64–128 kb/s), which keeps that generation
            // inaudible. ffmpeg's own AAC encoder, present in every build.
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            "-f", "mp4", "-y", output.path,
        ]
    }

    /// The media time ffmpeg has written, in seconds, from one `-progress` line, or nil for any
    /// other line. ffmpeg writes `out_time_us` and, under a misleading name, `out_time_ms`, both
    /// in microseconds; `N/A` (before the first packet) is nil.
    public static func progressSeconds(line: String) -> TimeInterval? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "out_time_us" || parts[0] == "out_time_ms", let micros = Int64(parts[1]), micros >= 0 else { return nil }
        return TimeInterval(micros) / 1_000_000
    }

    /// The fraction done, 0…1, or nil when the lecture's length is unknown.
    public static func fraction(written: TimeInterval, duration: TimeInterval?) -> Double? {
        guard let duration, duration > 0, duration.isFinite else { return nil }
        return min(max(written / duration, 0), 1)
    }

    /// How many enhanced copies are kept. A lecture's copy is about the size of the stream (the
    /// video is copied): a few hundred megabytes. The oldest-used beyond this go first.
    public static let keptCopies = 3

    /// One file in the copies' folder.
    public struct CachedCopy: Equatable, Sendable {
        public let name: String
        public let lastUsed: Date
        public init(name: String, lastUsed: Date) {
            self.name = name
            self.lastUsed = lastUsed
        }
    }

    /// The files to delete before a new copy is started, so the folder never holds more than
    /// `keptCopies` finished copies including the new one: every leftover partial file (a quit or
    /// a crash mid-way), then the least recently used copies. `keeping` (the lecture being
    /// enhanced, or playing) is never chosen.
    public static func evictions(_ files: [CachedCopy], keeping: Set<String> = [], limit: Int = keptCopies) -> [String] {
        let partials = files.filter { $0.name.hasSuffix(partialSuffix) && !keeping.contains($0.name) }.map(\.name)
        let finished = files.filter { $0.name.hasSuffix(copySuffix) && !$0.name.hasSuffix(partialSuffix) }
        let kept = finished.filter { keeping.contains($0.name) }
        let candidates = finished.filter { !keeping.contains($0.name) }.sorted { $0.lastUsed > $1.lastUsed }
        let room = max(limit - 1 - kept.count, 0)
        return partials + candidates.dropFirst(room).map(\.name)
    }

    public static let copySuffix = ".mp4"
    public static let partialSuffix = ".partial.mp4"
}
