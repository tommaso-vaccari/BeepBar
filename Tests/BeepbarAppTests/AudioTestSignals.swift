import AVFoundation
import Foundation
import Testing
import BeepbarCore

/// Synthetic audio for the enhanced-audio tests, made on the spot from macOS's own speech
/// synthesizer and ffmpeg's generators (never a real lecture), and the measurements they check:
/// level, and the delay between two signals by cross-correlation.
enum AudioTestSignals {
    /// Whether `say` is here to speak the synthetic teacher.
    static var canSpeak: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/say") }

    /// Runs `executable` and requires it to succeed.
    static func run(_ executable: URL, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(executable.lastPathComponent) failed")
    }

    /// About `seconds` of a synthetic teacher, mono, 48 kHz float WAV: `say` reading a lecture
    /// line in a loop, so the voice never stops for long.
    static func speech(seconds: Int, in folder: URL, ffmpeg: URL) throws -> URL {
        let spoken = folder.appendingPathComponent("spoken.aiff")
        try run(URL(fileURLWithPath: "/usr/bin/say"), ["-o", spoken.path,
            "Today we study the conditioning of a linear system. When the matrix is nearly singular, a small change in the data moves the solution a lot."], in: folder)
        let output = folder.appendingPathComponent("speech.wav")
        try run(ffmpeg, ["-nostdin", "-loglevel", "error", "-y", "-stream_loop", "-1", "-i", spoken.path, "-t", "\(seconds)",
                         "-ar", "48000", "-ac", "1", "-c:a", "pcm_f32le", output.path], in: folder)
        return output
    }

    /// The first channel of an audio file, as floats. Read in blocks until the end: one
    /// `read(into:)` of the whole length can return fewer frames than the file holds.
    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536))
        var result: [Float] = []
        result.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return result
    }

    static func level(_ x: ArraySlice<Float>) -> Double {
        let energy = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
        return 10 * log10(energy + 1e-20)
    }

    /// The shift, in samples, that best lines `signal` up with `reference` within `limit`:
    /// positive when `signal` comes later. Coarse every 8 samples, then refined.
    static func delay(of signal: [Float], against reference: [Float], limit: Int) -> Int {
        let count = min(signal.count, reference.count) - limit
        func correlation(_ lag: Int, step: Int) -> Double {
            var sum = 0.0
            var i = max(0, -lag)
            while i < count, i + lag < signal.count {
                sum += Double(reference[i]) * Double(signal[i + lag])
                i += step
            }
            return sum
        }
        let coarse = stride(from: -limit, through: limit, by: 8).max { correlation($0, step: 4) < correlation($1, step: 4) }!
        return ((coarse - 8)...(coarse + 8)).max { correlation($0, step: 1) < correlation($1, step: 1) }!
    }
}
