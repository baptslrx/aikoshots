import AppKit
import SwiftUI

/// `AikoShots --selftest <dossier>` : vrai site (local) capturé sur plusieurs appareils, modification, comparaison.
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

    init(outDir: URL) { self.outDir = outDir }

    func run() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            await steps()
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
            MainActor.assumeIsolated { self?.check(false, "le test a dépassé 4 minutes"); self?.finish() }
        }
    }

    private func log(_ s: String) { print(s); fflush(stdout); report.append(s) }
    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failures.append(what); if ci { print("::error title=Test::\(what)") } }
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func page(title: String, button: String) -> String {
        let cards = (1...6).map { i in
            "<div class=card><div class=img></div><h3>Projet \(i)</h3><p>Montage, étalonnage et motion design pour une marque de sport.</p></div>"
        }.joined()
        return """
        <!doctype html><html lang=fr><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <style>
        body{margin:0;font:16px -apple-system,sans-serif;color:#111;background:#fff}
        header{display:flex;justify-content:space-between;align-items:center;padding:20px 40px;background:#0A0A0C;color:#fff}
        nav a{color:#fff;margin-left:24px;text-decoration:none}
        .hero{padding:80px 40px;background:linear-gradient(135deg,#7DC8FF,#1F7FC8);color:#05121C}
        .hero h1{font-size:56px;margin:0 0 16px} .btn{display:inline-block;padding:14px 26px;border-radius:999px;background:\(button);color:#fff}
        .grid{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;padding:40px}
        .card{border:1px solid #ddd;border-radius:14px;padding:16px} .img{height:160px;border-radius:10px;background:#E8F4FD}
        footer{padding:40px;background:#f2f2f2;text-align:center}
        @media (max-width:700px){header{flex-direction:column;gap:10px} nav a{margin:0 8px} .hero{padding:48px 20px} .hero h1{font-size:34px}
          .grid{grid-template-columns:1fr;padding:20px}}
        </style></head><body>
        <header><strong>Aikographic</strong><nav><a href=#>Projets</a><a href=#>Studio</a><a href=#>Contact</a></nav></header>
        <section class=hero><h1>\(title)</h1><p>Vidéaste et designer à Paris.</p><a class=btn href=#>Voir les projets</a></section>
        <section class=grid>\(cards)</section><footer>© 2026 Aikographic</footer></body></html>
        """
    }

    private func steps() async {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("aikoshots-\(UUID().uuidString)")
        let site = tmp.appendingPathComponent("site")
        try? fm.createDirectory(at: site, withIntermediateDirectories: true)
        let index = site.appendingPathComponent("index.html")
        try? Self.page(title: "Des images qui bougent", button: "#0A0A0C").write(to: index, atomically: true, encoding: .utf8)

        let model = ShotsModel(root: tmp.appendingPathComponent("captures"))
        model.url = index.path
        model.selected = ["iphone-se", "ipad-air", "desktop-hd"]

        log("== 1re capture")
        let t0 = Date()
        await model.capture()
        log(String(format: "   3 appareils en %.1f s", Date().timeIntervalSince(t0)))
        guard let first = model.current else { check(false, "capture : \(model.error ?? "rien")"); return }
        check(first.files.count == 3, "3 captures enregistrées")
        func size(_ s: Shoot, _ d: String) -> CGSize {
            guard let u = s.image(d), let img = NSImage(contentsOf: u), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return .zero }
            return CGSize(width: cg.width, height: cg.height)
        }
        let phone = size(first, "iphone-se"), desktop = size(first, "desktop-hd")
        log("   iPhone SE : \(Int(phone.width))×\(Int(phone.height)) · Full HD : \(Int(desktop.width))×\(Int(desktop.height))")
        check(phone.width == 375 && desktop.width == 1920, "largeurs exactes des appareils")
        check(phone.height > 1800, "page entière sur téléphone (\(Int(phone.height)) px de haut, plus que l'écran)")
        check(phone.height > desktop.height, "la mise en page mobile (colonnes empilées) est bien plus haute que sur ordinateur")

        log("== Modification du site, 2e capture")
        try? Self.page(title: "Des images qui vivent", button: "#FF6B6B").write(to: index, atomically: true, encoding: .utf8)
        await model.capture()
        check(model.baseline?.id == first.id, "comparée automatiquement avec la capture précédente")
        for (d, r) in model.diffs.sorted(by: { $0.key < $1.key }) {
            log(String(format: "   %@ : %.1f %% changé, %d zone(s)", d, r.percent, r.regions.count))
        }
        let phoneDiff = model.diffs["iphone-se"]
        check(phoneDiff.map { !$0.unchanged && $0.percent < 25 && !$0.regions.isEmpty } ?? false,
              "changements repérés (titre et bouton) sans tout marquer")
        if let r = phoneDiff { check(r.regions.allSatisfy { $0.minY < 700 }, "les zones modifiées sont en haut de page, là où on a changé") }
        await snapshot(ShotsView(model: model), name: "galerie", size: NSSize(width: 1180, height: 760))
        await snapshot(DetailView(model: model, device: "desktop-hd", onClose: {}), name: "avant-apres", size: NSSize(width: 1000, height: 720))

        log("== 3e capture sans rien changer")
        await model.capture()
        check(model.diffs.values.allSatisfy(\.unchanged) && model.diffs.count == 3, "rien n'a changé → « Identique » partout")

        log("== Adresse impossible")
        model.url = "http://127.0.0.1:9"
        model.selected = ["iphone-se"]
        await model.capture()
        check(model.error != nil, "message clair : \(model.error ?? "")")
        try? fm.removeItem(at: tmp)
    }

    private func snapshot<V: View>(_ view: V, name: String, size: NSSize) async {
        for dark in [true, false] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            w.orderFrontRegardless()
            await sleep(1.5)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = "\(name)-\(dark ? "sombre" : "clair").png"
                try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(file))
                log("   capture \(file)")
            }
            w.orderOut(nil)
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
