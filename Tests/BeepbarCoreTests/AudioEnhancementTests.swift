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

    /// The command copies the video, filters and re-encodes only the audio, never waits on stdin,
    /// reads only network protocols, and writes the given (partial) file as MP4.
    @Test func theCommandFiltersOnlyTheAudio() throws {
        let input = URL(string: "https://example.invalid/hls.m3u8?token=x")!
        let output = URL(fileURLWithPath: "/tmp/x.partial.mp4")
        let args = AudioEnhancement.arguments(input: input, output: output)
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(value(after: "-i") == input.absoluteString)
        #expect(value(after: "-c:v") == "copy")
        #expect(value(after: "-af") == AudioEnhancement.filterChain)
        #expect(value(after: "-c:a") == "aac")
        #expect(value(after: "-b:a") == "192k")
        #expect(value(after: "-ar") == "48000")
        #expect(value(after: "-protocol_whitelist") == "https,tls,tcp,crypto")
        #expect(value(after: "-progress") == "pipe:1")
        #expect(value(after: "-f") == "mp4")
        #expect(args.contains("-nostdin"))
        #expect(args.last == output.path)
        #expect(!AudioEnhancement.protocolWhitelist.split(separator: ",").contains("file"))
        for filter in ["highpass", "afftdn", "equalizer", "dynaudnorm", "alimiter"] {
            #expect(AudioEnhancement.filterChain.contains(filter))
        }
        // Two denoise passes: the second removes the room noise the normalizer raised.
        let filters = AudioEnhancement.filterChain.split(separator: ",").map { $0.split(separator: "=").first.map(String.init) ?? "" }
        #expect(filters.filter { $0 == "afftdn" }.count == 2)
        #expect(filters.firstIndex(of: "dynaudnorm")! < filters.lastIndex(of: "afftdn")!)
    }

    /// Both microsecond keys are read; anything else, N/A and negatives are not progress.
    @Test func progressLinesAreParsed() {
        #expect(AudioEnhancement.progressSeconds(line: "out_time_us=1500000") == 1.5)
        #expect(AudioEnhancement.progressSeconds(line: "out_time_ms=2000000\n") == 2)
        #expect(AudioEnhancement.progressSeconds(line: "out_time_us=N/A") == nil)
        #expect(AudioEnhancement.progressSeconds(line: "out_time_us=-5") == nil)
        #expect(AudioEnhancement.progressSeconds(line: "out_time=00:00:01.5") == nil)
        #expect(AudioEnhancement.progressSeconds(line: "progress=continue") == nil)
        #expect(AudioEnhancement.fraction(written: 30, duration: 60) == 0.5)
        #expect(AudioEnhancement.fraction(written: 90, duration: 60) == 1)
        #expect(AudioEnhancement.fraction(written: 1, duration: nil) == nil)
        #expect(AudioEnhancement.fraction(written: 1, duration: 0) == nil)
    }

    /// Partial leftovers always go; finished copies beyond the limit go least recently used
    /// first, never the one being kept.
    @Test func evictionKeepsTheMostRecentCopies() {
        let day: TimeInterval = 86_400
        let files = [
            AudioEnhancement.CachedCopy(name: "a.mp4", lastUsed: Date(timeIntervalSince1970: 1 * day)),
            AudioEnhancement.CachedCopy(name: "b.mp4", lastUsed: Date(timeIntervalSince1970: 2 * day)),
            AudioEnhancement.CachedCopy(name: "c.mp4", lastUsed: Date(timeIntervalSince1970: 3 * day)),
            AudioEnhancement.CachedCopy(name: "d.partial.mp4", lastUsed: Date(timeIntervalSince1970: 4 * day)),
            AudioEnhancement.CachedCopy(name: "notes.txt", lastUsed: .distantPast),
        ]
        // Room for 2 others plus the new one: the oldest finished copy and the partial go.
        #expect(Set(AudioEnhancement.evictions(files, keeping: ["new.mp4"], limit: 3)) == ["a.mp4", "d.partial.mp4"])
        // Keeping the oldest one: it stays, and only one other fits.
        #expect(Set(AudioEnhancement.evictions(files, keeping: ["a.mp4"], limit: 3)) == ["b.mp4", "d.partial.mp4"])
        #expect(AudioEnhancement.evictions([], keeping: [], limit: 3).isEmpty)
    }
}
