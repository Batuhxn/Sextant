import XCTest

/// The native listening analysis must name the chord a guitar plays, like the web version did.
final class ChromaAnalyzerTests: XCTestCase {
    let sr = 48_000.0

    /// A plucked-string-like chord: each note with decaying harmonics, slightly detuned per string.
    func chord(_ midis: [Int], seconds: Double = 0.5, gain: Float = 0.2) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        for (j, m) in midis.enumerated() {
            let f = 440 * pow(2, Double(m - 69) / 12) * (1 + 0.0007 * Double(j))
            for h in 1...6 {
                let a = gain / Float(h * h) * (h == 1 ? 1 : 0.8)
                let w = 2 * Double.pi * f * Double(h) / sr
                for i in 0..<n { out[i] += a * Float(sin(w * Double(i))) * Float(exp(-Double(i) / sr * 1.5)) }
            }
        }
        return out
    }

    func lastFrame(_ x: [Float]) -> [Float] { Array(x.suffix(ChromaAnalyzer.bigN)) }

    func detect(_ x: [Float]) -> HearResult {
        let a = ChromaAnalyzer(sampleRate: sr)
        var r = a.hear(lastFrame(x))
        r = a.hear(lastFrame(x))  // smoothing settles
        return r
    }

    func testOpenChords() {
        // Guitar voicings (MIDI), low string first
        let cases: [(String, [Int])] = [
            ("C", [48, 52, 55, 60, 64]),          // x32010
            ("Am", [45, 52, 57, 60, 64]),         // x02210
            ("G", [43, 47, 50, 55, 59, 67]),      // 320003
            ("Em", [40, 47, 52, 55, 59, 64]),     // 022000
            ("D", [50, 57, 62, 66]),              // xx0232
            ("F#m", [42, 49, 54, 57, 61, 66]),    // 244222
            ("Bm", [47, 54, 59, 62, 66]),         // x24432
            ("C#m", [49, 56, 61, 64, 68]),        // x46654
        ]
        for (name, notes) in cases {
            let r = detect(chord(notes))
            XCTAssertTrue(r.loud, name)
            XCTAssertEqual(ChromaAnalyzer.label(r.best), name, "beklenen \(name)")
        }
    }

    func testSilenceIsNotLoud() {
        let r = detect([Float](repeating: 0, count: ChromaAnalyzer.bigN))
        XCTAssertFalse(r.loud)
    }

    func testOnsetRaisesFlux() {
        let a = ChromaAnalyzer(sampleRate: sr)
        let ring = chord([48, 52, 55, 60, 64], seconds: 1.0, gain: 0.05)
        // steady ringing: two consecutive frames 45 ms apart
        _ = a.hear(Array(ring[0..<ChromaAnalyzer.bigN]))
        let steady = a.hear(Array(ring[2160..<(2160 + ChromaAnalyzer.bigN)])).fr
        // a new strum arrives at the end of the next frame
        var hit = Array(ring[4320..<(4320 + ChromaAnalyzer.bigN)])
        let strum = chord([45, 52, 57, 60, 64], seconds: 0.03, gain: 0.4)
        for i in 0..<strum.count { hit[hit.count - strum.count + i] += strum[i] }
        let onset = a.hear(hit).fr
        XCTAssertGreaterThan(onset, max(0.22, 1.8 * steady), "flux \(onset) vs \(steady)")
    }

    func testLevelIsMeanSquareDB() {
        var x = [Float](repeating: 0, count: ChromaAnalyzer.bigN)
        for i in x.indices { x[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / sr)) }
        let r = ChromaAnalyzer(sampleRate: sr).hear(x)
        XCTAssertEqual(r.db, 10 * log10(0.005), accuracy: 0.3)  // sine of amplitude 0.1: mean square 0.005
    }
}
