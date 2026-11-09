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
            let output = folder.appendingPathComponent("isolated-\(model).wav")
            try await AppleVoiceIsolator(model: model).isolate(speech, to: output)
            let isolated = try AudioTestSignals.samples(output)
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
                                          "-f", "lavfi", "-i", "anoisesrc=c=pink:a=0.04:r=48000:d=8",
                                          "-f", "lavfi", "-i", "sine=f=100:r=48000:d=8",
                                          "-filter_complex", "[1]volume=0.02[h];[0][h]amix=inputs=2:normalize=0",
                                          "-ac", "1", "-c:a", "pcm_f32le", noise.path], in: folder)
        let output = folder.appendingPathComponent("isolated.wav")
        try await try #require(AppleVoiceIsolator.preferred()).isolate(noise, to: output)
        let before = AudioTestSignals.level(try AudioTestSignals.samples(noise)[48000...])
        let after = AudioTestSignals.level(try AudioTestSignals.samples(output)[48000...])
        #expect(before - after > 20, "noise only \(before - after) dB lower")
    }

    /// A cancelled segment stops instead of rendering to the end; a file that isn't what the
    /// decode step writes (stereo here) is refused rather than isolated wrongly.
    @Test func cancellationAndOtherFilesStopIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let ffmpeg = try prepare()
        let speech = try AudioTestSignals.speech(seconds: 4, in: folder, ffmpeg: ffmpeg)
        let isolator = try #require(AppleVoiceIsolator.preferred())
        let output = folder.appendingPathComponent("isolated.wav")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await isolator.isolate(speech, to: output)
        }
        await #expect(throws: CancellationError.self) { try await task.value }

        let stereo = folder.appendingPathComponent("stereo.wav")
        try AudioTestSignals.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-i", speech.path, "-ac", "2", "-c:a", "pcm_f32le", stereo.path], in: folder)
        await #expect(throws: AppleVoiceIsolator.IsolationError.self) { try await isolator.isolate(stereo, to: output) }
    }
}
