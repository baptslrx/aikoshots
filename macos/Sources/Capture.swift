import AppKit
import WebKit

/// Un écran à simuler.
struct Device: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let mobile: Bool
    let symbol: String

    static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let iPadUA = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let androidUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36"

    var userAgent: String? {
        if id.hasPrefix("iphone") { return Self.iPhoneUA }
        if id.hasPrefix("ipad") { return Self.iPadUA }
        if id.hasPrefix("android") { return Self.androidUA }
        return nil
    }

    static let all: [Device] = [
        Device(id: "iphone-se", name: "iPhone SE", width: 375, height: 667, mobile: true, symbol: "iphone"),
        Device(id: "iphone-15", name: "iPhone 15", width: 393, height: 852, mobile: true, symbol: "iphone"),
        Device(id: "iphone-15-max", name: "iPhone 15 Pro Max", width: 430, height: 932, mobile: true, symbol: "iphone"),
        Device(id: "android-pixel", name: "Android (Pixel 8)", width: 412, height: 915, mobile: true, symbol: "smartphone"),
        Device(id: "android-small", name: "Android compact", width: 360, height: 780, mobile: true, symbol: "smartphone"),
        Device(id: "ipad-mini", name: "iPad mini", width: 744, height: 1133, mobile: true, symbol: "ipad"),
        Device(id: "ipad-air", name: "iPad Air", width: 820, height: 1180, mobile: true, symbol: "ipad"),
        Device(id: "ipad-landscape", name: "iPad à l'horizontale", width: 1180, height: 820, mobile: true, symbol: "ipad.landscape"),
        Device(id: "laptop-13", name: "Portable 13\"", width: 1280, height: 800, mobile: false, symbol: "laptopcomputer"),
        Device(id: "laptop-15", name: "Portable 15\"", width: 1440, height: 900, mobile: false, symbol: "laptopcomputer"),
        Device(id: "desktop-hd", name: "Écran Full HD", width: 1920, height: 1080, mobile: false, symbol: "display"),
        Device(id: "desktop-27", name: "Écran 27\"", width: 2560, height: 1440, mobile: false, symbol: "display"),
    ]

    static let defaultSelection: Set<String> = ["iphone-se", "iphone-15", "android-pixel", "ipad-air", "laptop-13", "desktop-hd"]
}

/// Capture d'une page entière dans un vrai moteur Safari (WebKit), à la taille d'un appareil.
@MainActor
final class Shooter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private let window: NSWindow
    private let web: WKWebView

    init(device: Device, dark: Bool) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: device.width, height: device.height), configuration: config)
        web.customUserAgent = device.userAgent
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Une fenêtre hors de l'écran : WebKit dessine comme si la page était affichée
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: device.width, height: device.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.appearance = web.appearance
        super.init()
        web.navigationDelegate = self
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }

    func load(_ url: URL) async -> Bool {
        await withCheckedContinuation { c in
            continuation = c
            if url.isFileURL {
                web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    private func finish(_ ok: Bool) {
        continuation?.resume(returning: ok)
        continuation = nil
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func number(_ js: String) async -> Double {
        let v = try? await web.evaluateJavaScript(js)
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    /// Charge, fait défiler (pour les images chargées à la demande), puis photographie la page entière.
    func shoot(_ url: URL, fullPage: Bool) async -> NSImage? {
        guard await load(url) else { return nil }
        await sleep(0.6)
        let viewportH = web.frame.height
        var height = await number("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        if fullPage && height > viewportH {
            var y = 0.0
            while y < height {
                _ = try? await web.evaluateJavaScript("window.scrollTo(0, \(y))")
                await sleep(0.08)
                y += viewportH
            }
            _ = try? await web.evaluateJavaScript("window.scrollTo(0, 0)")
            await sleep(0.3)
            height = await number("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
            let full = min(max(height, viewportH), 16000)
            var f = web.frame
            f.size.height = full
            window.setContentSize(f.size)
            web.frame = f
            await sleep(0.5)
        }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = web.bounds
        cfg.afterScreenUpdates = true
        return await withCheckedContinuation { c in
            web.takeSnapshot(with: cfg) { img, _ in c.resume(returning: img) }
        }
    }
}

extension NSImage {
    /// Image en pixels réels (1 point = 1 pixel) pour des fichiers à la bonne taille.
    func pngData(width: Int) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = Double(width) / Double(cg.width)
        let h = Int((Double(cg.height) * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: NSSize(width: width, height: h)).draw(in: NSRect(x: 0, y: 0, width: width, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
