import Foundation
import Testing
@testable import BeepbarCore

/// The pure part of "Audio migliorato": where ffmpeg is looked for, what it is asked to do, how
/// its progress is read and which cached copies go.
struct AudioEnhancementTests {
    /// Only the fixed package-manager paths, in order; never anything else (no `PATH`).
    @Test func ffmpegIsFoundOnlyAtFixedPaths() {
        #expect(AudioEnhancement.locateFFmpeg { _ in false } == nil)
        #expect(AudioEnhancement.locateFFmpeg { $0 == "/usr/local/bin/ffmpeg" }?.path == "/usr/local/bin/ffmpeg")
        #expect(AudioEnhancement.locateFFmpeg { _ in true }?.path == "/opt/homebrew/bin/ffmpeg")
        var asked: [String] = []
        _ = AudioEnhancement.locateFFmpeg { asked.append($0); return false }
        #expect(asked == AudioEnhancement.ffmpegCandidates)
    }

    /// The filters, in the classroom order: the gate comes after the normalizer, so whatever
    /// the normalizer raised in a pause (background voices) is pushed down again; the final gain
    /// and the limiter come last, so the gate's threshold isn't moved by the gain and nothing after
    /// the limiter can clip. The normalizer stays gentle (at most 3x), since a strong one raised
    /// the chatter above the teacher on a real recording.
    @Test func theFiltersAreInClassroomOrder() {
        for filter in ["highpass", "afftdn", "equalizer", "dynaudnorm", "agate", "volume", "alimiter"] {
            #expect(AudioEnhancement.filterChain.contains(filter))
        }
        let filters = AudioEnhancement.filterChain.split(separator: ",").map { $0.split(separator: "=").first.map(String.init) ?? "" }
        #expect(filters.filter { $0 == "afftdn" }.count == 2)
        #expect(filters.firstIndex(of: "dynaudnorm")! < filters.firstIndex(of: "agate")!)
        #expect(filters.firstIndex(of: "agate")! < filters.firstIndex(of: "volume")!)
        #expect(filters.suffix(1) == ["alimiter"])
        #expect(AudioEnhancement.filterChain.contains("dynaudnorm=f=500:g=31:p=0.7:m=3"))
    }

    private static let playlistURL = URL(string: "https://cdn.example.test/rec/abc/playlist.m3u8?token=t")!
    private static let webex = """
    #EXTM3U
    #EXT-X-TARGETDURATION:30
    #EXT-X-VERSION:6
    #EXT-X-MEDIA-SEQUENCE:1
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MAP:URI="merge_0_9.mp4",BYTERANGE="1438@0"
    #EXTINF:30
    #EXT-X-BYTERANGE:3174988@5614
    merge_0_9.mp4
    #EXTINF:30
    #EXT-X-BYTERANGE:2349354@3180602
    merge_0_9.mp4
    #EXTINF:12.5,
    #EXT-X-BYTERANGE:1000
    merge_0_9.mp4
    #EXT-X-ENDLIST
    """

    /// The Webex layout: one fragmented MP4 sliced by byte ranges, with its init section,
    /// resolved against the playlist's address; a range without an offset follows the previous
    /// one, and both `EXTINF` forms (`30`, `12.5,`) are read. Guards against fetching the wrong
    /// bytes, which would play the wrong part of the lecture or nothing.
    @Test func aByteRangePlaylistIsReadAsItsSegments() throws {
        let lecture = try #require(AudioEnhancement.byteRangeLecture(playlist: Self.webex, at: Self.playlistURL))
        #expect(lecture.file == URL(string: "https://cdn.example.test/rec/abc/merge_0_9.mp4"))
        #expect(lecture.initSection == .init(offset: 0, length: 1438))
        #expect(lecture.segments == [
            .init(span: .init(offset: 5614, length: 3174988), duration: 30),
            .init(span: .init(offset: 3180602, length: 2349354), duration: 30),
            .init(span: .init(offset: 5529956, length: 1000), duration: 12.5),
        ])
        #expect(lecture.segments[0].span.rangeHeader == "bytes=5614-3180601")
        let crlf = Self.webex.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(AudioEnhancement.byteRangeLecture(playlist: crlf, at: Self.playlistURL) == lecture)
    }

    /// Anything but that layout gives nothing, so the player falls back to the stream rather than
    /// a filter fed the wrong bytes: plain segments, another file for the init section or a
    /// segment, a master playlist, encryption, http, no init section, a segment without its
    /// range or length, an implausibly large segment, no segments, not a playlist.
    @Test func otherPlaylistsAreNotFiltered() {
        let w = Self.webex
        let rejected = [
            "#EXTM3U\n#EXTINF:10\nseg1.ts\n#EXTINF:10\nseg2.ts\n",
            w.replacingOccurrences(of: "URI=\"merge_0_9.mp4\"", with: "URI=\"init.mp4\""),
            w.replacingOccurrences(of: "#EXT-X-BYTERANGE:1000\nmerge_0_9.mp4", with: "#EXT-X-BYTERANGE:1000\nother.mp4"),
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nmerge_0_9.mp4\n",
            w.replacingOccurrences(of: "#EXT-X-INDEPENDENT-SEGMENTS", with: "#EXT-X-KEY:METHOD=AES-128,URI=\"key\""),
            w.replacingOccurrences(of: "merge_0_9.mp4", with: "http://cdn.example.test/merge_0_9.mp4"),
            w.replacingOccurrences(of: "#EXT-X-MAP:URI=\"merge_0_9.mp4\",BYTERANGE=\"1438@0\"\n", with: ""),
            w.replacingOccurrences(of: "#EXT-X-BYTERANGE:2349354@3180602\n", with: ""),
            w.replacingOccurrences(of: "#EXTINF:12.5,\n", with: ""),
            w.replacingOccurrences(of: "3174988@5614", with: "99999999999@5614"),
            w.replacingOccurrences(of: "#EXTINF:30\n", with: "#EXTINF:abc\n"),
            "#EXTM3U\n#EXT-X-MAP:URI=\"a.mp4\",BYTERANGE=\"10@0\"\n#EXT-X-ENDLIST\n",
            "<html>merge_0_9.mp4</html>",
        ]
        for playlist in rejected {
            #expect(AudioEnhancement.byteRangeLecture(playlist: playlist, at: Self.playlistURL) == nil, "accepted: \(playlist.prefix(120))")
        }
        let clearKey = w.replacingOccurrences(of: "#EXT-X-INDEPENDENT-SEGMENTS", with: "#EXT-X-KEY:METHOD=NONE")
        #expect(AudioEnhancement.byteRangeLecture(playlist: clearKey, at: Self.playlistURL) != nil)
    }

    /// The player's playlist lists every segment with its own length, as TS segments the local
    /// server knows by index, complete (so AVPlayer can seek anywhere); its target duration
    /// covers the longest segment. Guards against a playlist AVPlayer would refuse or misplace.
    @Test func theLocalPlaylistListsEverySegment() throws {
        let lecture = try #require(AudioEnhancement.byteRangeLecture(playlist: Self.webex, at: Self.playlistURL))
        let playlist = AudioEnhancement.proxyPlaylist(lecture)
        #expect(playlist == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:30
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:30.000000,
        seg0.ts
        #EXTINF:30.000000,
        seg1.ts
        #EXTINF:12.500000,
        seg2.ts
        #EXT-X-ENDLIST

        """)
        #expect(!playlist.contains("cdn.example.test"), "the Webex address leaked into the local playlist")
        let long = AudioEnhancement.ByteRangeLecture(file: lecture.file, initSection: lecture.initSection, segments: [.init(span: .init(offset: 0, length: 1), duration: 30.2)])
        #expect(AudioEnhancement.proxyPlaylist(long).contains("#EXT-X-TARGETDURATION:31"))
        #expect(AudioEnhancement.segmentIndex("seg12.ts") == 12)
        #expect(AudioEnhancement.segmentIndex(AudioEnhancement.segmentName(0)) == 0)
        for name in ["seg.ts", "seg-1.ts", "segx.ts", "seg1.m4s", "../seg1.ts", "seg١.ts", "seg123456789.ts", "index.m3u8"] {
            #expect(AudioEnhancement.segmentIndex(name) == nil, "\(name)")
        }
    }

    /// Where a fragment's audio starts, from ffmpeg's `framecrc` report: the first packet's pts
    /// in its time base. Malformed reports give nothing rather than a wrong trim.
    @Test func theAudioStartIsReadFromTheProbe() {
        let report = """
        #extradata 0:        5, 0x054101d4
        #tb 0: 1/48000
        #media_type 0: audio
        0,    1440512,    1440512,     1024,      172, 0x77704ba3
        """
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: report) == 1440512.0 / 48000)
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: "0, 100, 100, 1024, 1, 0x0") == nil, "no time base")
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: "#tb 0: 1/48000\n") == nil, "no packet")
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: "#tb 0: 0/48000\n0, 1, 1, 1, 1, 0") == nil)
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: "#tb 0: 1/48000\n1, 5, 5, 1, 1, 0") == nil, "another stream")
        #expect(AudioEnhancement.firstPacketSeconds(framecrc: "") == nil)
        let probe = AudioEnhancement.probeArguments(input: "concat:/a|/b", output: "/p.txt")
        #expect(probe.contains("-copyts"))
        #expect(probe.suffix(4) == ["-f", "framecrc", "-y", "/p.txt"])
    }

    /// One segment: video from this segment alone, copied; audio from the wider input, filtered,
    /// then trimmed to this segment's span on the lecture's clock; local files only, TS out, no
    /// mux delay. Guards against audio that drifts from the video, double or missing audio at a
    /// join, and ffmpeg reaching the network.
    @Test func aSegmentIsFilteredAndTrimmedToItsOwnSpan() {
        let args = AudioEnhancement.segmentArguments(video: "concat:/i|/c", audio: "concat:/i|/p|/c|/n", start: 30.010667, end: 60.005333, output: "/o.ts")
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        let inputs = args.indices.filter { args[$0] == "-i" }.map { args[$0 + 1] }
        #expect(inputs == ["concat:/i|/c", "concat:/i|/p|/c|/n"])
        #expect(args.contains("-copyts"))
        #expect(args.firstIndex(of: "-copyts")! < args.firstIndex(of: "-i")!, "-copyts after the inputs is ignored")
        #expect(value(after: "-c:v") == "copy")
        #expect(value(after: "-af") == AudioEnhancement.filterChain + ",atrim=start=30.010667:end=60.005333")
        #expect(args.indices.filter { args[$0] == "-map" }.map { args[$0 + 1] } == ["0:v:0?", "1:a:0"])
        #expect(value(after: "-c:a") == "aac")
        #expect(value(after: "-b:a") == "192k")
        #expect(value(after: "-ar") == "48000")
        #expect(value(after: "-muxdelay") == "0")
        #expect(value(after: "-muxpreload") == "0")
        #expect(value(after: "-f") == "mpegts")
        #expect(value(after: "-protocol_whitelist") == "file,concat")
        #expect(args.contains("-nostdin"))
        #expect(args.last == "/o.ts")
        #expect(AudioEnhancement.concatInput(["/i", "/c"]) == "concat:/i|/c")
    }

    /// After voice isolation the chain has no noise reduction left to do (isolation did it) and
    /// levels speech with `speechnorm`, which `filterChain` couldn't use because it raised the
    /// room noise with the voice: equalizers first, then the leveller, the gate on its output,
    /// the limiter last so nothing after it can clip. Guards against a chain that filters the
    /// noise twice (a hollow voice) or levels after the gate (pauses raised again).
    @Test func theIsolatedChainLevelsSpeechAfterTheEqualizers() {
        let filters = AudioEnhancement.isolatedChain.split(separator: ",").map { $0.split(separator: "=").first.map(String.init) ?? "" }
        #expect(filters == ["highpass", "lowpass", "equalizer", "equalizer", "speechnorm", "agate", "alimiter"])
        #expect(!AudioEnhancement.isolatedChain.contains("afftdn"))
        #expect(AudioEnhancement.isolatedChain.contains("speechnorm=e=6:r=0.0005:l=1"))
        #expect(AudioEnhancement.isolatedChain.hasSuffix("alimiter=limit=0.8:level=disabled:latency=1"), "the limiter's look-ahead must be taken back")
        #expect(AudioEnhancement.samplePosition(8.021333) == 385024)
        #expect(AudioEnhancement.samplePosition(0) == 0)
    }

    /// The isolated path's two ffmpeg runs. Decoding: the audio context alone, on the lecture's
    /// clock (`-copyts` before the input), padded or trimmed to start exactly at `firstSample`
    /// (a WAV keeps no timestamps), mono float at the isolation rate, local files only.
    /// Encoding: the video copied from this segment, the isolated WAV put back at that same
    /// sample (`-itsoffset` before its input, where ffmpeg applies it), filtered with
    /// `isolatedChain` and trimmed to the segment's span. Guards against audio shifted from the
    /// picture or across a join, and against ffmpeg reaching the network.
    @Test func anIsolatedSegmentIsPutBackOnTheLecturesClock() {
        let decode = AudioEnhancement.isolationDecodeArguments(audio: "concat:/i|/p|/c|/n", firstSample: 385024, output: "/d.wav")
        func value(_ args: [String], after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value(decode, after: "-i") == "concat:/i|/p|/c|/n")
        #expect(decode.firstIndex(of: "-copyts")! < decode.firstIndex(of: "-i")!)
        #expect(value(decode, after: "-map") == "0:a:0")
        #expect(value(decode, after: "-af") == "aresample=48000:async=1:first_pts=385024,aformat=sample_fmts=flt:channel_layouts=mono")
        #expect(value(decode, after: "-c:a") == "pcm_f32le")
        #expect(value(decode, after: "-f") == "wav")
        #expect(value(decode, after: "-protocol_whitelist") == "file,concat")
        #expect(decode.contains("-nostdin"))
        #expect(decode.last == "/d.wav")

        let encode = AudioEnhancement.isolatedEncodeArguments(video: "concat:/i|/c", isolated: "/x.wav", firstSample: 385024, start: 30.010667, end: 60.005333, output: "/o.ts")
        let inputs = encode.indices.filter { encode[$0] == "-i" }
        #expect(inputs.map { encode[$0 + 1] } == ["concat:/i|/c", "/x.wav"])
        #expect(encode.firstIndex(of: "-copyts")! < inputs[0])
        let offset = encode.firstIndex(of: "-itsoffset")!
        #expect(encode[offset + 1] == "8.021333")
        #expect(inputs[0] < offset && offset < inputs[1], "-itsoffset applies to the input right after it")
        #expect(encode.indices.filter { encode[$0] == "-map" }.map { encode[$0 + 1] } == ["0:v:0?", "1:a:0"])
        #expect(value(encode, after: "-c:v") == "copy")
        #expect(value(encode, after: "-af") == AudioEnhancement.isolatedChain + ",atrim=start=30.010667:end=60.005333")
        #expect(value(encode, after: "-c:a") == "aac")
        #expect(value(encode, after: "-ar") == "48000")
        #expect(value(encode, after: "-muxdelay") == "0")
        #expect(value(encode, after: "-f") == "mpegts")
        #expect(value(encode, after: "-protocol_whitelist") == "file,concat")
        #expect(encode.last == "/o.ts")
    }

    /// The next segment always feeds the filter (the normalizer looks ahead: without it a join
    /// jumped by up to 3.5 dB); the previous one only when it is already here, so the first
    /// segment after a seek starts sooner. The last segment ends at its start plus its length,
    /// so its audio doesn't run past the lecture.
    @Test func eachSegmentIsFilteredWithItsNeighbours() throws {
        #expect(AudioEnhancement.audioContext(for: 5, count: 10, hasPrevious: true) == 4...6)
        #expect(AudioEnhancement.audioContext(for: 5, count: 10, hasPrevious: false) == 5...6)
        #expect(AudioEnhancement.audioContext(for: 0, count: 10, hasPrevious: true) == 0...1)
        #expect(AudioEnhancement.audioContext(for: 9, count: 10, hasPrevious: true) == 8...9)
        #expect(AudioEnhancement.audioContext(for: 0, count: 1, hasPrevious: false) == 0...0)
        let lecture = try #require(AudioEnhancement.byteRangeLecture(playlist: Self.webex, at: Self.playlistURL))
        #expect(AudioEnhancement.audioEnd(index: 0, start: 0.05, nextStart: 30.01, lecture: lecture) == 30.01)
        #expect(AudioEnhancement.audioEnd(index: 2, start: 60, nextStart: nil, lecture: lecture) == 72.5)
        #expect(AudioEnhancement.keptSegments(around: 0) == 0...2)
        #expect(AudioEnhancement.keptSegments(around: 10) == 8...12)
    }
}
