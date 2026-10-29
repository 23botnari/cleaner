import SwiftUI
import AppKit

// MARK: - Model

struct ExplorerItem: Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDir: Bool
    let isProtected: Bool
    var size: Int64?
    var lastAccess: Date?
    /// Motivul pentru care elementul pare inutil (nil = nicio sugestie).
    var hint: String?
    /// Avertisment (ex. fișier de sistem al unei aplicații care nu se șterge direct).
    var note: String?

    /// Folderul în care se află, cu ~ pentru home.
    var location: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.hasPrefix(Paths.realHome) ? "~" + dir.dropFirst(Paths.realHome.count) : dir
    }
}

/// Euristici pentru „probabil inutil”: doar sugestii, ștergerea merge tot prin Coș.
enum Hints {
    static let disposableDirs: [String: String] = [
        "node_modules": "dependențe npm, se reinstalează",
        ".next": "build Next.js, se regenerează",
        ".nuxt": "build Nuxt, se regenerează",
        ".turbo": "cache Turborepo",
        ".parcel-cache": "cache Parcel",
        ".angular": "cache Angular",
        ".expo": "cache Expo",
        ".dart_tool": "cache Dart/Flutter",
        "__pycache__": "cache Python",
        ".pytest_cache": "cache pytest",
        ".mypy_cache": "cache mypy",
        ".gradle": "cache Gradle",
        "DerivedData": "build Xcode, se regenerează",
        "Pods": "dependențe CocoaPods, se reinstalează",
        ".cache": "cache, se reface",
        "Caches": "cache, se reface",
        "cache": "cache, se reface",
        "logs": "log-uri",
    ]
    /// Foldere de build: inutile doar dacă lângă ele e un proiect.
    static let buildDirs: Set<String> = ["build", "dist", "out", "target", ".build"]
    static let projectMarkers = ["package.json", "Cargo.toml", "build.gradle", "build.gradle.kts", "Package.swift",
                                 "pom.xml", "pubspec.yaml", "CMakeLists.txt", "Makefile", "pyproject.toml"]

    static let fileKinds: [String: String] = [
        "dmg": "kit de instalare", "pkg": "kit de instalare", "iso": "imagine de disc", "xip": "arhivă Xcode",
        "apk": "build de aplicație", "aab": "build de aplicație", "ipa": "build de aplicație",
        "zip": "arhivă", "rar": "arhivă", "7z": "arhivă", "tgz": "arhivă", "gz": "arhivă",
        "log": "log", "crash": "raport de crash", "ips": "raport de crash", "dSYM": "simboluri de debug",
    ]

    static let staleAfter: TimeInterval = 180 * 24 * 3600
    static let staleMinSize: Int64 = 100_000_000

    static func reason(name: String, path: String, isDir: Bool, size: Int64?, lastAccess: Date?) -> String? {
        if isDir {
            // Direct în home, acestea pot ține credențiale (gradle.properties, login Expo): fără sugestie.
            let inHomeRoot = (path as NSString).deletingLastPathComponent == Paths.realHome
            if inHomeRoot && [".gradle", ".expo"].contains(name) { return nil }
            if let r = disposableDirs[name] { return r }
            if buildDirs.contains(name) {
                let parent = (path as NSString).deletingLastPathComponent
                if projectMarkers.contains(where: { Paths.lexists(Paths.join(parent, $0)) }) {
                    return "folder de build, se regenerează"
                }
            }
            return nil
        }
        // Fișier din interiorul unui folder de build/cache (ex. node_modules, .cxx, intermediates).
        let comps = path.split(separator: "/").dropLast().map(String.init)
        if let c = comps.first(where: { disposableDirs[$0] != nil || [".cxx", "intermediates"].contains($0) }),
           !(c == ".gradle" || c == ".expo") || !path.hasPrefix(Paths.realHome + "/" + c + "/") {
            return "în \(c), se regenerează"
        }
        let ext = (name as NSString).pathExtension
        if let kind = fileKinds[ext] ?? fileKinds[ext.lowercased()] { return kind }
        if let size, size >= staleMinSize, let lastAccess, Date().timeIntervalSince(lastAccess) > staleAfter {
            return "mare, nedeschis de \(monthsAgo(lastAccess)) luni"
        }
        return nil
    }

    /// Fișiere mari care nu trebuie șterse direct, cu ce să faci în loc.
    static func note(name: String, path: String) -> String? {
        if name == "Docker.raw" {
            return "Discul virtual Docker: NU-l muta la Coș. Folosește „Docker: imagini…” din Recomandări sau Docker Desktop → Troubleshoot."
        }
        if path.contains("/Library/Containers/com.docker.docker/") { return "Date interne Docker: curăță din Docker Desktop." }
        if name.hasSuffix(".app") { return "Aplicație: dezinstaleaz-o din tab-ul „Aplicații”." }
        if name.hasSuffix(".photoslibrary") { return "Biblioteca Photos: curăță din aplicația Photos." }
        if path.contains("/Library/Application Support/MobileSync/Backup/") { return "Backup iPhone: gestionează din Finder → iPhone → Manage Backups." }
        return nil
    }

    static func monthsAgo(_ d: Date) -> Int { max(1, Int(Date().timeIntervalSince(d) / (30 * 24 * 3600))) }
}

private let accessKeys: Set<URLResourceKey> = [.contentAccessDateKey]

private func accessDate(_ path: String) -> Date? {
    try? URL(fileURLWithPath: path).resourceValues(forKeys: accessKeys).contentAccessDate
}

// MARK: - Store

enum ExplorerMode { case folder, bigFiles }

@MainActor
final class ExplorerStore: ObservableObject {
    @Published var path: String = Paths.realHome
    @Published var mode: ExplorerMode = .folder
    @Published var items: [ExplorerItem] = []
    @Published var selection: Set<String> = []
    @Published var error: String?
    @Published var loading = false
    @Published var onlyHints = false
    private var generation = 0

    nonisolated static let bigFileMin: Int64 = 50_000_000
    nonisolated static let bigFileLimit = 300

    var total: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    var pending: Int { items.filter { $0.size == nil }.count }
    var selectedItems: [ExplorerItem] { items.filter { selection.contains($0.path) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + ($1.size ?? 0) } }
    var hintCount: Int { items.filter { $0.hint != nil && !$0.isProtected }.count }

    var visibleItems: [ExplorerItem] {
        items.filter { !onlyHints || $0.hint != nil }.sorted { a, b in
            let sa = a.size ?? -1, sb = b.size ?? -1
            return sa != sb ? sa > sb : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Bucățile căii de la home până la folderul curent, pentru navigare.
    var breadcrumbs: [(name: String, path: String)] {
        var out: [(String, String)] = [("Home", Paths.realHome)]
        let rel = Paths.relative(path)
        guard rel != "." else { return out }
        var cur = Paths.realHome
        for part in rel.split(separator: "/") {
            cur = Paths.join(cur, String(part))
            out.append((String(part), cur))
        }
        return out
    }

    private func begin(_ p: String, mode: ExplorerMode) -> Int? {
        let rp = Paths.realpath(p)
        guard Paths.underHome(rp) else {
            error = "Poți explora doar folderul tău de utilizator."
            return nil
        }
        generation += 1
        path = rp
        self.mode = mode
        items = []
        selection = []
        error = nil
        loading = true
        return generation
    }

    func open(_ p: String) {
        guard let gen = begin(p, mode: .folder) else { return }
        let rp = path
        Task {
            let listing: Result<[ExplorerItem], CleanError> = await offMain {
                do {
                    let names = try FileManager.default.contentsOfDirectory(atPath: rp)
                    return .success(names.map { n in
                        let full = Paths.join(rp, n)
                        var st = stat()
                        let isDir = lstat(full, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
                        let size: Int64? = isDir ? nil : Int64(st.st_blocks) * 512
                        let access = isDir ? nil : accessDate(full)
                        return ExplorerItem(name: n, path: full, isDir: isDir, isProtected: !Paths.deletable(full),
                                            size: size, lastAccess: access,
                                            hint: Hints.reason(name: n, path: full, isDir: isDir, size: size, lastAccess: access))
                    })
                } catch {
                    return .failure(Self.describe(error))
                }
            }
            guard gen == generation else { return }
            loading = false
            switch listing {
            case .failure(let e): error = e.message
            case .success(let list):
                items = list
                await sizeDirs(list.filter(\.isDir).map(\.path), gen: gen)
            }
        }
    }

    /// Cele mai mari fișiere din folderul curent, recursiv.
    func findBigFiles() {
        guard let gen = begin(path, mode: .bigFiles) else { return }
        let rp = path
        Task {
            let found: [ExplorerItem] = await offMain {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .totalFileAllocatedSizeKey, .contentAccessDateKey]
                guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: rp), includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else { return [] }
                var out: [ExplorerItem] = []
                // Pachetele (.app, .bundle, .photoslibrary…) se adună ca un singur element: nu ștergi bucăți din ele.
                var pkg: (path: String, size: Int64, access: Date?)?
                func flushPkg() {
                    guard let p = pkg else { return }
                    pkg = nil
                    guard p.size >= Self.bigFileMin else { return }
                    let n = (p.path as NSString).lastPathComponent
                    out.append(Self.bigItem(path: p.path, name: n, size: p.size, access: p.access))
                }
                for case let url as URL in en {
                    let full = url.path
                    if let p = pkg, !full.hasPrefix(p.path + "/") { flushPkg() }
                    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                    if pkg == nil, v.isPackage == true {
                        pkg = (full, 0, v.contentAccessDate)
                        continue
                    }
                    guard v.isRegularFile == true else { continue }
                    let size = Int64(v.totalFileAllocatedSize ?? 0)
                    if pkg != nil { pkg!.size += size; continue }
                    guard size >= Self.bigFileMin else { continue }
                    out.append(Self.bigItem(path: full, name: url.lastPathComponent, size: size, access: v.contentAccessDate))
                }
                flushPkg()
                return Array(out.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(Self.bigFileLimit))
            }
            guard gen == generation else { return }
            loading = false
            items = found
        }
    }

    nonisolated static func bigItem(path: String, name: String, size: Int64, access: Date?) -> ExplorerItem {
        var item = ExplorerItem(name: name, path: path, isDir: false, isProtected: !Paths.deletable(path),
                                size: size, lastAccess: access,
                                hint: Hints.reason(name: name, path: path, isDir: false, size: size, lastAccess: access))
        item.note = Hints.note(name: name, path: path)
        if item.note != nil { item.hint = nil }
        return item
    }

    func refresh() {
        mode == .folder ? open(path) : findBigFiles()
    }

    nonisolated private static func describe(_ error: Error) -> CleanError {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
            return CleanError(message: "Acces refuzat. Dă aplicației Full Disk Access: System Settings → Privacy & Security → Full Disk Access.")
        }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError {
            return CleanError(message: "Folderul nu mai există.")
        }
        return CleanError(message: e.localizedDescription)
    }

    private func sizeDirs(_ dirs: [String], gen: Int) async {
        await withTaskGroup(of: (String, Int64).self) { group in
            var it = dirs.makeIterator()
            func next() -> Bool {
                guard let p = it.next() else { return false }
                group.addTask { (p, await offMain { Sizer.du([p]) }) }
                return true
            }
            for _ in 0..<6 { _ = next() }
            for await (p, size) in group {
                guard gen == generation else { group.cancelAll(); return }
                if let i = items.firstIndex(where: { $0.path == p }) { items[i].size = size }
                _ = next()
            }
        }
    }

    func toggle(_ item: ExplorerItem) {
        guard !item.isProtected, item.note == nil else { return }
        if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
    }

    func selectHints() {
        selection = Set(items.filter { $0.hint != nil && !$0.isProtected }.map(\.path))
    }

    func reveal(_ item: ExplorerItem) {
        let rp = Paths.resolvedParent(item.path)
        guard Paths.underHome(rp) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rp)])
    }

    /// Mută la Coș (recuperabil). Întoarce mărimea mutată și erorile.
    func moveToTrash(_ list: [ExplorerItem]) -> (moved: Int, freed: Int64, errors: [String]) {
        var moved = 0, freed: Int64 = 0
        var errors: [String] = []
        for item in list {
            let full = Paths.resolvedParent(item.path)
            guard Paths.lexists(full) else { errors.append("\(item.name): nu mai există."); continue }
            guard Paths.deletable(full) else { errors.append("\(item.name): protejat."); continue }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: full), resultingItemURL: nil)
                items.removeAll { $0.path == item.path }
                selection.remove(item.path)
                moved += 1
                freed += item.size ?? 0
            } catch {
                errors.append("\(item.name): \(error.localizedDescription)")
            }
        }
        return (moved, freed, errors)
    }
}

// MARK: - View

struct HintBadge: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "lightbulb.fill")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow.opacity(0.16)))
            .foregroundStyle(Color.yellow)
    }
}

struct ExplorerView: View {
    @ObservedObject var store: ExplorerStore
    var onChange: () -> Void
    @State private var toTrash: [ExplorerItem] = []
    @State private var message: (title: String, body: String)?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !store.selection.isEmpty { selectionBar }
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !toTrash.isEmpty }, set: { if !$0 { toTrash = [] } }),
                            titleVisibility: .visible) {
            Button("Mută la Coș", role: .destructive) {
                let r = store.moveToTrash(toTrash)
                toTrash = []
                onChange()
                if !r.errors.isEmpty {
                    message = ("Unele elemente nu au fost mutate",
                               "Mutate: \(r.moved) (\(Fmt.bytes(r.freed))).\n\n" + r.errors.prefix(12).joined(separator: "\n"))
                }
            }
            Button("Anulează", role: .cancel) { toTrash = [] }
        } message: {
            Text(trashMessage)
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message?.body ?? "") }
    }

    private var trashMessage: String {
        var lines: [String]
        if toTrash.count == 1 {
            lines = ["Locație: " + toTrash[0].path]
        } else {
            lines = toTrash.prefix(8).map { "• " + $0.path }
            if toTrash.count > 8 { lines.append("… și încă \(toTrash.count - 8)") }
        }
        let total: Int64 = toTrash.reduce(0) { $0 + ($1.size ?? 0) }
        lines.append("")
        lines.append(Fmt.bytes(total) + ". Le poți recupera din Coș până îl golești; spațiul se eliberează după golirea Coșului.")
        return lines.joined(separator: "\n")
    }

    private var trashTitle: String {
        toTrash.count == 1 ? "Muți „\(toTrash[0].name)” la Coș?" : "Muți \(toTrash.count) elemente la Coș?"
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 4) {
            ForEach(Array(store.breadcrumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(c.name) { store.open(c.path) }
                    .buttonStyle(.link)
                    .foregroundStyle(i == store.breadcrumbs.count - 1 && store.mode == .folder ? Color.primary : Color.accentColor)
            }
            if store.mode == .bigFiles {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Text("Fișiere mari").fontWeight(.semibold)
            }
            Spacer()
            if store.pending > 0 { ProgressView().controlSize(.small) }
            Text("Total: \(Fmt.bytes(store.total))").foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 24).padding(.top, 10)
        HStack(spacing: 10) {
            Toggle("Doar sugestii", isOn: $store.onlyHints)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Selectează sugestiile (\(store.hintCount))") { store.selectHints() }
                .disabled(store.hintCount == 0)
            if store.mode == .folder {
                Button { store.findBigFiles() } label: { Label("Fișiere mari aici", systemImage: "doc.viewfinder") }
                    .help("Caută recursiv fișierele de peste \(Fmt.bytes(ExplorerStore.bigFileMin)) din acest folder")
            } else {
                Button { store.open(store.path) } label: { Label("Înapoi la folder", systemImage: "folder") }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let err = store.error {
            VStack(spacing: 12) {
                Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if err.contains("Full Disk Access") {
                    Button("Deschide setarea") { FullDiskAccess.openSettings() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else if store.loading {
            VStack(spacing: 10) {
                ProgressView()
                if store.mode == .bigFiles {
                    Text("Caut fișiere mari în „\((store.path as NSString).lastPathComponent)”…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleItems.isEmpty {
            Text(store.mode == .bigFiles ? "Niciun fișier peste \(Fmt.bytes(ExplorerStore.bigFileMin))."
                 : store.onlyHints ? "Nicio sugestie în acest folder." : "Folder gol.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let items = store.visibleItems
            let maxSize = max(1, items.compactMap(\.size).max() ?? 1)
            List(items) { it in row(it, maxSize: maxSize) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var selectionBar: some View {
        HStack {
            Text("\(store.selection.count) selectate • \(Fmt.bytes(store.selectedSize))")
                .fontWeight(.semibold).monospacedDigit()
            Spacer()
            Button("Deselectează") { store.selection = [] }
            Button("Mută selecția la Coș") { toTrash = store.selectedItems }
                .buttonStyle(.borderedProminent).tint(.red)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func row(_ it: ExplorerItem, maxSize: Int64) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { store.selection.contains(it.path) }, set: { _ in store.toggle(it) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(it.isProtected)
            Image(nsImage: NSWorkspace.shared.icon(forFile: it.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if it.isDir {
                        Button(it.name) { store.open(it.path) }
                            .buttonStyle(.plain).fontWeight(.medium)
                            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    } else {
                        Text(it.name).lineLimit(1).truncationMode(.middle)
                    }
                    if it.isProtected {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary).help("Protejat")
                    }
                }
                if store.mode == .bigFiles {
                    Text("Locație: \(it.location)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let note = it.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    if let hint = it.hint { HintBadge(text: "Probabil inutil: \(hint)") }
                    if !it.isDir, let d = it.lastAccess {
                        Text("Deschis ultima dată: \(Self.dateFmt.string(from: d))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if let s = it.size {
                    Text(Fmt.bytes(s)).fontWeight(.semibold).monospacedDigit()
                } else {
                    ProgressView().controlSize(.mini)
                }
                ProgressView(value: Double(it.size ?? 0), total: Double(maxSize)).tint(.gray)
            }
            .frame(width: 120)
            Button("Arată în Finder") { store.reveal(it) }
                .controlSize(.small)
            Button("Mută la Coș") { toTrash = [it] }
                .controlSize(.small)
                .help(it.note ?? (it.isProtected ? "Element protejat" : "Recuperabil din Coș"))
                .disabled(it.isProtected || it.note != nil)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if it.isDir { Button("Deschide") { store.open(it.path) } }
            Button("Arată în Finder") { store.reveal(it) }
            Button("Mută la Coș") { toTrash = [it] }.disabled(it.isProtected || it.note != nil)
        }
    }
}
