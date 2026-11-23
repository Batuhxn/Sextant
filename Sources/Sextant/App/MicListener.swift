import AVFoundation
import Foundation

/// Opens the microphone with iOS's own audio engine (raw sound: measurement mode turns off the voice
/// processing that would cut guitar overtones), runs ChromaAnalyzer every 45 ms and hands the result
/// to the web interface, which keeps the chord decision rule.
final class MicListener {
    static let shared = MicListener()
    var onResult: ((HearResult, Int) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let work = DispatchQueue(label: "sextant.listen")
    private var timer: DispatchSourceTimer?
    private var ring = [Float](repeating: 0, count: ChromaAnalyzer.bigN)
    private var ringPos = 0
    private var filled = 0
    private let lock = NSLock()
    private var analyzer: ChromaAnalyzer?
    private var seq = 0
    private(set) var running = false
    private var monitorOn = false

    func start(monitor: Bool) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.onError?("Mikrofon izni yok. Ayarlar > Sextant > Mikrofon'u aç.")
                    return
                }
                self.begin(monitor: monitor)
            }
        }
    }

    private func begin(monitor: Bool) {
        if running { stop() }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
        } catch {
            onError?("Ses oturumu açılamadı: \(error.localizedDescription)")
            return
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { onError?("Ses girişi bulunamadı."); return }
        analyzer = ChromaAnalyzer(sampleRate: fmt.sampleRate)
        lock.lock(); ringPos = 0; filled = 0; for i in ring.indices { ring[i] = 0 }; lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.push(buf) }
        setMonitor(monitor)
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("Mikrofon başlatılamadı: \(error.localizedDescription)")
            return
        }
        running = true
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + .milliseconds(45), repeating: .milliseconds(45))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        if monitorOn { engine.disconnectNodeOutput(engine.inputNode); monitorOn = false }
        // Back to plain playback so the song plays at full volume.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    /// Hear the guitar through the phone (only sensible with headphones).
    func setMonitor(_ on: Bool) {
        if on && !monitorOn {
            engine.connect(engine.inputNode, to: engine.mainMixerNode, format: engine.inputNode.outputFormat(forBus: 0))
            monitorOn = true
        } else if !on && monitorOn {
            engine.disconnectNodeOutput(engine.inputNode)
            monitorOn = false
        }
        engine.mainMixerNode.outputVolume = on ? 1 : 0
    }

    private func push(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        lock.lock()
        for i in 0..<n {
            var v: Float = 0
            for c in 0..<chans { v += ch[c][i] }
            ring[ringPos] = v / Float(chans)
            ringPos = (ringPos + 1) % ring.count
        }
        filled = min(ring.count, filled + n)
        lock.unlock()
    }

    private func tick() {
        guard let a = analyzer else { return }
        lock.lock()
        let ready = filled >= 4096
        var frame = [Float](repeating: 0, count: ring.count)
        if ready {  // oldest first
            let k = ringPos
            frame.replaceSubrange(0..<(ring.count - k), with: ring[k...])
            frame.replaceSubrange((ring.count - k)..<ring.count, with: ring[0..<k])
        }
        lock.unlock()
        guard ready else { return }
        let r = a.hear(frame)
        seq += 1
        let s = seq
        DispatchQueue.main.async { self.onResult?(r, s) }
    }
}
