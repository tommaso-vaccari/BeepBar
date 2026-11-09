import Foundation

// "Audio migliorato": a lecture's audio with cleaner, steadier speech, filtered while it plays by
// the student's own ffmpeg (Homebrew or MacPorts).
//
// Why ffmpeg and a local server: the lecture is an HLS stream, and AVFoundation never hands an
// HLS item's audio to an `MTAudioProcessingTap` (probed on macOS 27 on 2026-11-09 against Apple's
// public HLS sample: the tap was attached and received 0 frames while the item played), so there
// is no native way to filter what AVPlayer plays. Instead the app serves AVPlayer a playlist of
// its own on 127.0.0.1; each 30-second segment is fetched from Webex as its byte range, the
// video copied as is and only the audio filtered (`filterChain`), a fraction of a second of
// work per segment. With the switch off the player plays Webex's stream directly.
//
// Why segments and not a whole copy (the first version, replaced on 2026-11-09): a copy of a
// 2.5-hour lecture took about five minutes and 950 MB before the student heard anything.
//
// Seamless joins: each segment's audio is filtered with the previous and next segments around
// it (`segmentArguments`), so the normalizer and the noise estimate see the same signal on both
// sides of a join, and is then trimmed to exactly its own span on the lecture's clock
// (`-copyts`, `atrim`). Measured on a synthetic lecture: level difference across a join 0.3–0.8
// dB median, the same as inside a segment; without the following segment, up to 3.5 dB.
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

    /// A Webex lecture as its playlist describes it: one fragmented MP4 (`file`), its init
    /// section and its segments, each a byte range of that file with its length in seconds.
    public struct ByteRangeLecture: Equatable, Sendable {
        public struct Span: Equatable, Sendable {
            public let offset: Int64
            public let length: Int64
            public init(offset: Int64, length: Int64) {
                self.offset = offset
                self.length = length
            }
            /// The HTTP `Range` header value for these bytes.
            public var rangeHeader: String { "bytes=\(offset)-\(offset + length - 1)" }
        }
        public struct Segment: Equatable, Sendable {
            public let span: Span
            public let duration: Double
            public init(span: Span, duration: Double) {
                self.span = span
                self.duration = duration
            }
        }
        public let file: URL
        public let initSection: Span
        public let segments: [Segment]
    }

    /// The largest segment accepted, in bytes: a 30-second segment of a lecture is 2–4 MB, so
    /// anything this big is not one, and fetching it would cost the student's data plan.
    public static let maximumSegmentBytes: Int64 = 64 * 1024 * 1024

    /// The lecture behind `playlist` when it is the Webex layout, or nil.
    ///
    /// Webex serves each recording as a single fragmented MP4 that the playlist slices with
    /// `EXT-X-BYTERANGE`, its init section in `EXT-X-MAP`. Only that qualifies: a master
    /// playlist, several files, segments without a byte range, encryption (`EXT-X-KEY` other than
    /// `NONE`), a non-https file or an implausible size keep enhanced audio unavailable, and the
    /// player falls back to the stream. A byte range without `@offset` follows the previous one
    /// (RFC 8216 §4.3.2.2).
    public static func byteRangeLecture(playlist: String, at playlistURL: URL) -> ByteRangeLecture? {
        guard playlist.hasPrefix("#EXTM3U") else { return nil }
        var file: URL?
        var initSection: ByteRangeLecture.Span?
        var segments: [ByteRangeLecture.Segment] = []
        var duration: Double?
        var range: ByteRangeLecture.Span?
        var nextOffset: Int64?
        func same(_ url: URL) -> Bool {
            if let file { return file == url }
            file = url
            return true
        }
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF") || line.hasPrefix("#EXT-X-MEDIA:") { return nil }
                if line.hasPrefix("#EXT-X-KEY"), !line.contains("METHOD=NONE") { return nil }
                if line.hasPrefix("#EXT-X-MAP:") {
                    guard initSection == nil, let uri = quotedAttribute("URI", in: line),
                          let url = URL(string: uri, relativeTo: playlistURL)?.absoluteURL, same(url),
                          let spec = quotedAttribute("BYTERANGE", in: line), let span = span(spec, after: nil) else { return nil }
                    initSection = span
                } else if line.hasPrefix("#EXTINF:") {
                    let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    guard let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds > 0, seconds.isFinite else { return nil }
                    duration = seconds
                } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                    guard let span = span(String(line.dropFirst("#EXT-X-BYTERANGE:".count)), after: nextOffset) else { return nil }
                    range = span
                }
                continue
            }
            guard let url = URL(string: line, relativeTo: playlistURL)?.absoluteURL, same(url),
                  let seconds = duration, let span = range, span.length <= maximumSegmentBytes else { return nil }
            segments.append(.init(span: span, duration: seconds))
            nextOffset = span.offset + span.length
            duration = nil
            range = nil
        }
        guard let file, file.scheme == "https", let initSection, initSection.length <= maximumSegmentBytes, !segments.isEmpty else { return nil }
        return ByteRangeLecture(file: file, initSection: initSection, segments: segments)
    }

    /// `length[@offset]`; without an offset, `after` (the previous range's end), or nil.
    private static func span(_ spec: String, after: Int64?) -> ByteRangeLecture.Span? {
        let parts = spec.trimmingCharacters(in: .whitespaces).split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let length = Int64(parts[0]), length > 0 else { return nil }
        let offset = parts.count == 2 ? Int64(parts[1]) : after
        guard let offset, offset >= 0 else { return nil }
        return .init(offset: offset, length: length)
    }

    private static func quotedAttribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// The playlist AVPlayer gets from the local server: the lecture's segments, same lengths,
    /// named `segmentName(_:)` relative to the playlist, as MPEG-TS (version 3: no byte ranges,
    /// no init section), complete (`ENDLIST`), so AVPlayer can seek anywhere at once.
    public static func proxyPlaylist(_ lecture: ByteRangeLecture) -> String {
        let target = Int((lecture.segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
        for (index, segment) in lecture.segments.enumerated() {
            lines.append("#EXTINF:\(String(format: "%.6f", segment.duration)),")
            lines.append(segmentName(index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    public static let playlistName = "index.m3u8"
    public static func segmentName(_ index: Int) -> String { "seg\(index).ts" }

    /// The segment index a request names (`seg12.ts`), or nil for anything else.
    public static func segmentIndex(_ name: String) -> Int? {
        guard name.hasPrefix("seg"), name.hasSuffix(".ts") else { return nil }
        let digits = name.dropFirst(3).dropLast(3)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), digits.count < 8 else { return nil }
        return Int(digits)
    }

    /// The protocols ffmpeg may open: only the local files the app wrote and their
    /// concatenation. Never the network: the app fetches every byte itself, bounded, so ffmpeg
    /// can't be led by a file's contents to read anything else.
    public static let protocolWhitelist = "file,concat"

    /// ffmpeg reading `files` (absolute paths, the init section first) as one MP4.
    public static func concatInput(_ files: [String]) -> String { "concat:" + files.joined(separator: "|") }

    /// ffmpeg's command that reports where a fragment's audio starts on the lecture's clock: its
    /// first audio packet, copied (no decoding, ~25 ms), written as `framecrc` to `output`
    /// (`firstPacketSeconds`). `-copyts` keeps the timestamps the segments are trimmed on.
    public static func probeArguments(input: String, output: String) -> [String] {
        [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-protocol_whitelist", protocolWhitelist,
            "-copyts", "-i", input,
            "-map", "0:a:0", "-c", "copy", "-frames:a", "1",
            "-f", "framecrc", "-y", output,
        ]
    }

    /// The first packet's time in seconds from a `framecrc` report: its `#tb 0: 1/48000` line
    /// and the first packet line (`0, pts, dts, duration, size, crc`). Nil when either is missing.
    public static func firstPacketSeconds(framecrc: String) -> Double? {
        var timebase: (Double, Double)?
        for raw in framecrc.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#tb 0:") {
                let fraction = line.dropFirst("#tb 0:".count).trimmingCharacters(in: .whitespaces).split(separator: "/")
                guard fraction.count == 2, let num = Double(fraction[0]), let den = Double(fraction[1]), num > 0, den > 0 else { return nil }
                timebase = (num, den)
            } else if !line.hasPrefix("#") {
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 3, fields[0] == "0", let (num, den) = timebase, let pts = Double(fields[1]) else { return nil }
                return pts * num / den
            }
        }
        return nil
    }

    /// ffmpeg's command for one segment, without the executable.
    /// - `video`: the init section and this segment, read for the video, copied as is;
    /// - `audio`: the init section and this segment with its neighbours (`audioContext`), read
    ///   for the audio, filtered, then trimmed to `start..<end`: where this segment's audio
    ///   starts and the next one's starts (`firstPacketSeconds`), or, for the last segment,
    ///   its start plus its playlist length, so its audio doesn't run past the video;
    /// - `-copyts`: both keep the lecture's own clock, so the segments line up end to end;
    /// - MPEG-TS out, no mux delay (that would shift every segment by 0.7 s).
    /// 192 kb/s at 48 kHz: the filtered audio is encoded once more, so it gets a rate well above
    /// the stream's own (typically 64–128 kb/s), which keeps that generation inaudible. ffmpeg's
    /// own AAC encoder, present in every build.
    public static func segmentArguments(video: String, audio: String, start: Double, end: Double, output: String) -> [String] {
        [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-protocol_whitelist", protocolWhitelist,
            "-copyts",
            "-i", video,
            "-i", audio,
            // The first video track if there is one (a voice-only recording has none), and the
            // first audio track, which must exist.
            "-map", "0:v:0?", "-map", "1:a:0",
            "-c:v", "copy",
            "-af", filterChain + ",atrim=start=\(seconds(start)):end=\(seconds(end))",
            "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
            "-muxdelay", "0", "-muxpreload", "0",
            "-f", "mpegts", "-y", output,
        ]
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.6f", value) }

    /// The segments whose audio goes into segment `index`'s filter: the next one always (the
    /// normalizer looks ahead, and without it a join jumped by up to 3.5 dB), the previous one
    /// only when `hasPrevious` (already fetched: the segment just played), so the first segment
    /// after a seek needs one fetch less and starts sooner.
    public static func audioContext(for index: Int, count: Int, hasPrevious: Bool) -> ClosedRange<Int> {
        let first = hasPrevious && index > 0 ? index - 1 : index
        let last = min(index + 1, count - 1)
        return first...max(first, last)
    }

    /// Where segment `index`'s audio ends on the lecture's clock: the next segment's start, or,
    /// for the last one, its own start plus its playlist length.
    public static func audioEnd(index: Int, start: Double, nextStart: Double?, lecture: ByteRangeLecture) -> Double {
        nextStart ?? start + lecture.segments[index].duration
    }

    /// Which segments a request for `index` keeps, cached or underway: the ones around it.
    /// Anything else belongs to a position the student left (a seek), and its work is stopped.
    public static func keptSegments(around index: Int) -> ClosedRange<Int> { max(0, index - 2)...(index + 2) }
}
