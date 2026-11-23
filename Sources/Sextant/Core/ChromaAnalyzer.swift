import Accelerate
import Foundation

/// The listening analysis of the web interface (`hear()` in index.html), ported to native code.
///
/// The browser version reads two Web Audio AnalyserNodes: a 16384-point one (Blackman window,
/// smoothing 0.35) for the harmonic chroma, and a 1024-point one (no smoothing) for spectral flux.
/// This class reproduces both from raw microphone samples, so the chord decision rule that stays in
/// JavaScript (`judge`, the per-bar statistics) sees the same numbers it was tuned on.
public struct HearResult: Equatable {
    public var sc: [Double]   // 24 template scores: C, Cm, C#, C#m, ... B, Bm
    public var best: Int
    public var bass: Int      // pitch class of the lowest strong note, -1 if none
    public var loud: Bool
    public var db: Double     // level of the last 2048 samples, dB (mean square)
    public var fr: Double     // spectral flux ratio since the previous call
}

public final class ChromaAnalyzer {
    public static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    public static func label(_ index: Int) -> String { noteNames[index >> 1] + (index & 1 == 1 ? "m" : "") }

    public let sampleRate: Double
    public static let bigN = 16384
    public static let smallN = 1024
    let big: MagnitudeFFT
    let small: MagnitudeFFT
    var smoothed: [Float]
    var prevSmall: [Float]
    let pitchBins: [[Int]]          // FFT bins of the first 4 harmonics of E2...E6 (MIDI 40...88)
    let templates: [[Double]]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        big = MagnitudeFFT(n: Self.bigN)
        small = MagnitudeFFT(n: Self.smallN)
        smoothed = [Float](repeating: 0, count: Self.bigN / 2)
        prevSmall = [Float](repeating: 0, count: Self.smallN / 2)
        var pm: [[Int]] = []
        let nb = Self.bigN / 2
        for p in 40...88 {
            let f = 440.0 * pow(2.0, Double(p - 69) / 12.0)
            var hs: [Int] = []
            for h in 1...4 {
                let k = Int((Double(h) * f * Double(Self.bigN) / sampleRate).rounded())
                if k > 0 && k < nb - 1 { hs.append(k) }
            }
            pm.append(hs)
        }
        pitchBins = pm
        var T: [[Double]] = []
        for r in 0..<12 {
            for third in [4, 3] {
                var v = [Double](repeating: 0, count: 12)
                v[r] = 1; v[(r + third) % 12] = 0.6; v[(r + 7) % 12] = 0.8
                let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
                T.append(v.map { $0 / n })
            }
        }
        templates = T
    }

    /// Clears the smoothing and flux history (new listening session).
    public func reset() {
        for i in smoothed.indices { smoothed[i] = 0 }
        for i in prevSmall.indices { prevSmall[i] = 0 }
    }

    /// `samples` must hold at least `bigN` of the most recent mono samples (oldest first).
    public func hear(_ samples: [Float]) -> HearResult {
        precondition(samples.count >= Self.bigN)
        let tail = samples.count - Self.bigN

        // Level: the browser read the last 2048 samples of the time-domain buffer.
        var e: Float = 0
        samples.withUnsafeBufferPointer { p in
            vDSP_svesq(p.baseAddress! + (samples.count - 2048), 1, &e, 2048)
        }
        let db = 10 * log10(Double(e) / 2048 + 1e-12)

        // Big spectrum with the AnalyserNode's exponential smoothing (time constant 0.35).
        let mag = samples.withUnsafeBufferPointer { big.magnitudes($0.baseAddress! + tail) }
        for k in 0..<smoothed.count { smoothed[k] = 0.35 * smoothed[k] + 0.65 * mag[k] }
        let F = smoothed

        var c = [Double](repeating: 0, count: 12)
        let HW: [Double] = [1, 0.8, 0.6, 0.5]
        var sal = [Double](repeating: 0, count: pitchBins.count)
        var fund = [Double](repeating: 0, count: pitchBins.count)
        for p in 0..<pitchBins.count {
            var s = 0.0
            for (h, k) in pitchBins[p].enumerated() {
                let a = Double(max(F[k - 1], F[k], F[k + 1]))
                if h == 0 { fund[p] = a }
                s += HW[h] * a
            }
            sal[p] = s
            c[(p + 40) % 12] += s
        }
        var bmax = 0.0, fmax = 0.0
        for p in 0...24 { bmax = max(bmax, sal[p]); fmax = max(fmax, fund[p]) }
        // lowest strong note; candidates without a fundamental (a ghost an octave below) don't count
        var bass = -1
        for p in 0...24 where sal[p] >= 0.6 * bmax && fund[p] >= 0.15 * fmax && bmax > 0 { bass = (p + 40) % 12; break }
        let n = sqrt(c.reduce(0) { $0 + $1 * $1 }) + 1e-12
        var sc = [Double](repeating: 0, count: 24)
        for ix in 0..<24 {
            var s = 0.0
            for i in 0..<12 { s += templates[ix][i] * c[i] }
            sc[ix] = s / n + ((ix >> 1) == bass ? 0.12 : 0)
        }
        var best = 0
        for i in 1..<24 where sc[i] > sc[best] { best = i }

        // Spectral flux on a short (1024) window: new energy / total energy, bins 2..239.
        let m2 = samples.withUnsafeBufferPointer { small.magnitudes($0.baseAddress! + (samples.count - Self.smallN)) }
        var flux = 0.0, tot = 0.0
        for k in 2..<240 {
            let m = Double(m2[k]), d = m - Double(prevSmall[k])
            if d > 0 { flux += d }
            tot += m
            prevSmall[k] = m2[k]
        }
        let fr = flux / (tot + 1e-9)
        return HearResult(sc: sc, best: best, bass: bass, loud: db > -52, db: db, fr: fr)
    }
}

/// Magnitude spectrum |X[k]| / N of a Blackman-windowed frame, k = 0 ..< N/2 (the AnalyserNode's scaling).
final class MagnitudeFFT {
    let n: Int
    let log2n: vDSP_Length
    let setup: FFTSetup
    let window: [Float]
    var re: [Float]
    var im: [Float]
    var frame: [Float]

    init(n: Int) {
        self.n = n
        log2n = vDSP_Length(log2(Double(n)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // Blackman, alpha 0.16 (the Web Audio definition)
        window = (0..<n).map { i in
            let x = Double(i) / Double(n)
            return Float(0.42 - 0.5 * cos(2 * .pi * x) + 0.08 * cos(4 * .pi * x))
        }
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
        frame = [Float](repeating: 0, count: n)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ x: UnsafePointer<Float>) -> [Float] {
        vDSP_vmul(x, 1, window, 1, &frame, 1, vDSP_Length(n))
        var out = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip packs DC in re[0] and Nyquist in im[0]; its output is 2x the DFT.
                let scale = 1 / (2 * Float(n))
                out[0] = abs(rp[0]) * scale
                for k in 1..<(n / 2) {
                    out[k] = sqrt(rp[k] * rp[k] + ip[k] * ip[k]) * scale
                }
            }
        }
        return out
    }
}
