# Sextant

iPhone companion for **Kılavuz**, the guitar practice app that runs on your computer: pick any song,
see its chords over the lyrics, play along, and let Sextant listen through the microphone.

- The computer does the heavy work (source separation, chord, beat and lyrics analysis).
- The phone plays the song (full mix, without guitar, guitar only; slower speeds), shows chords,
  chord diagrams (left-handed mirror), lyrics with chords and the strumming pattern, and listens to
  you play with its own microphone.
- Songs you download to the phone keep working when the computer is off.

## How it is built

The interface is the same web page Kılavuz uses on the computer (`Sources/Sextant/Web/index.html`),
served to a `WKWebView` from a small HTTP server inside the app on `127.0.0.1`. That server answers
from songs stored on the phone and forwards everything else to Kılavuz with the pairing key.

Listening does not use the web view's microphone: `MicListener` opens the microphone with
`AVAudioEngine` in measurement mode (no voice processing), `ChromaAnalyzer` computes the same
harmonic chroma and spectral flux as the web version, and the page keeps its chord decision rule.

| Path | What |
|---|---|
| `Sources/Sextant/App` | app, web view bridge, local server, router, downloads, microphone |
| `Sources/Sextant/Core` | pure logic with unit tests: listening analysis, HTTP parsing, song list |
| `Tests/SextantTests` | unit tests (run in CI on an iOS simulator) |
| `.github/workflows/ci.yml` | simulator build + tests on every push (no signing) |
| `.github/workflows/testflight.yml` | signed IPA, optional upload to TestFlight (manual) |

## Pairing with the computer

1. On the computer, open Kılavuz and press **📱 Telefona bağla**.
2. Scan the QR code with the iPhone camera and tap the link (`sextant://pair?...`).
3. Phone and computer must be on the same Wi‑Fi. If Windows Firewall asks about Python, allow
   private networks.

The pairing key protects Kılavuz on the home network: requests that do not come from the computer
itself must carry it.

## TestFlight (no Mac needed)

One-time setup in the Apple Developer account:

1. **Identifiers** → register App ID `com.batuhxn.sextant` (no extra capabilities).
2. **Profiles** → new *App Store Connect* distribution profile for that App ID, using the existing
   Apple Distribution certificate, named exactly **Sextant App Store Connect**.
3. **App Store Connect** → My Apps → **+ New App**: iOS, name *Sextant* (or another free name),
   bundle ID `com.batuhxn.sextant`, SKU `sextant`.
4. Repository **Settings → Secrets and variables → Actions**, the same secrets as the Watchlink
   pipeline: `APPLE_TEAM_ID`, `IOS_DIST_P12_B64`, `IOS_DIST_P12_PASSWORD`, `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_B64`, and the new profile as `IOS_PROFILE_B64`
   (`base64 -w0 profile.mobileprovision`).

Then run **Actions → Sextant signed IPA (TestFlight) → Run workflow** with *upload* checked. After
Apple finishes processing (usually 10–30 minutes) the build appears in TestFlight on the phone.
