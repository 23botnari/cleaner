import Foundation

enum Risk: Sendable {
    /// safe = sigur, care = cere confirmare, suspect = euristică zgomotoasă, doar la cerere.
    case safe, care, suspect
    var label: String {
        switch self {
        case .safe: "Sigur"
        case .care: "Atenție"
        case .suspect: "Suspect"
        }
    }
}

struct CleanTarget: Identifiable, Sendable {
    let id: String
    let group: String
    let name: String
    let desc: String
    var risk: Risk = .safe
    /// Tipare pentru `pgrep -f`: dacă vreunul rulează, curățarea e refuzată.
    var procs: [String] = []
    var appName: String? = nil
    /// Se suprapune cu alt element (nu intră în totalul „se poate elibera”).
    var overlap = false
    /// Se mută la Coș în loc să se șteargă (fișiere ale utilizatorului: descărcări, duplicate).
    var trash = false
    var resolve: @Sendable () -> [String] = { [] }
    var cmds: [[String]] = []
    var sizePaths: [String] = []
    var fixedSize: Int64? = nil

    var isVisible: Bool {
        if let fixedSize { return fixedSize > 0 }
        return !resolve().isEmpty || !Paths.existing(sizePaths).isEmpty
    }

    func size() -> Int64 {
        if let fixedSize { return fixedSize }
        return Sizer.du(resolve() + sizePaths)
    }
}

enum Targets {
    private static let AS = Paths.hp("Library", "Application Support")
    private static let dev = Paths.hp("Library", "Developer")
    private static let xcrun = "/usr/bin/xcrun"

    static func filesMatching(_ dir: String, exts: Set<String>) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let rel = en.nextObject() as? String {
            if exts.contains((rel as NSString).pathExtension.lowercased()) {
                out.append(Paths.join(dir, rel))
            }
        }
        return out
    }

    static func staticTargets() -> [CleanTarget] {
        var L: [CleanTarget] = []
        let AS = Self.AS, dev = Self.dev

        var g = "Aplicații de chat"
        L.append(CleanTarget(
            id: "whatsapp", group: g, name: "WhatsApp: date locale (media + chat-uri)",
            desc: "Toate pozele, video-urile și fișierele primite pe WhatsApp, salvate pe Mac. "
                + "Înainte: în WhatsApp → Settings → Account → Log out, apoi închide aplicația. "
                + "La reconectare, chat-urile recente revin de pe telefon; media veche rămâne doar pe telefon.",
            risk: .care, procs: ["WhatsApp.app/Contents/MacOS"], appName: "WhatsApp",
            resolve: { Paths.existing([Paths.hp("Library", "Group Containers", "group.net.whatsapp.WhatsApp.shared")]) }))
        L.append(CleanTarget(
            id: "telegram", group: g, name: "Telegram: media în cache",
            desc: "Fișiere descărcate din chat-uri. Rămân în cloud-ul Telegram și se descarcă din nou la nevoie.",
            procs: ["Telegram.app/Contents/MacOS"], appName: "Telegram",
            resolve: { Paths.existing([Paths.join(AS, "Telegram Desktop", "tdata", "user_data")]) }))
        L.append(CleanTarget(
            id: "discord", group: g, name: "Discord: cache",
            desc: "Imagini și fișiere temporare. Discord le refolosește doar ca să încarce mai repede.",
            procs: ["Discord.app/Contents/MacOS"], appName: "Discord",
            resolve: { Paths.existing(["Cache", "Code Cache", "GPUCache"].map { Paths.join(AS, "discord", $0) }) }))

        g = "Dezvoltare"
        L.append(CleanTarget(
            id: "npm", group: g, name: "npm: cache",
            desc: "Pachete descărcate anterior. Se redescarcă automat la următorul npm install.",
            resolve: { Paths.existing([Paths.hp(".npm", "_cacache"), Paths.hp(".npm", "_npx"), Paths.hp(".npm", "_logs")]) }))
        L.append(CleanTarget(
            id: "gradle", group: g, name: "Gradle: cache și distribuții",
            desc: "Dependențe Android și versiuni Gradle descărcate. Primul build după curățare va dura mai mult.",
            procs: ["GradleDaemon"], appName: "Android Studio / Gradle (sau rulează ./gradlew --stop)",
            resolve: { Paths.existing([Paths.hp(".gradle", "caches"), Paths.hp(".gradle", "wrapper", "dists"), Paths.hp(".gradle", "daemon")]) }))
        L.append(CleanTarget(
            id: "pnpm", group: g, name: "pnpm: store",
            desc: "Depozitul global de pachete pnpm. Se reface la următorul pnpm install.",
            resolve: { Paths.existing([Paths.hp("Library", "pnpm", "store")]) }))
        L.append(CleanTarget(
            id: "deriveddata", group: g, name: "Xcode: DerivedData",
            desc: "Fișiere de build. Xcode le regenerează la următorul build.",
            procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "DerivedData")) }))
        L.append(CleanTarget(
            id: "devicesupport", group: g, name: "Xcode: suport pentru dispozitive",
            desc: "Simboluri copiate de pe iPhone-urile conectate vreodată. Se recopiază când conectezi din nou un dispozitiv.",
            procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "iOS DeviceSupport"))
                + Paths.children(Paths.join(dev, "Xcode", "watchOS DeviceSupport")) }))
        L.append(CleanTarget(
            id: "archives", group: g, name: "Xcode: arhive",
            desc: "Build-uri trimise în App Store / TestFlight. Păstrează-le dacă ai nevoie de rapoarte de crash simbolizate pentru versiuni publicate.",
            risk: .care, procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "Archives")) }))

        g = "Simulatoare iOS"
        let cs = Paths.join(dev, "CoreSimulator")
        L.append(CleanTarget(
            id: "simcaches", group: g, name: "Simulatoare: cache",
            desc: "Fișiere temporare ale simulatoarelor. Se refac automat.",
            resolve: { Paths.children(Paths.join(cs, "Caches")) }))
        if FileManager.default.isExecutableFile(atPath: xcrun) && Paths.isDir(Paths.join(cs, "Devices")) {
            L.append(CleanTarget(
                id: "simerase", group: g, name: "Simulatoare: resetează toate",
                desc: "Șterge aplicațiile și datele din toate simulatoarele și elimină simulatoarele pentru versiuni iOS care nu mai există. "
                    + "Simulatoarele rămân în listă, ca noi.",
                risk: .care, procs: ["Simulator.app/Contents/MacOS"], appName: "Simulator",
                cmds: [["/bin/sh", "-c", "/usr/bin/xcrun simctl shutdown all >/dev/null 2>&1; true"],
                       [xcrun, "simctl", "delete", "unavailable"],
                       [xcrun, "simctl", "erase", "all"]],
                sizePaths: [Paths.join(cs, "Devices")]))
        }

        g = "Sistem și altele"
        L.append(CleanTarget(
            id: "wallpapers", group: g, name: "Wallpapere Aerial descărcate",
            desc: "Video-urile pentru wallpapere și screensaver-e animate. Cel folosit acum se descarcă din nou automat.",
            resolve: { filesMatching(Paths.join(AS, "com.apple.wallpaper"), exts: ["mov", "mp4"]) }))
        L.append(CleanTarget(
            id: "dockerinstall", group: g, name: "Docker: kit de instalare rămas",
            desc: "Fișiere rămase după instalarea Docker Desktop. Docker funcționează și fără ele.",
            resolve: { Paths.existing([Paths.join(AS, "com.docker.install")]) }))
        L.append(CleanTarget(
            id: "vscode", group: g, name: "VS Code: cache",
            desc: "Cache-uri și log-uri. Setările, extensiile și proiectele nu sunt atinse.",
            procs: ["Visual Studio Code.app/Contents/MacOS"], appName: "VS Code",
            resolve: { Paths.existing(["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                .map { Paths.join(AS, "Code", $0) }) }))
        L.append(CleanTarget(
            id: "usercaches", group: g, name: "Cache-uri aplicații (~/Library/Caches)",
            desc: "Cache-urile tuturor aplicațiilor (browsere, Homebrew, CocoaPods etc.). Se refac singure; unele aplicații pot porni mai încet o dată. "
                + "Închide cât mai multe aplicații înainte și repornește Mac-ul după.",
            risk: .care,
            resolve: { Paths.children(Paths.hp("Library", "Caches")) }))
        L.append(CleanTarget(
            id: "logs", group: g, name: "Log-uri",
            desc: "Jurnale de erori și diagnostic ale aplicațiilor.",
            resolve: { Paths.children(Paths.hp("Library", "Logs")) }))
        L.append(CleanTarget(
            id: "trash", group: g, name: "Coșul (Bin)",
            desc: "Golește Coșul definitiv. Ce e acolo nu mai poate fi recuperat.",
            risk: .care,
            resolve: { Paths.children(Paths.hp(".Trash")) }))
        return L
    }

    static func claudeTargets() -> [CleanTarget] {
        var L: [CleanTarget] = []
        let g = "Claude"
        let cl = Paths.join(AS, "Claude")
        let desktop = ["Claude.app/Contents/MacOS/Claude"]
        L.append(CleanTarget(
            id: "claude-cache", group: g, name: "Claude Desktop: cache",
            desc: "Cache-uri ale interfeței (imagini, cod compilat, GPU). Conversațiile și setările nu sunt atinse; se refac automat.",
            procs: desktop, appName: "aplicația Claude (Claude → Quit)",
            resolve: { Paths.existing(["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "blob_storage"]
                .map { Paths.join(cl, $0) } + [Paths.hp("Library", "Caches", "com.anthropic.claudefordesktop.ShipIt")]) }))
        L.append(CleanTarget(
            id: "claude-vm", group: g, name: "Claude Desktop: mașina virtuală",
            desc: "Imaginea Linux folosită de Claude pentru lucru în sandbox (Cowork / agent). "
                + "Se descarcă din nou automat prima dată când e nevoie de ea (câțiva GB).",
            risk: .care, procs: desktop, appName: "aplicația Claude (Claude → Quit)",
            resolve: { Paths.existing([Paths.join(cl, "vm_bundles")]) }))
        let cc = Paths.hp(".claude")
        L.append(CleanTarget(
            id: "claudecode-temp", group: g, name: "Claude Code: fișiere temporare",
            desc: "Snapshot-uri de shell, cache, istoric de fișiere pentru undo, log-uri de debug și cache-ul CLI. "
                + "Setările, skill-urile, plugin-urile și conversațiile rămân.",
            procs: ["=claude"], appName: "toate sesiunile Claude Code (inclusiv cele din Claude Desktop)",
            resolve: { Paths.existing(["shell-snapshots", "paste-cache", "cache", "debug", "telemetry", "file-history", "statsig"]
                .map { Paths.join(cc, $0) } + [Paths.hp("Library", "Caches", "claude-cli-nodejs")]) }))
        L.append(CleanTarget(
            id: "claudecode-old", group: g, name: "Claude Code: conversații mai vechi de 30 de zile",
            desc: "Transcrieri ale sesiunilor vechi din ~/.claude/projects. După ștergere nu mai poți relua (--resume) acele sesiuni.",
            risk: .care, procs: ["=claude"], appName: "toate sesiunile Claude Code (inclusiv cele din Claude Desktop)",
            resolve: {
                let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
                return Paths.children(Paths.join(cc, "projects")).flatMap { proj in
                    Paths.children(proj).filter { p in
                        guard let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return false }
                        return m < cutoff
                    }
                }
            }))
        return L
    }

    static let dockerCLI: String? = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                     "/Applications/Docker.app/Contents/Resources/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// „1.23GB (45%)” → bytes (Docker afișează unități zecimale).
    static func parseDockerSize(_ s: String) -> Int64 {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let num = token.prefix { "0123456789.".contains($0) }
        let unit = token.dropFirst(num.count).uppercased()
        let mult: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 0
        return Int64((Double(num) ?? 0) * mult)
    }

    /// Doar dacă Docker Desktop rulează (altfel CLI-ul nu poate calcula nimic).
    static func dockerTargets() -> [CleanTarget] {
        guard let docker = dockerCLI else { return [] }
        let r = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20)
        guard r.code == 0 else { return [] }
        var total: Int64 = 0
        for line in r.out.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let rec = o["Reclaimable"] as? String else { continue }
            total += parseDockerSize(rec)
        }
        return [CleanTarget(
            id: "docker-prune", group: "Dezvoltare", name: "Docker: imagini, containere oprite și cache de build nefolosite",
            desc: "Rulează „docker system prune -a”. Volumele (bazele de date din containere) NU sunt atinse. "
                + "Imaginile se descarcă din nou la nevoie. Docker.raw se micșorează după repornirea Docker.",
            risk: .care,
            cmds: [[docker, "system", "prune", "-af"]],
            fixedSize: total)]
    }

    static func androidTargets() -> [CleanTarget] {
        var L: [CleanTarget] = []
        let g = "Android"
        let avdDir = Paths.hp(".android", "avd")
        let avds = Paths.children(avdDir).filter { $0.hasSuffix(".avd") }.sorted()
        for avd in avds {
            let base = String(avd.dropLast(4))
            let name = (base as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let snaps = Paths.join(avd, "snapshots")
            if Paths.isDir(snaps) {
                L.append(CleanTarget(
                    id: "avdsnap:" + avd, group: g, name: "Emulator \(name): snapshot-uri",
                    desc: "Stări salvate pentru Quick Boot. Emulatorul pornește la rece prima dată; aplicațiile și datele din el rămân.",
                    procs: ["qemu-system"], appName: "emulatorul Android",
                    resolve: { Paths.children(snaps) }))
            }
            L.append(CleanTarget(
                id: "avd:" + avd, group: g, name: "Emulator \(name): șterge complet",
                desc: "Șterge emulatorul cu tot cu datele lui. Îl poți crea din nou din Android Studio → Device Manager.",
                risk: .care, procs: ["qemu-system"], appName: "emulatorul Android", overlap: true,
                resolve: { Paths.existing([avd, base + ".ini"]) }))
        }
        let env = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        let sdk = (env?.isEmpty == false ? env! : Paths.hp("Library", "Android", "sdk"))
        let imgBase = Paths.join(sdk, "system-images")
        var imgs: [String] = []
        for a in Paths.children(imgBase) where Paths.isDir(a) {
            for b in Paths.children(a) where Paths.isDir(b) {
                for c in Paths.children(b) where Paths.isDir(c) { imgs.append(c) }
            }
        }
        for img in imgs.sorted() {
            L.append(CleanTarget(
                id: "sysimg:" + img, group: g, name: "Imagine de sistem \(Paths.relative(img, to: imgBase))",
                desc: "Necesară emulatoarelor pe versiunea asta de Android. Șterge-o doar dacă niciun emulator nu o folosește; se reinstalează din SDK Manager.",
                risk: .care,
                resolve: { Paths.existing([img]) }))
        }
        return L
    }

    static func simRuntimeTargets() -> [CleanTarget] {
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return [] }
        let r = Shell.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let d = json as? [String: Any] { items = d.values.compactMap { $0 as? [String: Any] } }
        else { items = (json as? [[String: Any]]) ?? [] }
        var L: [CleanTarget] = []
        for rt in items {
            guard let ident = rt["identifier"] as? String, !ident.isEmpty else { continue }
            if let del = rt["deletable"] as? Bool, !del { continue }
            let plat = (rt["platformIdentifier"] as? String ?? "").lowercased()
            let label = plat.contains("watch") ? "watchOS" : plat.contains("appletv") ? "tvOS"
                : plat.contains("xr") ? "visionOS" : "iOS"
            let version = rt["version"] as? String ?? "?"
            let size = (rt["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            L.append(CleanTarget(
                id: "runtime:" + ident, group: "Simulatoare iOS", name: "Runtime \(label) \(version)",
                desc: "Sistemul pentru simulatoarele pe această versiune. Păstrează doar ce folosești la testare; "
                    + "se descarcă din nou din Xcode → Settings → Components.",
                risk: .care, procs: ["Simulator.app/Contents/MacOS"], appName: "Simulator",
                cmds: [[xcrun, "simctl", "runtime", "delete", ident]],
                fixedSize: size))
        }
        return L.sorted { $0.name < $1.name }
    }

    static func nodeModulesTargets() -> [CleanTarget] {
        var L: [CleanTarget] = []
        let home = Paths.home
        let skipTop: Set<String> = ["Library", "Pictures", "Music", "Movies", "Applications", "Public"]
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let fm = FileManager.default

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for d in names.sorted() {
                let full = Paths.join(dir, d)
                var st = stat()
                guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue } // fără symlink-uri
                if d == "node_modules" {
                    let pkg = Paths.join(dir, "package.json")
                    let src = fm.fileExists(atPath: pkg) ? pkg : dir
                    let mt = (try? fm.attributesOfItem(atPath: src)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                    L.append(CleanTarget(
                        id: "nm:" + full, group: "node_modules din proiecte", name: Paths.relative(dir, to: home),
                        desc: "Proiect modificat ultima dată pe \(df.string(from: mt)). Se reinstalează cu npm / yarn / pnpm install.",
                        resolve: { Paths.existing([full]) }))
                } else if d.hasPrefix(".") || (dir == home && skipTop.contains(d)) {
                    continue
                } else if depth < 7 {
                    walk(full, depth: depth + 1)
                }
            }
        }
        walk(home, depth: 0)
        return L
    }
}
