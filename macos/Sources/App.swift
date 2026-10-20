import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct AikoShotsMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let test = SelfTest(outDir: URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : "screenshots"))
            app.setActivationPolicy(.regular)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let model = ShotsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: ShotsView(model: model)))
        w.title = "AikoShots"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 1180, height: 760))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ShotsView: View {
    @ObservedObject var model: ShotsModel
    @State private var detail: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                toolbar
                devicePicker
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
                }
                if model.busy { progressView } else if let cur = model.current { gallery(cur) } else { intro }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Theme.line(scheme)).frame(width: 1)
            history.frame(width: 250)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Theme.background(scheme))
        .sheet(item: Binding(get: { detail.map(DetailID.init) }, set: { detail = $0?.id })) { d in
            DetailView(model: model, device: d.id) { detail = nil }
        }
    }

    struct DetailID: Identifiable { let id: String }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.fill").font(.system(size: 22)).foregroundStyle(Theme.accentText(scheme))
            TextField("Adresse du site (https://monsite.fr, localhost:8080…)", text: $model.url)
                .textFieldStyle(.roundedBorder).font(.system(size: 14))
                .onSubmit { Task { await model.capture() } }
            Button { pickFile() } label: { Image(systemName: "folder") }.help("Choisir un fichier HTML sur le Mac")
            Toggle("Page entière", isOn: $model.fullPage).toggleStyle(.checkbox)
            Toggle("Mode sombre", isOn: $model.dark).toggleStyle(.checkbox)
            Button { Task { await model.capture() } } label: { Label("Capturer", systemImage: "camera.fill") }
                .keyboardShortcut(.defaultAction).tint(Theme.accentUI).controlSize(.large)
                .disabled(model.busy || model.url.isEmpty || model.selected.isEmpty)
        }
    }

    private var devicePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Device.all) { d in
                    let on = model.selected.contains(d.id)
                    Button {
                        if on { model.selected.remove(d.id) } else { model.selected.insert(d.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: d.symbol).font(.system(size: 11))
                            Text(d.name).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(on ? Theme.onAccent : Color.secondary)
                        .background(Capsule().fill(on ? Theme.accentUI : Theme.surface(scheme)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group").font(.system(size: 44)).foregroundStyle(Theme.accentText(scheme))
            Text("Ton site sur tous les écrans, d'un coup").font(.system(size: 18, weight: .semibold))
            Text("Entre une adresse et clique sur Capturer. À chaque nouvelle capture, AikoShots montre ce qui a changé.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Device.all.filter { model.progress[$0.id] != nil }) { d in
                HStack {
                    Image(systemName: d.symbol).frame(width: 20)
                    Text(d.name).font(.system(size: 13))
                    Spacer()
                    switch model.progress[d.id] {
                    case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentText(scheme))
                    case "échec": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case "en cours": ProgressView().controlSize(.small)
                    default: Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gallery(_ shoot: Shoot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(shoot.url).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.sameSite.count > 1 {
                    Text("Comparer avec").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { model.baseline?.id }, set: { id in
                        model.baseline = model.shoots.first { $0.id == id }
                        Task { await model.computeDiffs() }
                    })) {
                        Text("Rien").tag(UUID?.none)
                        ForEach(model.sameSite.filter { $0.id != shoot.id }) { s in
                            Text(s.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year().hour().minute())).tag(UUID?.some(s.id))
                        }
                    }
                    .labelsHidden().frame(width: 200)
                }
                Button { model.reveal() } label: { Image(systemName: "folder") }.help("Ouvrir le dossier des captures")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], alignment: .leading, spacing: 18) {
                    ForEach(Device.all.filter { shoot.files[$0.id] != nil }) { d in
                        card(shoot, d).onTapGesture { detail = d.id }
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func card(_ shoot: Shoot, _ d: Device) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme))
                if let u = shoot.image(d.id), let img = NSImage(contentsOf: u) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 300, alignment: .top).clipped()
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(diffColor(d.id) ?? Theme.line(scheme), lineWidth: diffColor(d.id) == nil ? 1 : 2))
            HStack(spacing: 6) {
                Image(systemName: d.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(d.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let r = model.diffs[d.id] {
                    Text(r.unchanged ? "Identique" : String(format: "%.0f %% changé", max(1, r.percent)))
                        .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((r.unchanged ? Theme.accentUI : Color.red).opacity(0.18)))
                        .foregroundStyle(r.unchanged ? Theme.accentText(scheme) : Color.red)
                }
            }
            Text("\(d.width) × \(d.height)").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func diffColor(_ device: String) -> Color? {
        guard let r = model.diffs[device], !r.unchanged else { return nil }
        return .red
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HISTORIQUE").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accentText(scheme))
                .padding(.horizontal, 14).padding(.top, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.shoots.prefix(60)) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.date.formatted(.dateTime.locale(Locale(identifier: "fr_FR")).day().month(.abbreviated).year().hour().minute())).font(.system(size: 12, weight: .medium))
                            Text(s.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(s.id == model.current?.id ? Theme.accentUI.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.url = s.url
                            model.current = s
                            model.baseline = model.sameSite.first { $0.date < s.date }
                            Task { await model.computeDiffs() }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .background(Theme.surface(scheme).opacity(0.5))
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.html]
        guard p.runModal() == .OK, let u = p.url else { return }
        model.url = u.path
    }
}

/// Avant / après côte à côte, avec les zones modifiées entourées.
struct DetailView: View {
    @ObservedObject var model: ShotsModel
    let device: String
    var onClose: () -> Void
    @State private var showZones = true

    var body: some View {
        let d = Device.all.first { $0.id == device }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(d?.name ?? device).font(.system(size: 16, weight: .semibold))
                if let r = model.diffs[device] {
                    Text(r.unchanged ? "Identique" : "\(r.regions.count) zone\(r.regions.count > 1 ? "s" : "") modifiée\(r.regions.count > 1 ? "s" : "")")
                        .foregroundStyle(r.unchanged ? Color.secondary : Color.red).font(.system(size: 12))
                }
                Spacer()
                Toggle("Entourer les changements", isOn: $showZones).toggleStyle(.checkbox)
                Button("Fermer") { onClose() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    if let b = model.baseline?.image(device), let img = NSImage(contentsOf: b) {
                        column("Avant", img)
                    }
                    if let a = model.current?.image(device), let img = NSImage(contentsOf: a) {
                        column("Après", zones(img))
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 1000, height: 720)
    }

    private func zones(_ img: NSImage) -> NSImage {
        guard showZones, let r = model.diffs[device], !r.unchanged,
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return img }
        return Differ.overlay(cg, r)
    }

    private func column(_ title: String, _ img: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 470)
                .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        }
    }
}
