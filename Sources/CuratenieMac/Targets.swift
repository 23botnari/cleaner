import Foundation

enum Risk: Sendable {
    /// safe = sigur, care = cere confirmare, suspect = euristică zgomotoasă, doar la cerere.
    case safe, care, suspect
    var label: String {
        switch self {
        case .safe: tr("Sigur")
        case .care: tr("Atenție")
        case .suspect: tr("Suspect")
        }
    }
}

struct CleanTarget: Identifiable, Sendable {
    let id: String
    /// Tehnologia de dezvoltare de care ține (nil = curățare generală). Țintele cu `tech` apar în secțiunea Dezvoltator.
    var tech: Tech? = nil
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

    var isDev: Bool { tech != nil }

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
            id: "whatsapp", group: g, name: tr("WhatsApp: date locale (media + chat-uri)"),
            desc: tr("Toate pozele, video-urile și fișierele primite pe WhatsApp, salvate pe Mac. Înainte: în WhatsApp → Settings → Account → Log out, apoi închide aplicația. La reconectare, chat-urile recente revin de pe telefon; media veche rămâne doar pe telefon."),
            risk: .care, procs: ["WhatsApp.app/Contents/MacOS"], appName: "WhatsApp",
            resolve: { Paths.existing([Paths.hp("Library", "Group Containers", "group.net.whatsapp.WhatsApp.shared")]) }))
        L.append(CleanTarget(
            id: "telegram", group: g, name: tr("Telegram: media în cache"),
            desc: tr("Fișiere descărcate din chat-uri. Rămân în cloud-ul Telegram și se descarcă din nou la nevoie."),
            procs: ["Telegram.app/Contents/MacOS"], appName: "Telegram",
            resolve: { Paths.existing([Paths.join(AS, "Telegram Desktop", "tdata", "user_data")]) }))
        L.append(CleanTarget(
            id: "discord", group: g, name: tr("Discord: cache"),
            desc: tr("Imagini și fișiere temporare. Discord le refolosește doar ca să încarce mai repede."),
            procs: ["Discord.app/Contents/MacOS"], appName: "Discord",
            resolve: { Paths.existing(["Cache", "Code Cache", "GPUCache"].map { Paths.join(AS, "discord", $0) }) }))

        g = "Dezvoltare"
        L.append(CleanTarget(
            id: "npm", tech: .js, group: g, name: tr("npm: cache"),
            desc: tr("Pachete descărcate anterior. Se redescarcă automat la următorul npm install."),
            resolve: { Paths.existing([Paths.hp(".npm", "_cacache"), Paths.hp(".npm", "_npx"), Paths.hp(".npm", "_logs")]) }))
        L.append(CleanTarget(
            id: "gradle", tech: .java, group: g, name: tr("Gradle: cache și distribuții"),
            desc: tr("Dependențe Android și versiuni Gradle descărcate. Primul build după curățare va dura mai mult."),
            procs: ["GradleDaemon"], appName: tr("Android Studio / Gradle (sau rulează ./gradlew --stop)"),
            resolve: { Paths.existing([Paths.hp(".gradle", "caches"), Paths.hp(".gradle", "wrapper", "dists"), Paths.hp(".gradle", "daemon")]) }))
        L.append(CleanTarget(
            id: "pnpm", tech: .js, group: g, name: tr("pnpm: store"),
            desc: tr("Depozitul global de pachete pnpm. Se reface la următorul pnpm install."),
            resolve: { Paths.existing([Paths.hp("Library", "pnpm", "store")]) }))
        L.append(CleanTarget(
            id: "deriveddata", tech: .apple, group: g, name: tr("Xcode: DerivedData"),
            desc: tr("Fișiere de build. Xcode le regenerează la următorul build."),
            procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "DerivedData")) }))
        L.append(CleanTarget(
            id: "devicesupport", tech: .apple, group: g, name: tr("Xcode: suport pentru dispozitive"),
            desc: tr("Simboluri copiate de pe iPhone-urile conectate vreodată. Se recopiază când conectezi din nou un dispozitiv."),
            procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "iOS DeviceSupport"))
                + Paths.children(Paths.join(dev, "Xcode", "watchOS DeviceSupport")) }))
        L.append(CleanTarget(
            id: "archives", tech: .apple, group: g, name: tr("Xcode: arhive"),
            desc: tr("Build-uri trimise în App Store / TestFlight. Păstrează-le dacă ai nevoie de rapoarte de crash simbolizate pentru versiuni publicate."),
            risk: .care, procs: ["Xcode.app/Contents/MacOS/Xcode"], appName: "Xcode",
            resolve: { Paths.children(Paths.join(dev, "Xcode", "Archives")) }))

        g = "Simulatoare iOS"
        let cs = Paths.join(dev, "CoreSimulator")
        L.append(CleanTarget(
            id: "simcaches", tech: .apple, group: g, name: tr("Simulatoare: cache"),
            desc: tr("Fișiere temporare ale simulatoarelor. Se refac automat."),
            resolve: { Paths.children(Paths.join(cs, "Caches")) }))
        if FileManager.default.isExecutableFile(atPath: xcrun) && Paths.isDir(Paths.join(cs, "Devices")) {
            L.append(CleanTarget(
                id: "simerase", tech: .apple, group: g, name: tr("Simulatoare: resetează toate"),
                desc: tr("Șterge aplicațiile și datele din toate simulatoarele și elimină simulatoarele pentru versiuni iOS care nu mai există. Simulatoarele rămân în listă, ca noi."),
                risk: .care, procs: ["Simulator.app/Contents/MacOS"], appName: "Simulator",
                cmds: [["/bin/sh", "-c", "/usr/bin/xcrun simctl shutdown all >/dev/null 2>&1; true"],
                       [xcrun, "simctl", "delete", "unavailable"],
                       [xcrun, "simctl", "erase", "all"]],
                sizePaths: [Paths.join(cs, "Devices")]))
        }

        g = "Sistem și altele"
        L.append(CleanTarget(
            id: "wallpapers", group: g, name: tr("Wallpapere Aerial descărcate"),
            desc: tr("Video-urile pentru wallpapere și screensaver-e animate. Cel folosit acum se descarcă din nou automat."),
            resolve: { filesMatching(Paths.join(AS, "com.apple.wallpaper"), exts: ["mov", "mp4"]) }))
        L.append(CleanTarget(
            id: "dockerinstall", tech: .docker, group: "Dezvoltare", name: tr("Docker: kit de instalare rămas"),
            desc: tr("Fișiere rămase după instalarea Docker Desktop. Docker funcționează și fără ele."),
            resolve: { Paths.existing([Paths.join(AS, "com.docker.install")]) }))
        L.append(CleanTarget(
            id: "vscode", tech: .tools, group: "Dezvoltare", name: tr("VS Code: cache"),
            desc: tr("Cache-uri și log-uri. Setările, extensiile și proiectele nu sunt atinse."),
            procs: ["Visual Studio Code.app/Contents/MacOS"], appName: "VS Code",
            resolve: { Paths.existing(["Cache", "CachedData", "CachedExtensionVSIXs", "Code Cache", "GPUCache", "logs"]
                .map { Paths.join(AS, "Code", $0) }) }))
        L.append(CleanTarget(
            id: "usercaches", group: g, name: tr("Cache-uri aplicații (~/Library/Caches)"),
            desc: tr("Cache-urile tuturor aplicațiilor (browsere, Homebrew, CocoaPods etc.). Se refac singure; unele aplicații pot porni mai încet o dată. Închide cât mai multe aplicații înainte și repornește Mac-ul după."),
            risk: .care,
            resolve: { Paths.children(Paths.hp("Library", "Caches")) }))
        L.append(CleanTarget(
            id: "logs", group: g, name: tr("Log-uri"),
            desc: tr("Jurnale de erori și diagnostic ale aplicațiilor."),
            resolve: { Paths.children(Paths.hp("Library", "Logs")) }))
        L.append(CleanTarget(
            id: "trash", group: g, name: tr("Coșul (Bin)"),
            desc: tr("Golește Coșul definitiv. Ce e acolo nu mai poate fi recuperat."),
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
            id: "claude-cache", tech: .claude, group: g, name: tr("Claude Desktop: cache"),
            desc: tr("Cache-uri ale interfeței (imagini, cod compilat, GPU). Conversațiile și setările nu sunt atinse; se refac automat."),
            procs: desktop, appName: tr("aplicația Claude (Claude → Quit)"),
            resolve: { Paths.existing(["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "blob_storage"]
                .map { Paths.join(cl, $0) } + [Paths.hp("Library", "Caches", "com.anthropic.claudefordesktop.ShipIt")]) }))
        L.append(CleanTarget(
            id: "claude-vm", tech: .claude, group: g, name: tr("Claude Desktop: mașina virtuală"),
            desc: tr("Imaginea Linux folosită de Claude pentru lucru în sandbox (Cowork / agent). Se descarcă din nou automat prima dată când e nevoie de ea (câțiva GB)."),
            risk: .care, procs: desktop, appName: tr("aplicația Claude (Claude → Quit)"),
            resolve: { Paths.existing([Paths.join(cl, "vm_bundles")]) }))
        let cc = Paths.hp(".claude")
        L.append(CleanTarget(
            id: "claudecode-temp", tech: .claude, group: g, name: tr("Claude Code: fișiere temporare"),
            desc: tr("Snapshot-uri de shell, cache, istoric de fișiere pentru undo, log-uri de debug și cache-ul CLI. Setările, skill-urile, plugin-urile și conversațiile rămân."),
            procs: ["=claude"], appName: tr("toate sesiunile Claude Code (inclusiv cele din Claude Desktop)"),
            resolve: { Paths.existing(["shell-snapshots", "paste-cache", "cache", "debug", "telemetry", "file-history", "statsig"]
                .map { Paths.join(cc, $0) } + [Paths.hp("Library", "Caches", "claude-cli-nodejs")]) }))
        L.append(CleanTarget(
            id: "claudecode-old", tech: .claude, group: g, name: tr("Claude Code: conversații mai vechi de 30 de zile"),
            desc: tr("Transcrieri ale sesiunilor vechi din ~/.claude/projects. După ștergere nu mai poți relua (--resume) acele sesiuni."),
            risk: .care, procs: ["=claude"], appName: tr("toate sesiunile Claude Code (inclusiv cele din Claude Desktop)"),
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
            id: "docker-prune", tech: .docker, group: "Dezvoltare", name: tr("Docker: imagini, containere oprite și cache de build nefolosite"),
            desc: tr("Rulează „docker system prune -a”. Volumele (bazele de date din containere) NU sunt atinse. Imaginile se descarcă din nou la nevoie. Docker.raw se micșorează după repornirea Docker."),
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
                    id: "avdsnap:" + avd, tech: .android, group: g, name: tr("Emulator \(name): snapshot-uri"),
                    desc: tr("Stări salvate pentru Quick Boot. Emulatorul pornește la rece prima dată; aplicațiile și datele din el rămân."),
                    procs: ["qemu-system"], appName: tr("emulatorul Android"),
                    resolve: { Paths.children(snaps) }))
            }
            L.append(CleanTarget(
                id: "avd:" + avd, tech: .android, group: g, name: tr("Emulator \(name): șterge complet"),
                desc: tr("Șterge emulatorul cu tot cu datele lui. Îl poți crea din nou din Android Studio → Device Manager."),
                risk: .care, procs: ["qemu-system"], appName: tr("emulatorul Android"), overlap: true,
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
                id: "sysimg:" + img, tech: .android, group: g, name: tr("Imagine de sistem \(Paths.relative(img, to: imgBase))"),
                desc: tr("Necesară emulatoarelor pe versiunea asta de Android. Șterge-o doar dacă niciun emulator nu o folosește; se reinstalează din SDK Manager."),
                risk: .care,
                resolve: { Paths.existing([img]) }))
        }
        return L
    }

    /// Simulatoare pentru versiuni iOS care nu mai sunt instalate: nu pot porni, doar ocupă loc.
    static func unavailableSimTargets() -> [CleanTarget] {
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return [] }
        let r = Shell.run(xcrun, ["simctl", "list", "devices", "unavailable", "-j"], timeout: 60)
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [] }
        let devices = Paths.join(dev, "CoreSimulator", "Devices")
        let dirs = byRuntime.values.flatMap { $0 }.compactMap { $0["udid"] as? String }.map { Paths.join(devices, $0) }
        guard !dirs.isEmpty else { return [] }
        return [CleanTarget(
            id: "simunavailable", tech: .apple, group: "Simulatoare iOS", name: tr("Simulatoare indisponibile (\(dirs.count))"),
            desc: tr("Simulatoare pentru versiuni iOS care nu mai sunt instalate; nu mai pot porni. Rulează „xcrun simctl delete unavailable”."),
            procs: ["Simulator.app/Contents/MacOS"], appName: "Simulator",
            cmds: [[xcrun, "simctl", "delete", "unavailable"]],
            sizePaths: dirs)]
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
                id: "runtime:" + ident, tech: .apple, group: "Simulatoare iOS", name: tr("Runtime \(label) \(version)"),
                desc: tr("Sistemul pentru simulatoarele pe această versiune. Păstrează doar ce folosești la testare; se descarcă din nou din Xcode → Settings → Components."),
                risk: .care, procs: ["Simulator.app/Contents/MacOS"], appName: "Simulator",
                cmds: [[xcrun, "simctl", "runtime", "delete", ident]],
                fixedSize: size))
        }
        return L.sorted { $0.name < $1.name }
    }

    /// Proiectele atinse în ultimele zile nu se bifează implicit: probabil lucrezi la ele.
    static let activeProjectDays: Double = 30

    /// Foldere de build regenerabile, recunoscute doar lângă fișierul care le confirmă proiectul.
    struct Artifact: Sendable {
        let dir: String
        let tech: Tech
        let what: String
        let regen: String
        /// Fișiere din folderul proiectului; ajunge să existe unul.
        var markers: [String] = []
        /// Sufixe de fișiere din folderul proiectului (ex. „.csproj”); ajunge unul.
        var suffixes: [String] = []
        /// Căi din interiorul folderului de build; trebuie să existe toate.
        var inside: [String] = []
        /// Se curăță doar acest subfolder (ex. vendor/bundle), nu tot folderul.
        var sub: String? = nil
        /// Nume prea generic (dist, build, out): se ia doar dacă git îl ignoră, deci e sigur generat.
        var ignoredOnly = false
        var risk: Risk = .safe

        func matches(parent: String, names: [String], full: String) -> Bool {
            if !markers.isEmpty || !suffixes.isEmpty {
                guard names.contains(where: { n in markers.contains(n) || suffixes.contains { n.hasSuffix($0) } }) else { return false }
            }
            guard inside.allSatisfy({ Paths.lexists(Paths.join(full, $0)) }) else { return false }
            if let sub, !Paths.isDir(Paths.join(full, sub)) { return false }
            if ignoredOnly && !Targets.gitIgnores(dir, in: parent) { return false }
            return true
        }
    }

    private static let jsMarker = ["package.json"]
    private static let gradleMarkers = ["build.gradle", "build.gradle.kts"]
    private static let regenBuild = tr("Se reface la următorul build.")

    /// Ordinea contează: pentru același nume de folder câștigă prima potrivire.
    static let projectArtifacts: [Artifact] = [
        Artifact(dir: ".next", tech: .js, what: tr("build Next.js"), regen: tr("Se regenerează la următorul next dev / build."), markers: jsMarker),
        Artifact(dir: ".nuxt", tech: .js, what: tr("build Nuxt"), regen: tr("Se regenerează la următorul nuxt dev / build."), markers: jsMarker),
        Artifact(dir: ".output", tech: .js, what: tr("build Nuxt / Nitro"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".svelte-kit", tech: .js, what: tr("build SvelteKit"), regen: tr("Se regenerează la următorul vite dev / build."), markers: jsMarker),
        Artifact(dir: ".turbo", tech: .js, what: tr("cache Turborepo"), regen: tr("Se reface la următorul turbo run."), markers: ["package.json", "turbo.json"]),
        Artifact(dir: ".parcel-cache", tech: .js, what: tr("cache Parcel"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".angular", tech: .js, what: tr("cache Angular"), regen: tr("Se reface la următorul ng serve / build."), markers: ["angular.json"]),
        Artifact(dir: ".expo", tech: .js, what: tr("cache Expo"), regen: tr("Se reface la următorul expo start."), markers: jsMarker),
        Artifact(dir: ".astro", tech: .js, what: tr("cache Astro"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".docusaurus", tech: .js, what: tr("cache Docusaurus"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".vite", tech: .js, what: tr("cache Vite"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".nx", tech: .js, what: tr("cache Nx"), regen: regenBuild, markers: ["nx.json"]),
        Artifact(dir: ".cache", tech: .js, what: tr("cache de build"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: ".vercel", tech: .js, what: tr("build Vercel"), regen: tr("Se regenerează la următorul vercel build."), markers: jsMarker, sub: "output"),
        Artifact(dir: "storybook-static", tech: .js, what: tr("build Storybook"), regen: regenBuild, markers: jsMarker),
        Artifact(dir: "target", tech: .rust, what: tr("build Rust"), regen: tr("Se recompilează la următorul cargo build."), markers: ["Cargo.toml"]),
        Artifact(dir: "target", tech: .java, what: tr("build Maven"), regen: tr("Se recompilează la următorul mvn package."), markers: ["pom.xml"]),
        Artifact(dir: ".build", tech: .apple, what: tr("build Swift"), regen: tr("Se recompilează la următorul swift build."), markers: ["Package.swift"]),
        Artifact(dir: "Pods", tech: .apple, what: tr("dependențe CocoaPods"), regen: tr("Se reinstalează cu pod install."), markers: ["Podfile"]),
        Artifact(dir: ".dart_tool", tech: .flutter, what: tr("cache Dart / Flutter"), regen: tr("Se reface la următorul flutter pub get."), markers: ["pubspec.yaml"]),
        Artifact(dir: "build", tech: .flutter, what: tr("build Flutter"), regen: tr("Se regenerează la următorul flutter build."), markers: ["pubspec.yaml"]),
        Artifact(dir: "build", tech: .java, what: tr("build Gradle"), regen: tr("Se regenerează la următorul build Gradle."), markers: gradleMarkers),
        Artifact(dir: ".gradle", tech: .java, what: tr("cache Gradle al proiectului"), regen: tr("Se reface la următorul build Gradle."),
                 markers: ["settings.gradle", "settings.gradle.kts"] + gradleMarkers),
        Artifact(dir: "build", tech: .apple, what: tr("build Xcode"), regen: tr("Se regenerează la următorul build din Xcode."),
                 markers: ["Podfile"], suffixes: [".xcodeproj", ".xcworkspace"]),
        Artifact(dir: "vendor", tech: .php, what: tr("dependențe Composer"), regen: tr("Se reinstalează cu composer install."),
                 markers: ["composer.json"], inside: ["autoload.php"]),
        Artifact(dir: "vendor", tech: .ruby, what: tr("gem-uri Bundler"), regen: tr("Se reinstalează cu bundle install."), markers: ["Gemfile"], sub: "bundle"),
        Artifact(dir: "bin", tech: .dotnet, what: tr("build .NET"), regen: tr("Se recompilează la următorul dotnet build."), suffixes: [".csproj", ".fsproj", ".vbproj"]),
        Artifact(dir: "obj", tech: .dotnet, what: tr("build .NET"), regen: tr("Se recompilează la următorul dotnet build."), suffixes: [".csproj", ".fsproj", ".vbproj"]),
        Artifact(dir: ".venv", tech: .python, what: tr("mediu virtual Python"), regen: tr("Se recreează cu python -m venv și reinstalarea dependențelor."),
                 inside: ["pyvenv.cfg"], risk: .care),
        Artifact(dir: "venv", tech: .python, what: tr("mediu virtual Python"), regen: tr("Se recreează cu python -m venv și reinstalarea dependențelor."),
                 inside: ["pyvenv.cfg"], risk: .care),
        Artifact(dir: ".pytest_cache", tech: .python, what: tr("cache pytest"), regen: tr("Se reface la următoarea rulare.")),
        Artifact(dir: ".mypy_cache", tech: .python, what: tr("cache mypy"), regen: tr("Se reface la următoarea rulare.")),
        Artifact(dir: ".ruff_cache", tech: .python, what: tr("cache ruff"), regen: tr("Se reface la următoarea rulare.")),
        Artifact(dir: ".tox", tech: .python, what: tr("medii tox"), regen: tr("Se reface la următoarea rulare.")),
        // Nume generice: doar în proiecte JS și doar dacă git le ignoră. Nebifate implicit.
        Artifact(dir: "dist", tech: .js, what: tr("build (dist)"), regen: regenBuild, markers: jsMarker, ignoredOnly: true, risk: .care),
        Artifact(dir: "build", tech: .js, what: tr("build"), regen: regenBuild, markers: jsMarker, ignoredOnly: true, risk: .care),
        Artifact(dir: "out", tech: .js, what: tr("build (out)"), regen: regenBuild, markers: jsMarker, ignoredOnly: true, risk: .care),
        Artifact(dir: "coverage", tech: .js, what: tr("raport de acoperire a testelor"), regen: tr("Se reface la următoarea rulare."),
                 markers: jsMarker, ignoredOnly: true, risk: .care),
    ]

    /// git real, nu shim-ul /usr/bin/git (care ar deschide dialogul de instalare a Command Line Tools).
    static let gitCLI: String? = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                                  "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// `name` din folderul `dir` e ignorat de git (deci generat, nu sursă). Fără git sau fără repo: false.
    static func gitIgnores(_ name: String, in dir: String) -> Bool {
        guard let git = gitCLI else { return false }
        return Shell.run(git, ["-C", dir, "check-ignore", "-q", "--", name], timeout: 10).code == 0
    }

    /// Ultima activitate în proiect: fișierele de pe primul nivel, folderul însuși și indexul git (până la 4 niveluri mai sus).
    static func lastActivity(_ dir: String, skip: String) -> Date {
        let fm = FileManager.default
        func mtime(_ p: String) -> Date? {
            var st = stat()
            guard lstat(p, &st) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        }
        var dates = [mtime(dir)]
        for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n != skip {
            let p = Paths.join(dir, n)
            if !Paths.isDir(p) { dates.append(mtime(p)) }
        }
        var cur = dir
        for _ in 0..<5 {
            let git = Paths.join(cur, ".git")
            if Paths.lexists(git) {
                dates += [mtime(Paths.join(git, "index")), mtime(Paths.join(git, "logs", "HEAD"))]
                break
            }
            if cur == Paths.home || cur == Paths.realHome { break }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return dates.compactMap { $0 }.max() ?? Date(timeIntervalSince1970: 0)
    }

    /// Doar pentru tehnologiile din profil: restul folderelor de build nici nu se caută.
    static func projectArtifactTargets(techs: Set<Tech>) -> [CleanTarget] {
        guard !techs.isEmpty else { return [] }
        let artifacts = projectArtifacts.filter { techs.contains($0.tech) }
        let artifactDirs = Set(artifacts.map(\.dir))
        var L: [CleanTarget] = []
        let home = Paths.home
        let skipTop: Set<String> = ["Library", "Pictures", "Music", "Movies", "Applications", "Public"]
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-activeProjectDays * 24 * 3600)

        func target(id: String, tech: Tech, group: String, full: String, dir: String, skip: String, what: String, regen: String,
                    care: Bool = false) -> CleanTarget {
            let last = lastActivity(dir, skip: skip)
            let active = last > cutoff
            let days = max(0, Int(Date().timeIntervalSince(last) / (24 * 3600)))
            let rel = Paths.relative(dir, to: home)
            return CleanTarget(
                id: id + full, tech: tech, group: group,
                name: group == "node_modules din proiecte" ? rel : "\(rel) — \(what)",
                desc: tr("Ultima activitate în proiect: \(df.string(from: last)) (acum \(days) zile). \(regen)")
                    + (active ? tr(" Lucrezi recent la el, așa că nu e bifat implicit.") : ""),
                risk: active || care ? .care : .safe,
                resolve: { Paths.existing([full]) })
        }

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for d in names.sorted() {
                let full = Paths.join(dir, d)
                var st = stat()
                guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue } // fără symlink-uri
                // Pachetele (.app, .bundle…) au node_modules proprii: ștergerea ar strica aplicația.
                if (try? URL(fileURLWithPath: full).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { continue }
                if d == "node_modules" {
                    if techs.contains(.js) {
                        L.append(target(id: "nm:", tech: .js, group: "node_modules din proiecte", full: full, dir: dir, skip: d,
                                        what: "node_modules", regen: tr("Se reinstalează cu npm / yarn / pnpm install.")))
                    }
                } else if dir != home, artifactDirs.contains(d),
                          let a = artifacts.first(where: { $0.dir == d && $0.matches(parent: dir, names: names, full: full) }) {
                    L.append(target(id: "art:", tech: a.tech, group: "Build-uri din proiecte",
                                    full: a.sub.map { Paths.join(full, $0) } ?? full, dir: dir, skip: d,
                                    what: a.what, regen: a.regen, care: a.risk != .safe))
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
