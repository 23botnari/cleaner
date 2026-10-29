import SwiftUI
import AppKit

// MARK: - Model

enum LeftoverKind: Int, Sendable, CaseIterable {
    case halfUninstalled, emptyLaunch, orphanLaunch, vendor, bloat, orphanContainer

    var title: String {
        switch self {
        case .halfUninstalled: tr("Aplicații dezinstalate pe jumătate")
        case .emptyLaunch: tr("Plist-uri de pornire goale")
        case .orphanLaunch: tr("LaunchAgents / LaunchDaemons orfani")
        case .vendor: tr("Resturi de antivirus / cleaner")
        case .bloat: tr("Aplicații cu servicii de fundal (sugestie)")
        case .orphanContainer: tr("Containere fără aplicație (suspecte)")
        }
    }
}

struct LeftoverFinding: Identifiable, Sendable {
    let id: String
    let kind: LeftoverKind
    let title: String
    let detail: String
    let risk: Risk
    /// Ce se mută la Coș.
    let paths: [String]
    /// Plist-uri de launch cu Label: se opresc (launchctl bootout) înainte de mutare.
    var launchPlists: [String] = []
    /// Ce se afișează (pentru sugestii, fără să se mute nimic).
    var listed: [String] = []
    /// Doar sugestie: dezinstalatorul propriu al aplicației.
    var uninstaller: String? = nil
    var size: Int64? = nil

    var shown: [String] { listed.isEmpty ? paths : listed }
}

// MARK: - Reguli de siguranță

enum LeftoverGuard {
    /// Servicii legitime care arată ca resturi. Plus excluderi locale din
    /// ~/Library/Application Support/Cleaner/exclude.txt (un cuvânt pe linie, `#` = comentariu).
    static let neverTouch = ["steam", "valvesoftware", "docker", "karabiner", "pqrs", "googleupdater", "edgeupdater"] + localExcludes()

    static let excludeFile = Paths.hp("Library", "Application Support", "Cleaner", "exclude.txt")

    static func localExcludes() -> [String] {
        guard let s = try? String(contentsOfFile: excludeFile, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func excluded(_ s: String) -> Bool {
        let l = s.lowercased()
        return neverTouch.contains { l.contains($0) }
    }

    static let launchDirs = ["/Library/LaunchDaemons", "/Library/LaunchAgents", Paths.hp("Library", "LaunchAgents")]

    static let systemParents: Set<String> = ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
                                             "/Library/Application Support", "/Library/Preferences", "/Applications"]

    /// Foldere standard din /Library: nu sunt resturi ale vreunei aplicații.
    static let standardLibrary: Set<String> = [
        "Apple", "Application Support", "Audio", "Bluetooth", "Caches", "ColorPickers", "ColorSync", "Components", "Compositions",
        "Contextual Menu Items", "CoreAnalytics", "CoreMediaIO", "Developer", "DirectoryServices", "Documentation",
        "DriverExtensions", "Extensions", "Filesystems", "Fonts", "Frameworks", "GPUBundles", "Graphics", "Image Capture",
        "Input Methods", "InstallerSandboxes", "Internet Plug-Ins", "Java", "KernelCollections", "Keyboard Layouts", "Keychains",
        "LaunchAgents", "LaunchDaemons", "Logs", "Modem Scripts", "OSAnalytics", "OpenDirectory", "PDF Services", "Perl",
        "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools", "QuickLook", "Receipts", "Ruby", "Sandbox",
        "Screen Savers", "ScriptingAdditions", "Scripts", "Security", "Speech", "Spotlight", "StagedDriverExtensions",
        "StagedExtensions", "StartupItems", "SystemExtensions", "SystemMigration", "SystemProfiler", "Trial", "Updates",
        "User Pictures", "User Template", "Video", "WebServer", "Widgets", "Containers", "Group Containers", "Application Scripts",
    ]

    /// Doar căile detectate, în locuri cunoscute: în home după regulile generale, în afara lui doar un nivel sub
    /// folderele de launch / suport / /Applications (fără .app) sau un folder nestandard direct în /Library.
    static func allowed(_ p: String) -> Bool {
        let full = Paths.resolvedParent(p)
        let name = (full as NSString).lastPathComponent
        guard !name.isEmpty, !excluded(name), !name.lowercased().hasPrefix("com.apple.") else { return false }
        if Paths.underHome(full) { return Paths.deletable(full) }
        let parent = (full as NSString).deletingLastPathComponent
        if parent == "/Applications" { return !name.hasSuffix(".app") }
        if systemParents.contains(parent) { return true }
        return parent == "/Library" && !standardLibrary.contains(name)
    }
}

// MARK: - Detecție

enum LeftoverScanner {
    struct Installed {
        var ids: Set<String> = []
        var orgs: Set<String> = []
        var paths: [String] = []

        func owns(_ id: String) -> Bool {
            let l = id.lowercased()
            if ids.contains(l) { return true }
            if ids.contains(where: { l.hasPrefix($0 + ".") || $0.hasPrefix(l + ".") }) { return true }
            return orgs.contains(org(l))
        }

        func hasPrefix(_ prefix: String) -> Bool { ids.contains { $0.hasPrefix(prefix) } }
    }

    static func org(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Bundle ID-urile tuturor aplicațiilor știute de Spotlight (inclusiv pe volumele externe) + scanarea proprie.
    static func installed() -> Installed {
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemContentType == com.apple.application-bundle"], timeout: 60)
        var paths = Set(r.out.split(separator: "\n").map(String.init))
        paths.formUnion(AppScanner.scan().map(\.path))
        var inst = Installed()
        for p in paths {
            guard let info = NSDictionary(contentsOfFile: Paths.join(p, "Contents", "Info.plist")),
                  let id = (info["CFBundleIdentifier"] as? String)?.lowercased(), !id.isEmpty else { continue }
            inst.ids.insert(id)
            inst.paths.append(p)
            if id.split(separator: ".").count >= 3 { inst.orgs.insert(org(id)) }
        }
        return inst
    }

    struct LaunchPlist {
        let path: String
        let label: String?
        let program: String?
        let args: [String]
        var isEmpty: Bool { program == nil }
    }

    static func launchPlists() -> [LaunchPlist] {
        LeftoverGuard.launchDirs.flatMap(Paths.children).filter { $0.hasSuffix(".plist") }.compactMap { p in
            guard let data = FileManager.default.contents(atPath: p),
                  let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            let args = d["ProgramArguments"] as? [String] ?? []
            let prog = (d["Program"] as? String) ?? args.first ?? (d["BundleProgram"] as? String)
            return LaunchPlist(path: p, label: d["Label"] as? String, program: prog, args: args)
        }
    }

    /// Lipsește binarul? Un volum extern nemontat nu înseamnă orfan; căile relative nu se pot verifica.
    static func missing(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path.hasPrefix("/Volumes/") {
            let vol = path.split(separator: "/").prefix(2).joined(separator: "/")
            if !Paths.isDir("/" + vol) { return false }
        }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Folderele în care stau resturile, cu copiii lor (fără ce e exclus).
    static func scanEntries() -> [String] {
        let L = Paths.hp("Library")
        let home = ["Application Support", "Caches", "Containers", "Group Containers", "Application Scripts", "Preferences",
                    "LaunchAgents", "Logs", "Saved Application State", "HTTPStorages", "WebKit", "Cookies"].map { Paths.join(L, $0) }
        let sys = ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools",
                   "/Library/Application Support", "/Library/Preferences"]
        var out = (home + sys).flatMap(Paths.children)
        out += Paths.children("/Library").filter { !LeftoverGuard.standardLibrary.contains(($0 as NSString).lastPathComponent) }
        out += Paths.children("/Applications").filter { !$0.hasSuffix(".app") }
        return out.filter {
            let n = ($0 as NSString).lastPathComponent
            return !LeftoverGuard.excluded(n) && !n.lowercased().contains("com.apple.")
        }
    }

    static func name(_ p: String) -> String { (p as NSString).lastPathComponent }

    static func isLaunch(_ p: String) -> Bool {
        LeftoverGuard.launchDirs.contains((p as NSString).deletingLastPathComponent)
    }

    static let vendors: [(token: String, owners: [String])] = [
        ("avira", ["com.avira"]), ("avast", ["com.avast", "com.piriform"]), ("avg", ["com.avg", "com.piriform"]),
        ("norton", ["com.norton", "com.symantec", "com.nortonlifelock"]), ("symantec", ["com.symantec", "com.norton"]),
        ("mcafee", ["com.mcafee"]), ("kaspersky", ["com.kaspersky"]), ("sophos", ["com.sophos"]),
        ("bitdefender", ["com.bitdefender"]), ("malwarebytes", ["com.malwarebytes"]), ("eset", ["com.eset"]),
        ("macpaw", ["com.macpaw"]), ("mackeeper", ["com.mackeeper", "com.kromtech", "com.zeobit"]),
    ]

    static let bloat: [(name: String, idPrefix: String, plistPrefix: String)] = [
        ("CCleaner", "com.piriform.ccleaner", "com.piriform."),
    ]

    static func scan() -> [LeftoverFinding] {
        let inst = installed()
        let entries = scanEntries()
        let plists = launchPlists().filter {
            !LeftoverGuard.excluded(name($0.path)) && !LeftoverGuard.excluded($0.label ?? "") && !LeftoverGuard.excluded($0.program ?? "")
        }
        let labeled = Set(plists.filter { $0.label != nil && !$0.isEmpty }.map(\.path))
        /// Căi deja prinse de o detecție (sau aparținând unei aplicații instalate): nu apar a doua oară.
        var claimed = Set<String>()
        var out: [LeftoverFinding] = []

        func make(_ id: String, _ kind: LeftoverKind, _ title: String, _ detail: String, _ risk: Risk, _ paths: [String]) {
            let ok = paths.filter { !claimed.contains($0) && LeftoverGuard.allowed($0) }
            guard !ok.isEmpty else { return }
            claimed.formUnion(ok)
            out.append(LeftoverFinding(id: id, kind: kind, title: title, detail: detail, risk: risk, paths: ok,
                                       launchPlists: ok.filter { labeled.contains($0) }))
        }

        // 3. Folder de aplicație gol în /Applications, cu suport rămas în altă parte.
        for dir in Paths.children("/Applications") where Paths.isDir(dir) && !Paths.isSymlink(dir) && !dir.hasSuffix(".app") {
            let kids = Paths.children(dir).map(name)
            guard kids.allSatisfy({ $0.hasPrefix(".") && !$0.hasSuffix(".app") }) else { continue }
            let token = name(dir).lowercased().filter { $0.isLetter || $0.isNumber }
            guard token.count >= 4, !LeftoverGuard.excluded(token), name(dir) != "Utilities" else { continue }
            let rest = entries.filter { $0 != dir && name($0).lowercased().contains(token) }
            guard !rest.isEmpty else { continue }
            let support = rest.filter { r in inst.paths.contains { $0.hasPrefix(r + "/") } }
            var detail = tr("Folderul /Applications/\(name(dir)) e gol, dar au rămas \(rest.count) elemente (suport, plist-uri de pornire, containere).")
            if !support.isEmpty {
                detail += tr(" În \(support.map(name).joined(separator: ", ")) încă există componente (ex. extensii sau drivere).")
            }
            if token == "bit4id" {
                detail += tr(" bit4id e middleware-ul PKCS#11 pentru tokenuri de semnătură electronică. Șterge doar dacă nu mai folosești tokenul.")
            } else {
                detail += tr(" Poate fi middleware folosit de altă aplicație; confirmă că nu-l folosești.")
            }
            make("half:" + dir, .halfUninstalled, tr("\(name(dir)): rest de dezinstalare"), detail, .care, [dir] + rest)
        }

        // 2. Plist-uri de launch fără program, grupate după prefix (ex. com.google.keystone) + preferințele lor.
        let prefs = Paths.children(Paths.hp("Library", "Preferences"))
        var emptyGroups: [String: [String]] = [:]
        for p in plists where p.isEmpty {
            let stem = (name(p.path) as NSString).deletingPathExtension.lowercased()
            let key = stem.split(separator: ".").prefix(3).joined(separator: ".")
            emptyGroups[key, default: []].append(p.path)
            emptyGroups[key]! += prefs.filter { name($0).lowercased() == stem + ".plist" }
        }
        for (key, paths) in emptyGroups.sorted(by: { $0.key < $1.key }) {
            make("empty:" + key, .emptyLaunch, tr("\(key): plist-uri de pornire goale"),
                 tr("Fișiere de pornire fără Program / ProgramArguments: nu pornesc nimic. Probabil rămase de la o versiune veche (ex. Google Keystone, înlocuit de GoogleUpdater)."), .safe, paths)
        }

        // 1. Plist-uri de launch al căror binar (sau fișier din /Applications primit ca argument) nu mai există.
        for p in plists where !p.isEmpty {
            guard let prog = p.program else { continue }
            let missingArgs = p.args.dropFirst().filter { $0.hasPrefix("/Applications/") && missing($0) }
            guard missing(prog) || !missingArgs.isEmpty else { continue }
            let what = missing(prog) ? prog : missingArgs[0]
            make("orphan:" + p.path, .orphanLaunch, p.label ?? name(p.path), tr("Pornește „\(what)”, care nu mai există."), .safe, [p.path])
        }

        // 4. Resturi de antivirus / cleaner al căror vendor nu mai e instalat.
        for v in vendors {
            let hits = entries.filter { tokens(name($0)).contains(v.token) }
            guard !hits.isEmpty else { continue }
            if v.owners.contains(where: inst.hasPrefix) {
                claimed.formUnion(hits)  // aparțin unei aplicații instalate (ex. grupul Avast al CCleaner)
                continue
            }
            make("vendor:" + v.token, .vendor, tr("\(v.token.capitalized): resturi"),
                 tr("Fișiere \(v.token.capitalized) rămase după dezinstalare; nicio aplicație a vendorului nu mai e instalată."), .safe, hits)
        }

        // 6. Aplicații instalate cu mulți daemoni: doar sugestie, prin dezinstalatorul lor.
        for b in bloat {
            guard let app = inst.paths.first(where: { p in
                (NSDictionary(contentsOfFile: Paths.join(p, "Contents", "Info.plist"))?["CFBundleIdentifier"] as? String)?
                    .lowercased().hasPrefix(b.idPrefix) == true && p.hasPrefix("/Applications/")
            }) else { continue }
            let own = plists.map(\.path).filter { name($0).hasPrefix(b.plistPrefix) }
            guard !own.isEmpty else { continue }
            claimed.formUnion(own)
            let daemons = own.filter { $0.hasPrefix("/Library/LaunchDaemons/") }.count
            let unin = Paths.join(app, "Contents", "Uninstaller.app")
            out.append(LeftoverFinding(
                id: "bloat:" + b.name, kind: .bloat, title: tr("\(b.name): \(daemons) LaunchDaemons + \(own.count - daemons) LaunchAgents"),
                detail: tr("Servicii de fundal (telemetrie, actualizări). Dacă nu folosești \(b.name), dezinstalează-l cu dezinstalatorul propriu, nu prin ștergere."),
                risk: .care, paths: [], listed: own, uninstaller: Paths.isDir(unin) ? unin : nil))
        }

        // 5. Containere / preferințe al căror bundle ID nu aparține niciunei aplicații instalate.
        let L = Paths.hp("Library")
        var orphans: [String: [String]] = [:]
        for sub in ["Containers", "Group Containers", "Application Scripts", "Preferences"] {
            for p in Paths.children(Paths.join(L, sub)) where !claimed.contains(p) {
                var n = name(p)
                if sub == "Preferences" {
                    guard n.hasSuffix(".plist") else { continue }
                    n = String(n.dropLast(6))
                }
                if n.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) != nil { n = String(n.dropFirst(11)) }
                for g in ["group.", "groups."] where n.hasPrefix(g) { n = String(n.dropFirst(g.count)) }
                let l = n.lowercased()
                guard l.split(separator: ".").count >= 3, !l.hasPrefix("com.apple."), !l.contains(".com.apple."), !l.hasPrefix("is.workflow."),
                      UUID(uuidString: n) == nil, !LeftoverGuard.excluded(l), !inst.owns(l) else { continue }
                orphans[l, default: []].append(p)
            }
        }
        for (id, paths) in orphans.sorted(by: { $0.key < $1.key }) {
            let where_ = Set(paths.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }).sorted()
            make("orphanc:" + id, .orphanContainer, id,
                 tr("Nicio aplicație instalată nu are acest bundle ID (\(where_.joined(separator: ", "))). Euristică: verifică înainte."),
                 .suspect, paths)
        }
        return out
    }
}

// MARK: - Execuție (implicit doar previzualizare)

enum LeftoverActions {
    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    struct Plan: Sendable {
        var userBoot: [String] = []
        var adminBoot: [(domain: String, path: String)] = []
        var homeTrash: [String] = []
        var systemTrash: [String] = []
        var skipped: [String] = []

        /// Un singur shell rulat ca administrator; „not loaded” e normal pentru resturi.
        var adminCommand: String? {
            adminBoot.isEmpty ? nil
                : adminBoot.map { "/bin/launchctl bootout \($0.domain) \(shq($0.path)) 2>/dev/null" }.joined(separator: "; ") + "; true"
        }

        /// Exact ce rulează execute(), în ordine.
        var lines: [String] {
            var l = userBoot.map { "/bin/launchctl bootout gui/\(getuid()) \(shq($0))" }
            if let c = adminCommand { l.append(osascriptLine(adminScript, [c])) }
            l += homeTrash.map { tr("FileManager.trashItem(\(shq($0)))   # refuzat → Finder, ca mai jos") }
            if !systemTrash.isEmpty { l.append(osascriptLine(finderScript, systemTrash)) }
            return l
        }
    }

    static let adminScript = ["on run argv", "do shell script (item 1 of argv) with administrator privileges", "end run"]
    static let finderScript = ["on run argv", "set L to {}", "repeat with p in argv",
                               "set end of L to (POSIX file (contents of p)) as alias", "end repeat",
                               "tell application \"Finder\" to delete L", "end run"]

    static func osascriptArgs(_ script: [String], _ argv: [String]) -> [String] {
        script.flatMap { ["-e", $0] } + argv
    }

    static func osascriptLine(_ script: [String], _ argv: [String]) -> String {
        (["/usr/bin/osascript"] + osascriptArgs(script, argv).map(shq)).joined(separator: " ")
    }

    static func plan(_ f: LeftoverFinding) -> Plan {
        var p = Plan()
        for path in f.paths {
            guard LeftoverGuard.allowed(path) else { p.skipped.append(path); continue }
            if Paths.underHome(Paths.resolvedParent(path)) { p.homeTrash.append(path) } else { p.systemTrash.append(path) }
        }
        for lp in f.launchPlists where LeftoverGuard.allowed(lp) {
            if Paths.underHome(Paths.resolvedParent(lp)) {
                p.userBoot.append(lp)
            } else {
                p.adminBoot.append((lp.hasPrefix("/Library/LaunchDaemons/") ? "system" : "gui/\(getuid())", lp))
            }
        }
        return p
    }

    /// Un singur plan pentru mai multe resturi (o singură cerere de parolă de administrator).
    static func plan(_ fs: [LeftoverFinding]) -> Plan {
        var p = Plan()
        for f in fs {
            let q = plan(f)
            p.userBoot += q.userBoot
            p.adminBoot += q.adminBoot
            p.homeTrash += q.homeTrash
            p.systemTrash += q.systemTrash
            p.skipped += q.skipped
        }
        return p
    }

    /// Mută la Coș prin Finder: merge și pentru folderele protejate de macOS (Containers) fără Full Disk Access,
    /// iar pentru /Library Finder cere singur parola de administrator. Păstrează „Put Back”.
    static func finderTrash(_ paths: [String]) -> String? {
        let r = Shell.run("/usr/bin/osascript", osascriptArgs(finderScript, paths), timeout: 300)
        return r.code == 0 ? nil : "Finder: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
    }

    static func execute(_ p: Plan) -> [String] {
        var errors = p.skipped.map { tr("Sărit (protejat): \($0)") }
        // „not loaded” e normal pentru resturi; eroarea de bootout nu oprește mutarea.
        for lp in p.userBoot { Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", lp], timeout: 30) }
        if let cmd = p.adminCommand {
            let r = Shell.run("/usr/bin/osascript", osascriptArgs(adminScript, [cmd]), timeout: 300)
            if r.code != 0 {
                return errors + [tr("Autorizare refuzată; nu am mutat nimic (serviciile ar fi rămas pornite).")]
            }
        }
        var viaFinder = p.systemTrash.filter(Paths.lexists)
        for path in p.homeTrash where Paths.lexists(path) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            catch { viaFinder.append(path) }  // ex. Containers fără Full Disk Access
        }
        if !viaFinder.isEmpty, let e = finderTrash(viaFinder) { errors.append(e) }
        return errors
    }
}

// MARK: - Store

@MainActor
final class LeftoversStore: ObservableObject {
    @Published var findings: [LeftoverFinding] = []
    @Published var scanning = false
    @Published var partial = false
    /// Resturile bifate pentru mutare în bloc.
    @Published var selected: Set<String> = []
    private var generation = 0

    /// Se pot muta din aplicație (cele cu dezinstalator propriu doar se deschid).
    var actionable: [LeftoverFinding] { findings.filter { $0.uninstaller == nil && !$0.paths.isEmpty } }
    var selectedFindings: [LeftoverFinding] { actionable.filter { selected.contains($0.id) } }

    var sections: [(kind: LeftoverKind, items: [LeftoverFinding])] {
        LeftoverKind.allCases.compactMap { k in
            let items = findings.filter { $0.kind == k }
            return items.isEmpty ? nil : (k, items)
        }
    }

    /// Prima scanare: o pornește fie fereastra, fie bara de meniu, nu amândouă.
    func scanIfNeeded() {
        if generation == 0 { scan() }
    }

    func scan() {
        generation += 1
        let gen = generation
        scanning = true
        partial = !FullDiskAccess.granted()
        findings = []
        selected = []
        Task {
            let found = await offMain { LeftoverScanner.scan() }
            guard gen == generation else { return }
            findings = found
            scanning = false
            for f in found {
                let paths = f.shown
                let size = await offMain { Sizer.du(paths) }
                guard gen == generation else { return }
                if let i = findings.firstIndex(where: { $0.id == f.id }) { findings[i].size = size }
            }
        }
    }
}

// MARK: - View

struct LeftoversView: View {
    @ObservedObject var store: LeftoversStore
    let hasFDA: Bool
    var onChange: () -> Void
    @State private var preview: [LeftoverFinding] = []
    @State private var message: (title: String, body: String)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.partial || !hasFDA {
                        Label("Scanare parțială, fără Full Disk Access: folderele protejate (Containers, Group Containers) pot lipsi din rezultate. Un rezultat gol nu înseamnă că nu există resturi.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13)).foregroundStyle(Theme.careFg)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.careBg))
                    }
                    Text("Nimic nu se șterge direct: vezi întâi comenzile exacte, apoi totul se mută la Coș (după „launchctl bootout” pentru serviciile de pornire).")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    if store.scanning {
                        HStack { ProgressView().controlSize(.small); Text("Caut resturi…").foregroundStyle(Theme.muted) }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if store.findings.isEmpty {
                        Text("Nu am găsit resturi.").foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(store.sections, id: \.kind) { s in
                        section(s.kind, s.items)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .sheet(isPresented: Binding(get: { !preview.isEmpty }, set: { if !$0 { preview = [] } })) {
            LeftoverPreviewSheet(findings: preview) { errors in
                let done = preview
                preview = []
                guard let errors else { return }
                message = errors.isEmpty
                    ? (tr("Mutat la Coș"), done.count == 1 ? tr("„\(done[0].title)” a fost mutat la Coș.")
                        : tr("\(done.count) resturi au fost mutate la Coș."))
                    : (tr("Executat parțial"), errors.joined(separator: "\n"))
                onChange()
                store.scan()
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message?.body ?? "") }
    }

    private func section(_ kind: LeftoverKind, _ items: [LeftoverFinding]) -> some View {
        let ids = items.filter { $0.uninstaller == nil && !$0.paths.isEmpty }.map(\.id)
        let on = ids.filter { store.selected.contains($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { !ids.isEmpty && on == ids.count },
                    set: { v in if v { store.selected.formUnion(ids) } else { store.selected.subtract(ids) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(ids.isEmpty)
                    .accessibilityLabel(Text("Selectează tot din \(kind.title)"))
                Text(kind.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                Text(items.count == 1 ? tr("1 rest") : tr("\(items.count) resturi")).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 18)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                    row(f)
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func row(_ f: LeftoverFinding) -> some View {
        let actionable = f.uninstaller == nil && !f.paths.isEmpty
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: Binding(
                get: { store.selected.contains(f.id) },
                set: { v in if v { store.selected.insert(f.id) } else { store.selected.remove(f.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!actionable)
                .accessibilityLabel(Text(f.title))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(f.title).fontWeight(.semibold)
                    RiskMark(risk: f.risk)
                }
                Text(f.detail).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(f.shown.prefix(6), id: \.self) { p in
                    Text(p).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.faint)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if f.shown.count > 6 { Text("+ încă \(f.shown.count - 6)").font(.system(size: 12)).foregroundStyle(Theme.faint) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                if let s = f.size { Text(Fmt.bytes(s)).font(.system(size: 15, weight: .bold)).monospacedDigit() }
                else { ProgressView().controlSize(.small) }
                HStack(spacing: 6) {
                    Button("Arată în Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(f.shown.prefix(20).map { URL(fileURLWithPath: $0) })
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    if let u = f.uninstaller {
                        Button("Deschide dezinstalatorul") { NSWorkspace.shared.open(URL(fileURLWithPath: u)) }
                            .buttonStyle(SecondaryButtonStyle(height: 30)).help("open \(LeftoverActions.shq(u))")
                    } else if actionable {
                        Button("Șterge…") { preview = [f] }
                            .buttonStyle(PrimaryButtonStyle(tint: Theme.danger, height: 30))
                            .help(tr("Arată comenzile exacte, apoi mută la Coș"))
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var footer: some View {
        let sel = store.selectedFindings
        let bytes = sel.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let risky = sel.filter { $0.risk != .safe }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(sel.isEmpty ? tr("Nimic selectat") : tr("Selectat: \(sel.count) resturi · \(Fmt.bytes(bytes))"))
                    .fontWeight(.bold).monospacedDigit()
                Text(risky > 0 ? tr("\(risky) dintre ele nu sunt marcate „Sigur”: verifică înainte.")
                     : tr("Totul se mută la Coș și se poate recupera."))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Doar cele sigure") {
                store.selected = Set(store.actionable.filter { $0.risk == .safe }.map(\.id))
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!store.actionable.contains { $0.risk == .safe })
            Button("Deselectează") { store.selected = [] }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(sel.isEmpty)
            Button(sel.isEmpty ? tr("Șterge selecția") : tr("Șterge selecția (\(sel.count))")) { preview = sel }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.danger))
                .disabled(sel.isEmpty)
        }
        .padding(.horizontal, 24).frame(height: 68)
        .background(Theme.card)
    }
}

struct LeftoverPreviewSheet: View {
    let findings: [LeftoverFinding]
    /// nil = anulat; altfel erorile execuției.
    var finish: ([String]?) -> Void
    @State private var confirmed = false
    @State private var working = false

    var body: some View {
        let plan = LeftoverActions.plan(findings)
        let risky = findings.contains { $0.risk != .safe }
        let bytes = findings.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        VStack(alignment: .leading, spacing: 14) {
            if findings.count == 1, let f = findings.first {
                HStack(spacing: 8) {
                    Text(f.title).font(.title3.weight(.semibold))
                    RiskMark(risk: f.risk)
                }
                Text(f.detail).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Șterge \(findings.count) resturi · \(Fmt.bytes(bytes))?").font(.title3.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(findings) { f in
                            HStack {
                                Text(f.title).lineLimit(1)
                                RiskMark(risk: f.risk)
                                Spacer()
                                Text(Fmt.bytes(f.size)).monospacedDigit().foregroundStyle(Theme.muted)
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            GroupBox("Comenzi (previzualizare, nimic nu a rulat încă)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(plan.lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(plan.skipped, id: \.self) { s in
                            Text("Sărit (protejat): \(s)").font(.caption.monospaced()).foregroundStyle(Theme.careFg)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Text("Dacă FileManager.trashItem e refuzat (Containers fără Full Disk Access), elementul se mută prin Finder. „with administrator privileges” și Finder pentru /Library cer parola de administrator. Totul se poate recupera din Coș până îl golești.")
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if risky {
                Toggle("Am verificat: nu folosesc ce se mută", isOn: $confirmed).toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Anulează") { finish(nil) }.keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(height: 34))
                Button(working ? tr("Se mută…") : tr("Mută la Coș")) { run(plan) }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.danger, height: 34))
                    .disabled(working || plan.lines.isEmpty || (risky && !confirmed))
            }
        }
        .padding(22)
        .frame(width: 680)
    }

    private func run(_ plan: LeftoverActions.Plan) {
        working = true
        Task {
            let errors = await offMain { LeftoverActions.execute(plan) }
            working = false
            finish(errors)
        }
    }
}
