import AVFoundation
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Apple's voice isolation as the enhanced audio uses it, on a synthetic teacher and synthetic
/// noise: skipped where the Mac lacks the unit, ffmpeg or `say`. Proves what nothing else can:
/// the unit's real delay, which it doesn't report, is the one `AppleVoiceIsolator.Model` drops.
@Suite(.enabled(if: AppleVoiceIsolator.preferred() != nil && AudioEnhancement.locateFFmpeg() != nil && AudioTestSignals.canSpeak,
                "needs voice isolation, ffmpeg and say"))
struct VoiceIsolatorTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-isolator-\(UUID().uuidString)", isDirectory: true)

    private func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try #require(AudioEnhancement.locateFFmpeg())
    }

    private var models: [AppleVoiceIsolator.Model] {
        if #available(macOS 15, *) { return [.highQuality, .standard] }
        return [.standard]
    }

    /// The voice comes out as long as it went in, on the same samples (within 2 ms) and at
    /// about its level, for every model this Mac has. Guards against the unit's hidden delay
    /// (4440 or 2704 samples) left in, which would put the voice behind the picture and cut
    /// words at every join, and against a macOS that changes that delay.
    @Test func theVoiceStaysOnItsOwnSamples() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let speech = try AudioTestSignals.speech(seconds: 10, in: folder, ffmpeg: try prepare())
        let input = try AudioTestSignals.samples(speech)
        for model in models {
            let output = folder.appendingPathComponent("isolated-\(model).raw")
            try await AppleVoiceIsolator(model: model).isolate(speech, from: 0, count: nil, to: output)
            let isolated = try AudioTestSignals.rawSamples(output)
            #expect(isolated.count == input.count, "\(model): length changed")
            let delay = AudioTestSignals.delay(of: isolated, against: input, limit: 9600)
            #expect(abs(delay) <= 96, "\(model): the voice moved by \(delay) samples")
            let change = AudioTestSignals.level(isolated[...]) - AudioTestSignals.level(input[...])
            #expect(abs(change) < 6, "\(model): voice level changed by \(change) dB")
        }
    }

    /// Steady noise and a mains hum, with no voice, come out at least 20 dB quieter (measured
    /// about 27 dB on these 8 seconds, 45 dB over 50). Guards against isolation silently not running (a parameter refused, the
    /// wrong unit) while the audio still flows.
    @Test func steadyNoiseIsRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = try prepare()
        let noise = folder.appendingPathComponent("noise.wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y",
                                          "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.04:r=48000:d=8:seed=7",
                                          "-f", "lavfi", "-i", "sine=f=100:r=48000:d=8",
                                          "-filter_complex", "[1]volume=0.02[h];[0][h]amix=inputs=2:normalize=0",
                                          "-ac", "1", "-c:a", "pcm_f32le", noise.path], in: folder)
        let output = folder.appendingPathComponent("isolated.raw")
        try await try #require(AppleVoiceIsolator.preferred()).isolate(noise, from: 0, count: nil, to: output)
        let before = AudioTestSignals.level(try AudioTestSignals.samples(noise)[48000...])
        let after = AudioTestSignals.level(try AudioTestSignals.rawSamples(output)[48000...])
        #expect(before - after > 20, "noise only \(before - after) dB lower")
    }

    /// A cancelled segment stops instead of rendering to the end; a file that isn't what the
    /// decode step writes (stereo here) is refused rather than isolated wrongly.
    @Test func cancellationAndOtherFilesStopIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = try prepare()
        let speech = try AudioTestSignals.speech(seconds: 4, in: folder, ffmpeg: ffmpeg)
        let isolator = try #require(AppleVoiceIsolator.preferred())
        let output = folder.appendingPathComponent("isolated.raw")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await isolator.isolate(speech, from: 0, count: nil, to: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }

        let stereo = folder.appendingPathComponent("stereo.wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", speech.path, "-ac", "2", "-c:a", "pcm_f32le", stereo.path], in: folder)
        await #expect(throws: AppleVoiceIsolator.IsolationError.self) { try await isolator.isolate(stereo, from: 0, count: nil, to: output) }
        // A start past the end of the audio is refused too, rather than written as nothing.
        await #expect(throws: AppleVoiceIsolator.IsolationError.self) { try await isolator.isolate(speech, from: 4 * 48000 + 1, count: nil, to: output) }
    }

    /// A stretch isolated on its own, with `isolationLead` before it and `isolationTail` after,
    /// comes out as the same stretch of the whole recording isolated in one go, cut at exactly the
    /// samples asked for: the difference stays more than 45 dB below the voice (measured 59 dB,
    /// the floor of 16-bit pieces; identical before rounding to 16 bits). This is what
    /// lets the pipeline isolate a lecture one fragment at a time (`LiveAudioPipeline`) without
    /// a change in the voice where two fragments meet. Guards against a lead-in or tail too
    /// short (−25 and −16 dB without them), and `from`/`count` cutting a sample off.
    @Test func aStretchIsolatedOnItsOwnMatchesTheWholeRecording() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = try prepare()
        let speech = try AudioTestSignals.speech(seconds: 24, in: folder, ffmpeg: ffmpeg)
        let noisy = folder.appendingPathComponent("noisy.wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", speech.path,
                                          "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.02:r=48000:d=24:seed=7",
                                          "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-ac", "1", "-c:a", "pcm_f32le", noisy.path], in: folder)
        let input = try AudioTestSignals.samples(noisy)
        let isolator = try #require(AppleVoiceIsolator.preferred())
        let whole = folder.appendingPathComponent("whole.raw")
        try await isolator.isolate(noisy, from: 0, count: nil, to: whole)
        let reference = try AudioTestSignals.rawSamples(whole)

        // An arbitrary stretch, as a fragment between two others: 10.3 s to 17.9 s.
        let start = 494_400, end = 859_200
        let lead = AudioEnhancement.isolationLead, tail = AudioEnhancement.isolationTail
        let chunk = folder.appendingPathComponent("chunk.wav")
        try AudioTestSignals.writeWAV(Array(input[(start - lead)..<(end + tail)]), to: chunk)
        let piece = folder.appendingPathComponent("piece.raw")
        try await isolator.isolate(chunk, from: lead, count: end - start, to: piece)
        let isolated = try AudioTestSignals.rawSamples(piece)
        try #require(isolated.count == end - start)
        let difference = zip(isolated, reference[start..<end]).map { $0 - $1 }
        let below = AudioTestSignals.level(reference[start..<end]) - AudioTestSignals.level(difference[...])
        #expect(below > 45, "the stretch differs from the whole by only \(below) dB")
        // Its first and last second, where the lead-in and the tail matter.
        for edge in [0..<48000, (end - start - 48000)..<(end - start)] {
            let near = AudioTestSignals.level(reference[(start + edge.lowerBound)..<(start + edge.upperBound)]) - AudioTestSignals.level(difference[edge])
            #expect(near > 45, "near \(edge) the stretch differs by only \(near) dB")
        }
    }
}
