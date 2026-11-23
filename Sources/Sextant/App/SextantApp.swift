import AVFoundation
import SwiftUI
import UIKit
import WebKit

@main
struct SextantApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.open($0) }
        }
    }
}

/// App state: the local server's port and pairing messages for the user.
final class AppModel: ObservableObject {
    @Published var port: UInt16 = 0
    @Published var banner: String?
    weak var web: WKWebView?

    init() {
        // The song should keep playing with the ring/silent switch on (it's a practice tool).
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        LocalServer.shared.start { [weak self] p in self?.port = p }
        AppRouter.shared.onPaired = { [weak self] in
            DispatchQueue.main.async { self?.web?.evaluateJavaScript("window.__sextantPaired && window.__sextantPaired()") }
        }
    }

    /// sextant://pair?u=...&t=... from the QR code on the computer.
    func open(_ url: URL) {
        guard let link = PairLink.parse(url) else { banner = "Bu bağlantı Sextant eşleme bağlantısı değil."; return }
        banner = "Bilgisayara bağlanılıyor…"
        Task { @MainActor in
            if let err = await AppRouter.shared.pair(server: link.server, token: link.token) {
                self.banner = err
            } else {
                self.banner = "Bilgisayara bağlandı."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if self.banner == "Bilgisayara bağlandı." { self.banner = nil } }
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.port != 0 {
                WebContainer(port: model.port, model: model).ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView("Sextant açılıyor…")
            }
            if let b = model.banner {
                Text(b)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .onTapGesture { model.banner = nil }
            }
        }
    }
}

struct WebContainer: UIViewRepresentable {
    let port: UInt16
    let model: AppModel

    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        // Tells the page it runs inside the app (before its own script runs).
        ucc.addUserScript(WKUserScript(source: "window.SEXTANT = { native: true, version: '\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")' };",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(context.coordinator, name: "sextant")
        cfg.userContentController = ucc
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.isOpaque = false
        w.backgroundColor = .systemBackground
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.allowsBackForwardNavigationGestures = true
        #if DEBUG
        if #available(iOS 16.4, *) { w.isInspectable = true }
        #endif
        w.uiDelegate = context.coordinator  // JS alert/confirm/prompt (e.g. "Sil" asks confirm)
        context.coordinator.web = w
        model.web = w
        w.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Messages from the page (window.webkit.messageHandlers.sextant) and listening results back to it.
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?

    override init() {
        super.init()
        let mic = MicListener.shared
        mic.onResult = { [weak self] r, seq in
            let obj: [String: Any] = ["sc": r.sc, "best": r.best, "bass": r.bass, "loud": r.loud, "db": r.db, "fr": r.fr, "seq": seq]
            guard let d = try? JSONSerialization.data(withJSONObject: obj), let js = String(data: d, encoding: .utf8) else { return }
            self?.web?.evaluateJavaScript("window.__nativeHear && window.__nativeHear(\(js))")
        }
        mic.onError = { [weak self] msg in
            guard let d = try? JSONSerialization.data(withJSONObject: [msg]), let js = String(data: d, encoding: .utf8) else { return }
            self?.web?.evaluateJavaScript("window.__nativeListenError && window.__nativeListenError(\(js)[0])")
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let o = message.body as? [String: Any], let cmd = o["cmd"] as? String else { return }
        switch cmd {
        case "listenStart": MicListener.shared.start(monitor: o["monitor"] as? Bool ?? false)
        case "listenStop": MicListener.shared.stop()
        case "monitor": MicListener.shared.setMonitor(o["on"] as? Bool ?? false)
        default: break
        }
    }
}

// WKWebView shows no alert/confirm/prompt unless the UI delegate presents them;
// without this, confirm() silently returns false and the page's delete does nothing.
extension Bridge: WKUIDelegate {
    private func presenter() -> UIViewController? {
        var vc = web?.window?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let vc = presenter() else { return completionHandler() }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler() })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let vc = presenter() else { return completionHandler(false) }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Vazgeç", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "Tamam", style: .destructive) { _ in completionHandler(true) })
        vc.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let vc = presenter() else { return completionHandler(nil) }
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Vazgeç", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "Tamam", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        vc.present(a, animated: true)
    }
}
