import AVFoundation
import AudioToolbox
import BeepbarCore

/// Runs one segment's audio through voice isolation: reads the mono WAV at `input`, writes the
/// isolated audio to `output`, same length and the same clock. Throws `CancellationError` when
/// the calling task is cancelled.
protocol LiveAudioVoiceIsolating: Sendable {
    func isolate(_ input: URL, to output: URL) async throws
}

/// Apple's voice isolation (`AUSoundIsolation`, the audio unit behind FaceTime's Voice
/// Isolation), run offline on a file: it keeps the voice and removes steady noise, hum and much
/// of the room's echo, with nothing to download. On a synthetic classroom (`AudioEnhancement.
/// isolatedChain` has the numbers) it removed steady noise by about 45 dB, against about 15 dB
/// for ffmpeg's `afftdn`. What it keeps: other people's voices (voice too), and a steady tone
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

    func isolate(_ input: URL, to output: URL) async throws {
        try Self.render(input: input, output: output, model: model)
    }

    /// The offline render: a player node reads the file into the unit, the engine renders in
    /// 4096-frame blocks straight to `output` (memory independent of the segment's length), the
    /// first `model.delay` samples are dropped and the unit's tail rendered after the file ends.
    /// Checks for cancellation between blocks: a 90-second context renders in about a second.
    private static func render(input: URL, output: URL, model: Model) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        guard format.channelCount == 1, Int(format.sampleRate) == AudioEnhancement.isolationSampleRate else { throw IsolationError.unsupportedInput }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: component)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        guard AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, model.soundType, 0) == noErr,
              AudioUnitSetParameter(effect.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0) == noErr
        else { throw IsolationError.renderFailed }
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(source, at: nil)
        player.play()

        let destination = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { throw IsolationError.renderFailed }
        let delay = AVAudioFramePosition(model.delay)
        let total = source.length + delay
        var toDrop = delay
        // Exactly the input's length: the engine may round the last block up.
        var toWrite = source.length
        while engine.manualRenderingSampleTime < total, toWrite > 0 {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(total - engine.manualRenderingSampleTime, AVAudioFramePosition(buffer.frameCapacity)))
            guard try engine.renderOffline(frames, to: buffer) == .success else { throw IsolationError.renderFailed }
            if toDrop >= AVAudioFramePosition(buffer.frameLength) {
                toDrop -= AVAudioFramePosition(buffer.frameLength)
                continue
            }
            if toDrop > 0 {
                // Shift the block's kept part to its start: AVAudioFile writes from frame 0.
                let keep = Int(buffer.frameLength) - Int(toDrop)
                let samples = buffer.floatChannelData![0]
                samples.update(from: samples + Int(toDrop), count: keep)
                buffer.frameLength = AVAudioFrameCount(keep)
                toDrop = 0
            }
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameLength), toWrite))
            toWrite -= AVAudioFramePosition(buffer.frameLength)
            try destination.write(from: buffer)
        }
        // Before macOS 15 the file is closed when `destination` goes out of scope, here too.
        if #available(macOS 15, *) { destination.close() }
    }
}
