import AppKit

/// Une série de captures (un passage sur tous les appareils choisis).
struct Shoot: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var date = Date()
    var dark = false
    var files: [String: String] = [:]      // appareil → nom du fichier PNG
    var folder: String = ""

    func image(_ device: String) -> URL? {
        files[device].map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
    }
}

@MainActor
final class ShotsModel: ObservableObject {
    @Published var url = ""
    @Published var selected: Set<String> = Device.defaultSelection
    @Published var fullPage = true
    @Published var dark = false
    @Published var shoots: [Shoot] = []
    @Published var current: Shoot?
    @Published var baseline: Shoot?
    @Published var progress: [String: String] = [:]     // appareil → « en cours » / « ok » / « échec »
    @Published var busy = false
    @Published var diffs: [String: DiffResult] = [:]
    @Published var error: String?
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AikoShots", isDirectory: true)
        url = UserDefaults.standard.string(forKey: "lastURL") ?? ""
        if let saved = UserDefaults.standard.array(forKey: "devices") as? [String], !saved.isEmpty { selected = Set(saved) }
        loadHistory()
    }

    var normalizedURL: URL? {
        let s = url.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("/") || s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if s.contains("://") { return URL(string: s) }
        if s.hasPrefix("localhost") || s.first?.isNumber == true { return URL(string: "http://" + s) }
        return URL(string: "https://" + s)
    }

    private var siteKey: String {
        guard let u = normalizedURL else { return "site" }
        let base = u.isFileURL ? u.deletingLastPathComponent().lastPathComponent : (u.host ?? "site") + u.path
        return base.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    func loadHistory() {
        var all: [Shoot] = []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let sites = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for s in sites {
                let dir = root.appendingPathComponent(s)
                for run in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    let f = dir.appendingPathComponent(run).appendingPathComponent("prises.json")
                    if var shoot = try? dec.decode(Shoot.self, from: Data(contentsOf: f)) {
                        shoot.folder = f.deletingLastPathComponent().path
                        all.append(shoot)
                    }
                }
            }
        }
        shoots = all.sorted { $0.date > $1.date }
    }

    /// Prises du même site (pour comparer).
    var sameSite: [Shoot] {
        guard let u = normalizedURL?.absoluteString else { return shoots }
        return shoots.filter { $0.url == u }
    }

    func capture() async {
        guard let u = normalizedURL else { error = "Entre l'adresse du site"; return }
        error = nil
        busy = true
        defer { busy = false }
        // Le site répond-il ? (message clair plutôt que des captures vides)
        if !u.isFileURL {
            var req = URLRequest(url: u, timeoutInterval: 12)
            req.httpMethod = "GET"
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    error = "Le site répond « erreur \(http.statusCode) ». Vérifie l'adresse."
                    return
                }
            } catch {
                self.error = "Le site ne répond pas. Vérifie l'adresse (et que le site local est bien lancé)."
                return
            }
        } else if !FileManager.default.fileExists(atPath: u.path) {
            error = "Fichier introuvable : \(u.path)"
            return
        }
        UserDefaults.standard.set(url, forKey: "lastURL")
        UserDefaults.standard.set(Array(selected), forKey: "devices")
        let previous = sameSite.first
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH'h'mm'm'ss"
        let dir = root.appendingPathComponent(siteKey).appendingPathComponent(f.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var shoot = Shoot(url: u.absoluteString, dark: dark, folder: dir.path)
        let devices = Device.all.filter { selected.contains($0.id) }
        progress = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, "attente") })
        for d in devices {
            progress[d.id] = "en cours"
            let shooter = Shooter(device: d, dark: dark)
            let img = await shooter.shoot(u, fullPage: fullPage)
            shooter.close()
            if let img, let png = img.pngData(width: d.width) {
                let name = d.id + ".png"
                try? png.write(to: dir.appendingPathComponent(name))
                shoot.files[d.id] = name
                progress[d.id] = "ok"
            } else {
                progress[d.id] = "échec"
            }
        }
        if shoot.files.isEmpty {
            error = "La page ne s'est pas chargée. Vérifie l'adresse (et que le site local est bien lancé)."
            try? FileManager.default.removeItem(at: dir)
            return
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(shoot).write(to: dir.appendingPathComponent("prises.json"))
        loadHistory()
        current = shoots.first { $0.id == shoot.id }
        baseline = previous
        await computeDiffs()
    }

    func computeDiffs() async {
        diffs = [:]
        guard let cur = current, let base = baseline, cur.id != base.id else { return }
        for (device, _) in cur.files {
            guard let a = base.image(device), let b = cur.image(device) else { continue }
            let r = await Task.detached { () -> DiffResult? in
                guard let ia = NSImage(contentsOf: a)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let ib = NSImage(contentsOf: b)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return Differ.compare(ia, ib)
            }.value
            if let r { diffs[device] = r }
        }
    }

    func reveal() {
        if let c = current { NSWorkspace.shared.open(URL(fileURLWithPath: c.folder)) }
    }
}
