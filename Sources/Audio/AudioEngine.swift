import AVFoundation

/// Central audio engine for Marduk.
/// Manages the AVAudioEngine graph with separate submixers for speech and earcons.
/// Phase 1: Speech output only. Earcons and spatial audio added in Phase 5.
final class AudioEngine {
    let engine = AVAudioEngine()

    // Submixers for independent volume control
    let speechMixer = AVAudioMixerNode()
    let earconMixer = AVAudioMixerNode()

    // Player nodes
    let speechPlayer = AVAudioPlayerNode()

    var speechVolume: Float {
        get { speechMixer.volume }
        set { speechMixer.volume = newValue }
    }

    var earconVolume: Float {
        get { earconMixer.volume }
        set { earconMixer.volume = newValue }
    }

    var masterVolume: Float {
        get { engine.mainMixerNode.volume }
        set { engine.mainMixerNode.volume = newValue }
    }

    init() throws {
        // Attach nodes to the engine
        engine.attach(speechMixer)
        engine.attach(earconMixer)
        engine.attach(speechPlayer)

        // Connect: speechPlayer -> speechMixer -> mainMixer -> output
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(speechPlayer, to: speechMixer, format: format)
        engine.connect(speechMixer, to: engine.mainMixerNode, format: format)
        engine.connect(earconMixer, to: engine.mainMixerNode, format: format)

        // Start the engine
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    /// Schedule a PCM buffer for playback on the speech player.
    /// Used when routing AVSpeechSynthesizer output through the engine.
    func playSpeechBuffer(_ buffer: AVAudioPCMBuffer) {
        speechPlayer.scheduleBuffer(buffer, completionHandler: nil)
        if !speechPlayer.isPlaying {
            speechPlayer.play()
        }
    }
}
