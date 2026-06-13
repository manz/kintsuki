import AVFoundation
import CKintsuki
import Foundation

/// CoreAudio output for the emulator.
///
/// ares resamples the SPC/DSP output to a fixed interleaved-stereo float32
/// stream at `kintsuki_audio_sample_rate` (48 kHz) and buffers it in a
/// lock-free ring inside libkintsuki. This class stands up an
/// `AVAudioEngine` whose source node pulls from that ring on the real-time
/// render thread. The producer is the emulation tick calling
/// `kintsuki_run_frames`, the consumer is the render callback here.
///
/// The render block must stay allocation- and lock-free; it only calls
/// `kintsuki_audio_read` (a plain memcpy out of the ring) and zero-fills on
/// underrun, so it is safe in the audio real-time context.
@MainActor
final class AudioOutput {
    private let handle: OpaquePointer
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private(set) var running = false

    /// Engine nodes use non-interleaved (planar) float buffers; the
    /// mixer input bus rejects an interleaved format. The core's ring is
    /// interleaved, so the render callback reads into this scratch and
    /// deinterleaves into the planar output. Heap-allocated (not a
    /// main-actor stored property) so the audio thread can touch it
    /// without crossing actor isolation, and never allocates in-callback.
    private static let maxRenderFrames = 4096
    private var scratch: UnsafeMutablePointer<Float>?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    /// Begin pulling samples and route them to the default output device.
    /// Idempotent: a second call while already running is a no-op.
    func start() {
        guard !running else { return }
        let sampleRate = kintsuki_audio_sample_rate(handle)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 2,
                                         interleaved: false) else {
            NSLog("kintsuki: audio format init failed")
            return
        }

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioOutput.maxRenderFrames * 2)
        scratch.initialize(repeating: 0, count: AudioOutput.maxRenderFrames * 2)
        self.scratch = scratch

        let handle = self.handle
        let maxFrames = AudioOutput.maxRenderFrames
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard let lRaw = abl[0].mData,
                  abl.count > 1, let rRaw = abl[1].mData,
                  frames <= maxFrames else {
                // Can't satisfy the request safely; emit silence.
                for buf in abl {
                    if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }
            let left = lRaw.assumingMemoryBound(to: Float.self)
            let right = rRaw.assumingMemoryBound(to: Float.self)
            // Pull interleaved stereo from the core, then deinterleave into
            // the planar output buffers. A short read means the ring
            // underran (paused / STP / host hiccup): zero the tail rather
            // than replay stale samples.
            let got = Int(kintsuki_audio_read(handle, scratch, frameCount))
            for i in 0..<got {
                left[i] = scratch[i * 2]
                right[i] = scratch[i * 2 + 1]
            }
            for i in got..<frames {
                left[i] = 0
                right[i] = 0
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        kintsuki_audio_set_enabled(handle, 1)
        do {
            try engine.start()
            running = true
            NSLog("kintsuki: audio output started @ \(Int(sampleRate)) Hz")
        } catch {
            kintsuki_audio_set_enabled(handle, 0)
            NSLog("kintsuki: audio engine start failed: \(error.localizedDescription)")
        }
    }

    /// Stop output and gate sample production in the core. Idempotent.
    func stop() {
        guard running else { return }
        // engine.stop() blocks until the render thread quiesces, so it is
        // safe to free the scratch the callback was reading afterwards.
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        kintsuki_audio_set_enabled(handle, 0)
        if let scratch {
            scratch.deallocate()
            self.scratch = nil
        }
        running = false
        NSLog("kintsuki: audio output stopped")
    }
}
