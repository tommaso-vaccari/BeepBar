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

    /// The audio filters, in order, for a lecture recorded in a university classroom (one teacher,
    /// a room microphone, students talking in the background):
    /// - `highpass` / `lowpass`: cut rumble (ventilation, desk knocks, mains hum) below 90 Hz and
    ///   hiss above 10 kHz, outside the voice;
    /// - `afftdn`: spectral noise reduction that follows the room's steady noise (`tn`), moderate
    ///   (15 dB) so the voice doesn't turn metallic;
    /// - `equalizer` ×2: −2 dB around 250 Hz (the boom of a lecture hall) and +3 dB around
    ///   3 kHz, where consonants make speech intelligible;
    /// - `dynaudnorm`: evens out the volume slowly (half-second frames, at most 3x gain), so a
    ///   teacher walking away from the microphone gets closer to one next to it. Kept gentle on
    ///   purpose: a strong normalizer raises whatever is loudest in a pause, and in a classroom
    ///   that is the students' voices;
    /// - `agate`: lowers by about 18 dB what stays well below the teacher (background voices,
    ///   chatter in the pauses), with a 300 ms release so word endings aren't cut;
    /// - a second, gentler `afftdn`: removes the noise left between words;
    /// - `volume` then `alimiter`: brings the whole lecture up to a comfortable level (about
    ///   −18 LUFS) with peaks held near −2 dBFS, so the AAC encoder never clips.
    ///
    /// Chosen on 2026-11-09 with ffmpeg 9.0.2 on a real 2.5-hour classroom recording (three
    /// 60 s excerpts: lecture, quiet speech, continuous background chatter), measured with
    /// `ebur128` and 100 ms RMS frames. The previous chain (`dynaudnorm` with 12x gain, no gate)
    /// raised the background 6.7 dB more than the teacher, so the chatter students complained
    /// about got louder; this one raises the teacher by ~8.5 dB and leaves the background 5–12 dB
    /// lower relative to them, at ~300x real time on an M2. Rejected there: `speechnorm`
    /// (pumping, wider loudness range on quiet speech), a gentler gate (background unchanged
    /// relative to speech), no final gain (lecture left at −25 LUFS, too quiet). Background
    /// voices as loud as the teacher can't be separated without a neural model; `arnndn` needs a
    /// model file ffmpeg doesn't ship.
    public static let filterChain = "highpass=f=90,lowpass=f=10000,afftdn=nr=15:nf=-50:tn=1,equalizer=f=250:t=q:w=1:g=-2,equalizer=f=3000:t=q:w=1.4:g=3,dynaudnorm=f=500:g=31:p=0.7:m=3,agate=threshold=0.035:ratio=4:range=0.12:attack=5:release=300:knee=4,afftdn=nr=6:nf=-50:tn=1,volume=8dB,alimiter=limit=0.8:level=disabled"

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

    /// The one media file a playlist cuts into byte ranges, when that is all it is, or nil.
    ///
    /// Why: Webex serves each recording as a single fragmented MP4 that the playlist slices with
    /// `EXT-X-BYTERANGE`. ffmpeg's HLS reader handles that badly: on a real 2.5-hour lecture
    /// (2026-11-09) it wrote the first 30 seconds, then kept requesting the same range,
    /// downloading hundreds of megabytes a minute without writing anything more, and the copy
    /// never got past 0%. Read as the plain file it is, the same lecture streams through in
    /// order. AVPlayer still plays the playlist: only ffmpeg's input changes.
    ///
    /// Only a media playlist whose init section (`EXT-X-MAP`) and every segment resolve to the
    /// same URL qualifies; a master playlist, several files, or encryption (`EXT-X-KEY` other
    /// than `NONE`, which needs the playlist's keys) keep the playlist as ffmpeg's input.
    public static func singleMediaFile(playlist: String, at playlistURL: URL) -> URL? {
        guard playlist.hasPrefix("#EXTM3U") else { return nil }
        var resources = Set<URL>()
        var segments = 0
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") || line.hasPrefix("#EXT-X-MEDIA:") { return nil }
                if line.hasPrefix("#EXT-X-KEY"), !line.contains("METHOD=NONE") { return nil }
                if line.hasPrefix("#EXT-X-MAP:") {
                    guard let uri = quotedAttribute("URI", in: line), let url = URL(string: uri, relativeTo: playlistURL)?.absoluteURL else { return nil }
                    resources.insert(url)
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL else { return nil }
            resources.insert(url)
            segments += 1
        }
        guard segments > 0, resources.count == 1, let file = resources.first, file.scheme == "https" else { return nil }
        return file
    }

    private static func quotedAttribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
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
