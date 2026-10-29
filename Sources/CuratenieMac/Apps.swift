import SwiftUI
import AppKit
import CoreServices

// MARK: - Model

struct VolumeInfo: Sendable, Hashable {
    let name: String
    let isInternal: Bool
    var label: String { isInternal ? "Mac (disc intern)" : "\(name) (extern)" }

    static func of(_ path: String) -> VolumeInfo {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey])
        let root = v?.volumeIsRootFileSystem ?? false
        // Volumul de date al sistemului e mereu intern, chiar dacă nu e raportat ca „root”.
        let isInt = root || (v?.volumeIsInternal ?? false) || !path.hasPrefix("/Volumes/")
        return VolumeInfo(name: v?.volumeLocalizedName ?? "?", isInternal: isInt)
    }
}

struct AppEntry: Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let bundleID: String
    let version: String
    let volume: VolumeInfo
    let lastUsed: Date?
    /// Are drivere / servicii de sistem: trebuie folosit dezinstalatorul ei.
    let hasSystemParts: Bool
    var size: Int64?
    /// Datele aplicației din ~/Library (Application Support, Caches, Containers…), mereu pe discul intern.
    var dataSize: Int64?
    var dataTop: String?

    var total: Int64? {
        guard let size else { return nil }
        return size + (dataSize ?? 0)
    }

    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasPrefix(Paths.realHome) ? "~" + dir.dropFirst(Paths.realHome.count) : dir
    }
}

struct Leftover: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let size: Int64
    var display: String { "~" + path.dropFirst(Paths.realHome.count) }
}

enum AppScanner {
    static let ownBundleID = Bundle.main.bundleIdentifier ?? "io.webitfactory.CuratenieMac"

    static func roots() -> [String] {
        var r = ["/Applications", Paths.hp("Applications")]
        for v in Paths.children("/Volumes") where Paths.realpath(v) != "/" {
            r.append(v)
            r.append(Paths.join(v, "Applications"))
        }
        return r
    }

    /// Aplicațiile din /Applications, ~/Applications și de pe volumele externe (rădăcină + Applications), 2 niveluri.
    static func scan() -> [AppEntry] {
        var seen = Set<String>()
        var out: [AppEntry] = []
        func visit(_ dir: String, depth: Int) {
            for p in Paths.children(dir) {
                let name = (p as NSString).lastPathComponent
                if name.hasPrefix(".") { continue }
                if name.hasSuffix(".app") {
                    let real = Paths.realpath(p)
                    guard seen.insert(real).inserted, let e = entry(real) else { continue }
                    out.append(e)
                } else if depth < 1, Paths.isDir(p), !Paths.isSymlink(p) {
                    visit(p, depth: depth + 1)
                }
            }
        }
        for root in roots() { visit(root, depth: root.hasPrefix("/Volumes/") && !root.hasSuffix("/Applications") ? 1 : 0) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func entry(_ path: String) -> AppEntry? {
        guard let b = Bundle(path: path) else { return nil }
        let id = b.bundleIdentifier ?? ""
        // Safari face parte din sistem (protejat de SIP); celelalte aplicații Apple (Xcode, Pages…) se pot dezinstala.
        if id == "com.apple.Safari" || id == ownBundleID { return nil }
        let info = b.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let version = (info["CFBundleShortVersionString"] as? String) ?? ""
        var lastUsed: Date?
        if let md = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) {
            lastUsed = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
        }
        let sys = ["Contents/Library/SystemExtensions", "Contents/Library/LaunchServices", "Contents/Library/LaunchDaemons"]
            .contains { Paths.lexists(Paths.join(path, $0)) }
        return AppEntry(name: name, path: path, bundleID: id, version: version, volume: VolumeInfo.of(path),
                        lastUsed: lastUsed, hasSystemParts: sys, size: nil)
    }

    /// Fișiere lăsate de aplicație în ~/Library, după bundle ID (și numele exact al aplicației).
    static func leftovers(for app: AppEntry) -> [Leftover] {
        let b = app.bundleID
        guard !b.isEmpty else { return [] }
        let L = Paths.hp("Library")
        let appFile = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
        var c: [String] = [
            "Application Support/\(b)", "Caches/\(b)", "Preferences/\(b).plist", "Containers/\(b)",
            "Saved Application State/\(b).savedState", "HTTPStorages/\(b)", "HTTPStorages/\(b).binarycookies",
            "WebKit/\(b)", "Logs/\(b)", "Cookies/\(b).binarycookies", "Application Scripts/\(b)",
        ].map { Paths.join(L, $0) }
        // Numele aplicației doar dacă e destul de specific (evită foldere generice).
        // …și doar dacă numele apare în bundle ID (altfel ex. aplicația web Edge „Claude” ar lua datele lui Claude Desktop).
        let idLower = b.lowercased()
        for n in Set([app.name, appFile]) where n.count >= 4
            && idLower.contains(n.lowercased().replacingOccurrences(of: " ", with: "")) {
            c += ["Application Support/\(n)", "Caches/\(n)", "Logs/\(n)"].map { Paths.join(L, $0) }
        }
        c += Paths.children(Paths.join(L, "Preferences", "ByHost")).filter { ($0 as NSString).lastPathComponent.hasPrefix(b + ".") }
        c += Paths.children(Paths.join(L, "LaunchAgents")).filter { ($0 as NSString).lastPathComponent.hasPrefix(b) }
        c += Paths.children(Paths.join(L, "Group Containers")).filter {
            let n = ($0 as NSString).lastPathComponent
            return n.hasSuffix("." + b) || n == "group." + b || n.hasPrefix("group." + b + ".")
        }
        var seen = Set<String>()
        return c.filter { Paths.lexists($0) && Paths.deletable($0) && seen.insert(Paths.realpath($0)).inserted }
            .map { Leftover(path: $0, size: Sizer.du([$0])) }
            .sorted { $0.size > $1.size }
    }

    /// Reguli pentru .app în afara home-ului: doar în /Applications sau ~/Applications, pe discul intern, fără Apple.
    static func uninstallable(_ app: AppEntry) -> String? {
        let real = Paths.realpath(app.path)
        guard real.hasSuffix(".app"), Paths.isDir(real) else { return "Nu e un pachet de aplicație." }
        guard real.hasPrefix("/Applications/") || real.hasPrefix(Paths.realHome + "/Applications/") else {
            return "Dezinstalez doar aplicații din /Applications sau ~/Applications."
        }
        guard VolumeInfo.of(real).isInternal else { return "Aplicația e pe un disc extern; nu o ating." }
        guard app.bundleID != "com.apple.Safari", app.bundleID != ownBundleID else { return "Aplicație de sistem." }
        return nil
    }

    static func runningApp(_ app: AppEntry) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier == app.bundleID && !app.bundleID.isEmpty)
                || ($0.bundleURL.map { Paths.realpath($0.path) } == Paths.realpath(app.path))
        }
    }

    /// Mută aplicația la Coș; dacă e a altui utilizator (ex. din App Store), Finder cere parola de administrator.
    static func trashApp(_ path: String) -> String? {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return nil
        } catch {
            let r = Shell.run("/usr/bin/osascript", ["-e", "on run argv", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                                                     "-e", "end run", path], timeout: 300)
            if r.code == 0 { return nil }
            return "Nu am putut muta aplicația la Coș: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"
        }
    }
}

// MARK: - Store

@MainActor
final class AppsStore: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var showExternal = true
    private var generation = 0

    var visible: [AppEntry] {
        apps.filter { showExternal || $0.volume.isInternal }.sorted { a, b in
            let sa = a.total ?? -1, sb = b.total ?? -1
            return sa != sb ? sa > sb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Pe discul intern: aplicațiile interne + datele tuturor aplicațiilor (datele stau mereu în ~/Library).
    var internalTotal: Int64 {
        apps.reduce(0) { $0 + ($1.volume.isInternal ? ($1.size ?? 0) : 0) + ($1.dataSize ?? 0) }
    }

    func scan() {
        generation += 1
        let gen = generation
        loading = true
        apps = []
        Task {
            let list = await offMain { AppScanner.scan() }
            guard gen == generation else { return }
            apps = list
            loading = false
            await withTaskGroup(of: (String, Int64).self) { group in
                var it = list.map(\.path).makeIterator()
                func next() -> Bool {
                    guard let p = it.next() else { return false }
                    group.addTask { (p, await offMain { Sizer.du([p]) }) }
                    return true
                }
                for _ in 0..<4 { _ = next() }
                for await (p, size) in group {
                    guard gen == generation else { group.cancelAll(); return }
                    if let i = apps.firstIndex(where: { $0.path == p }) { apps[i].size = size }
                    _ = next()
                }
            }
            for a in list {
                let data = await offMain { AppScanner.leftovers(for: a) }
                guard gen == generation else { return }
                if let i = apps.firstIndex(where: { $0.path == a.path }) {
                    apps[i].dataSize = data.reduce(0) { $0 + $1.size }
                    apps[i].dataTop = data.first.map { $0.display }
                }
            }
        }
    }

    func remove(_ path: String) { apps.removeAll { $0.path == path } }
}

// MARK: - View

struct AppsView: View {
    @ObservedObject var store: AppsStore
    var onChange: () -> Void
    @State private var sheetApp: AppEntry?
    @State private var quit: QuitPrompt?
    @State private var message: (title: String, body: String)?

    static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Aplicații pe discul intern: \(Fmt.bytes(store.internalTotal))")
                    .foregroundStyle(.secondary).monospacedDigit()
                if store.apps.contains(where: { $0.size == nil }) { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Arată și aplicațiile de pe discuri externe", isOn: $store.showExternal).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            Divider()
            if store.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let items = store.visible
                let maxSize = max(1, items.compactMap(\.total).max() ?? 1)
                List(items) { a in row(a, maxSize: maxSize) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .sheet(item: $sheetApp) { app in
            UninstallSheet(app: app) { result in
                sheetApp = nil
                switch result {
                case .cancelled: break
                case .done(let freed, let errors):
                    store.remove(app.path)
                    onChange()
                    message = errors.isEmpty
                        ? ("„\(app.name)” a fost mutată la Coș", "\(Fmt.bytes(freed)) se eliberează după golirea Coșului.")
                        : ("Dezinstalare parțială", errors.joined(separator: "\n"))
                case .failed(let err):
                    message = ("Nu am putut dezinstala „\(app.name)”", err)
                }
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message?.body ?? "") }
        .quitPrompt($quit, message: $message)
    }

    @ViewBuilder
    private func row(_ a: AppEntry, maxSize: Int64) -> some View {
        let blocked = AppScanner.uninstallable(a)
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(a.name).fontWeight(.semibold)
                    if !a.version.isEmpty { Text(a.version).font(.caption).foregroundStyle(.tertiary) }
                    VolumeBadge(volume: a.volume)
                }
                Text(a.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if let top = a.dataTop, (a.dataSize ?? 0) >= 50_000_000 {
                    Text("Date: \(top)\(a.volume.isInternal ? "" : " — pe discul intern")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    if let d = a.lastUsed {
                        Text("Folosită ultima dată: \(Self.dateFmt.string(from: d))").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("Nefolosită niciodată (după Spotlight)").font(.caption).foregroundStyle(.tertiary)
                    }
                    if a.hasSystemParts {
                        Text("Are componente de sistem: preferă dezinstalatorul ei").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if let t = a.total { Text(Fmt.bytes(t)).fontWeight(.semibold).monospacedDigit() }
                else { ProgressView().controlSize(.mini) }
                if let s = a.size {
                    Text("app \(Fmt.bytes(s)) + date \(a.dataSize.map { Fmt.bytes($0) } ?? "…")")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(a.total ?? 0), total: Double(maxSize)).tint(.gray)
            }
            .frame(width: 170)
            Button("Arată în Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
                .controlSize(.small)
            Button("Dezinstalează…") { ask(a) }
                .controlSize(.small)
                .disabled(blocked != nil)
                .help(blocked ?? "Mută aplicația și fișierele ei din ~/Library la Coș")
        }
        .padding(.vertical, 4)
        .opacity(a.volume.isInternal ? 1 : 0.7)
    }

    private func ask(_ a: AppEntry) {
        let running = AppQuitter.matching(bundleID: a.bundleID, path: a.path)
        if running.isEmpty {
            sheetApp = a
        } else {
            quit = QuitPrompt(name: a.name, apps: running, action: "dezinstalare") { ask(a) }
        }
    }
}

struct VolumeBadge: View {
    let volume: VolumeInfo
    var body: some View {
        Label(volume.label, systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(volume.isInternal ? Color.blue.opacity(0.16) : Color.purple.opacity(0.18)))
            .foregroundStyle(volume.isInternal ? Color.blue : Color.purple)
    }
}

enum UninstallResult {
    case cancelled
    case done(freed: Int64, errors: [String])
    case failed(String)
}

struct UninstallSheet: View {
    let app: AppEntry
    var finish: (UninstallResult) -> Void
    @State private var leftovers: [Leftover]?
    @State private var selected: Set<String> = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dezinstalezi „\(app.name)”?").font(.title3.weight(.semibold))
                    HStack { VolumeBadge(volume: app.volume); Text("aplicația: \(Fmt.bytes(app.size))").foregroundStyle(.secondary) }
                }
            }
            GroupBox("Aplicația") {
                Text(app.path).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if app.hasSystemParts {
                Text("Aplicația are drivere sau servicii de sistem. Dacă are un dezinstalator propriu (ex. „Uninstall …”), folosește-l pe acela; mutarea la Coș poate lăsa componente active.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            GroupBox("Fișiere rămase în ~/Library") {
                if let leftovers {
                    if leftovers.isEmpty {
                        Text("Nu am găsit fișiere rămase.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(leftovers) { l in
                                    Toggle(isOn: Binding(get: { selected.contains(l.path) },
                                                         set: { on in if on { selected.insert(l.path) } else { selected.remove(l.path) } })) {
                                        HStack {
                                            Text(l.display).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(Fmt.bytes(l.size)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        Text("Datele din aceste foldere (setări, conturi, istoric) se pierd după golirea Coșului. Debifează ce vrei să păstrezi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Caut fișiere rămase…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Totul se mută la Coș și poate fi recuperat până îl golești.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Anulează") { finish(.cancelled) }.keyboardShortcut(.cancelAction)
                Button(working ? "Se mută…" : "Mută la Coș") { run() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(leftovers == nil || working)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            let a = app
            let found = await offMain { AppScanner.leftovers(for: a) }
            leftovers = found
            selected = Set(found.map(\.path))
        }
    }

    private func run() {
        working = true
        let a = app
        let chosen = (leftovers ?? []).filter { selected.contains($0.path) }
        Task {
            if AppScanner.runningApp(a) {
                working = false
                finish(.failed("Închide \(a.name) înainte de dezinstalare."))
                return
            }
            if let why = AppScanner.uninstallable(a) {
                working = false
                finish(.failed(why))
                return
            }
            let result: UninstallResult = await offMain {
                if let err = AppScanner.trashApp(Paths.realpath(a.path)) { return .failed(err) }
                var errors: [String] = []
                var freed = a.size ?? 0
                for l in chosen {
                    guard Paths.deletable(l.path) else { errors.append("Sărit (protejat): \(l.display)"); continue }
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: l.path), resultingItemURL: nil)
                        freed += l.size
                    } catch {
                        errors.append("\(l.display): \(error.localizedDescription)")
                    }
                }
                return .done(freed: freed, errors: errors)
            }
            working = false
            finish(result)
        }
    }
}
