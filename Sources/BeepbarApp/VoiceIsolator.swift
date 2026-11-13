import AVFoundation
import AudioToolbox
import BeepbarCore

/// Runs audio through voice isolation: reads the mono 48 kHz WAV at `input` and writes to
/// `output` its isolated samples from `first`, `count` of them (to the end when nil), on the
/// input's own clock, as raw 16-bit little-endian mono (the pieces `LiveAudioPipeline` levels
/// with `VoiceLeveler` before `AudioEnhancement.levelledEncodeArguments`). The samples around the kept range are what the
/// voice model hears before and after it (`AudioEnhancement.isolationLead`). Throws
/// `CancellationError` when the calling task is cancelled.
protocol LiveAudioVoiceIsolating: Sendable {
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws
}

/// Apple's voice isolation (`AUSoundIsolation`, the audio unit behind FaceTime's Voice
/// Isolation), run offline on a file: it keeps the voice and removes steady noise, hum and much
/// of the room's echo, with nothing to download. On a synthetic classroom (measured with the ffmpeg chain that preceded the leveler, removed in
/// PR #242) it removed steady noise by about 45 dB,
/// against about 15 dB for ffmpeg's `afftdn`. What it keeps: other people's voices (voice too), and a steady tone
/// as loud as speech (a 100 Hz hum at −27 dB came through unchanged; at −42 dB it went).
///
/// The unit's delay: it answers 0 to `kAudioUnitProperty_Latency`, yet its output comes later
/// than its input, by 4440 samples (92.5 ms) for the high-quality voice model and 2704 (56.3 ms)
/// for the standard one at 48 kHz, measured on 2026-11-09 on macOS 27 by cross-correlation on
/// clean speech, the same for every render size. Left in, the voice would trail the picture and
/// the segments' trims would cut words at the joins; `isolate` drops that many samples from the
/// start and renders as many more at the end. `VoiceIsolatorTests` measures it again, so a macOS
/// that changes it fails there rather than in a student's lecture.
struct AppleVoiceIsolator: LiveAudioVoiceIsolating {
    enum Model: Equatable, Sendable {
        /// `kAUSoundIsolationSoundType_HighQualityVoice`, macOS 15 and later: a closer voice.
        case highQuality
        /// `kAUSoundIsolationSoundType_Voice`, every macOS with the unit.
        case standard

        /// The value of `kAUSoundIsolationParam_SoundToIsolate`. Raw values on purpose: the
        /// named sound types are marked macOS 15, and the standard one must also work on 14.
        var soundType: AudioUnitParameterValue { self == .highQuality ? 0 : 1 }

        /// The delay the unit adds, in samples at `AudioEnhancement.isolationSampleRate`.
        var delay: Int { self == .highQuality ? 4440 : 2704 }
    }

    let model: Model

    static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// The best isolation this Mac has, or nil when the unit is missing (then the pipeline
    /// filters with `AudioEnhancement.filterChain` alone, as before isolation).
    static func preferred() -> AppleVoiceIsolator? {
        var description = component
        guard AudioComponentFindNext(nil, &description) != nil else { return nil }
        if #available(macOS 15, *) { return AppleVoiceIsolator(model: .highQuality) }
        return AppleVoiceIsolator(model: .standard)
    }

    enum IsolationError: Error { case unsupportedInput, renderFailed }

    /// A nonisolated async function: the second of rendering runs on the shared pool, neither
    /// on the main actor nor on `LiveAudioPipeline` (no default actor isolation is set in
    /// either build), so seeks and `stop()` aren't held up by it.
    func isolate(_ input: URL, from first: Int, count: Int?, to output: URL) async throws {
        try Self.render(input: input, first: first, count: count, output: output, model: model)
    }

    /// The offline render: a player node reads the file into the unit, the engine renders in
    /// 4096-frame blocks straight to `output` (memory independent of the audio's length), the
    /// first `model.delay` samples and those before `first` are dropped, and the unit's tail
    /// rendered after the file ends. Checks for cancellation between blocks: a 30-second
    /// fragment renders in about a third of a second.
    ///
    /// 16-bit output, clamped to full scale: half the disk of float for the pieces a lecture
    /// keeps (`LiveAudioPipeline`), 96 dB of range, and isolated speech stays below full scale.
    private static func render(input: URL, first: Int, count: Int?, output: URL, model: Model) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        guard format.channelCount == 1, Int(format.sampleRate) == AudioEnhancement.isolationSampleRate,
              first >= 0, first <= source.length, (count ?? 0) >= 0 else { throw IsolationError.unsupportedInput }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: component)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        // The standard model is the unit's default, and on macOS 14 the parameter's only value:
        // set only to ask for the high-quality one. The wet/dry mix is set to 100% explicitly
        // (the isolated voice alone), so what is heard never depends on the unit's default.
        guard model == .standard || AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, model.soundType, 0) == noErr,
              AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0) == noErr
        else { throw IsolationError.renderFailed }
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(source, at: nil)
        player.play()

        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw IsolationError.renderFailed }
        let destination = try FileHandle(forWritingTo: output)
        defer { try? destination.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { throw IsolationError.renderFailed }
        let wanted = AVAudioFramePosition(min(count ?? Int.max, Int(source.length) - first))
        // The unit's output at `delay + first` is the input's sample `first`.
        let skip = AVAudioFramePosition(model.delay + first)
        let total = skip + wanted
        var rendered: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        var samples = [Int16](repeating: 0, count: Int(buffer.frameCapacity))
        while rendered < total, written < wanted {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(total - rendered, AVAudioFramePosition(buffer.frameCapacity)))
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw IsolationError.renderFailed }
            let blockStart = rendered
            rendered += AVAudioFramePosition(buffer.frameLength)
            // The part of this block past `skip`, up to what is still wanted.
            let from = max(0, skip - blockStart)
            let to = min(AVAudioFramePosition(buffer.frameLength), from + (wanted - written))
            guard to > from else { continue }
            let block = buffer.floatChannelData![0]
            for i in 0..<Int(to - from) {
                samples[i] = Int16((max(-1, min(1, block[Int(from) + i])) * 32767).rounded()).littleEndian
            }
            try samples.withUnsafeBytes { try destination.write(contentsOf: UnsafeRawBufferPointer(rebasing: $0[0..<(Int(to - from) * 2)])) }
            written += to - from
        }
    }
}
