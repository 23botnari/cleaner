import SwiftUI
import AppKit
import CoreServices

// MARK: - Model

struct VolumeInfo: Sendable, Hashable {
    let name: String
    let isInternal: Bool
    var label: String { isInternal ? tr("Mac (disc intern)") : tr("\(name) (extern)") }

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
        guard real.hasSuffix(".app"), Paths.isDir(real) else { return tr("Nu e un pachet de aplicație.") }
        guard real.hasPrefix("/Applications/") || real.hasPrefix(Paths.realHome + "/Applications/") else {
            return tr("Dezinstalez doar aplicații din /Applications sau ~/Applications.")
        }
        guard VolumeInfo.of(real).isInternal else { return tr("Aplicația e pe un disc extern; nu o ating.") }
        guard app.bundleID != "com.apple.Safari", app.bundleID != ownBundleID else { return tr("Aplicație de sistem.") }
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
            return tr("Nu am putut muta aplicația la Coș: \(String(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))")
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
    @State private var selectedID: String?
    @State private var quit: QuitPrompt?
    @State private var message: (title: String, body: String)?

    static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var body: some View {
        let items = store.visible
        let maxSize = Double(max(1, items.compactMap(\.total).max() ?? 1))
        let selected = items.first { $0.id == selectedID } ?? items.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    legend(Theme.dyn(0x3D6FE0, 0x5B8AF0), "Aplicația")
                    legend(Theme.dyn(0xA9C0F5, 0x3A5490), "Date în ~/Library")
                    if store.apps.contains(where: { $0.size == nil || $0.dataSize == nil }) { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Doar discul intern", isOn: Binding(get: { !store.showExternal }, set: { store.showExternal = !$0 }))
                        .toggleStyle(.checkbox)
                }
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 28).padding(.bottom, 10)
                if store.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { a in row(a, maxSize: maxSize, on: a.id == selected?.id) }
                        }
                        .padding(.leading, 28).padding(.trailing, 16).padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if let selected {
                    AppInspector(app: selected, uninstall: { chosen in ask(selected, chosen: chosen) })
                        .id(selected.id)
                } else {
                    Text("Alege o aplicație.").foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 340)
            .frame(maxHeight: .infinity)
            .background(Theme.card)
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message?.body ?? "") }
        .quitPrompt($quit, message: $message)
    }

    private func legend(_ c: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(label).foregroundStyle(Theme.muted)
        }
        .fixedSize()
    }

    private func row(_ a: AppEntry, maxSize: Double, on: Bool) -> some View {
        Button { selectedID = a.id } label: {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(a.name).fontWeight(.semibold).lineLimit(1).layoutPriority(2)
                        VolumePill(volume: a.volume)
                        if AppScanner.runningApp(a) {
                            HStack(spacing: 4) {
                                Circle().fill(Theme.reclaim).frame(width: 6, height: 6)
                                Text("Rulează")
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.safeFg)
                            .fixedSize()
                        }
                    }
                    Text(a.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle().fill(Theme.dyn(0x3D6FE0, 0x5B8AF0))
                                .frame(width: g.size.width * Double(a.size ?? 0) / maxSize)
                            Rectangle().fill(Theme.dyn(0xA9C0F5, 0x3A5490))
                                .frame(width: g.size.width * Double(a.dataSize ?? 0) / maxSize)
                            Spacer(minLength: 0)
                        }
                        .background(Theme.lineSoft)
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    if let t = a.total { Text(Fmt.bytes(t)).font(.system(size: 15, weight: .bold)).monospacedDigit() }
                    else { ProgressView().controlSize(.small) }
                    if let s = a.size {
                        Text("app \(Fmt.bytes(s)) + date \(a.dataSize.map { Fmt.bytes($0) } ?? "…")")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.accent : Theme.line, lineWidth: on ? 1.5 : 1))
        .opacity(a.volume.isInternal ? 1 : 0.8)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func ask(_ a: AppEntry, chosen: [Leftover]) {
        let running = AppQuitter.matching(bundleID: a.bundleID, path: a.path)
        guard running.isEmpty else {
            quit = QuitPrompt(name: a.name, apps: running, action: tr("dezinstalare")) { ask(a, chosen: chosen) }
            return
        }
        Task {
            switch await Uninstaller.run(a, leftovers: chosen) {
            case .cancelled: break
            case .done(let freed, let errors):
                store.remove(a.path)
                selectedID = nil
                onChange()
                message = errors.isEmpty
                    ? (tr("„\(a.name)” a fost mutată la Coș"), tr("\(Fmt.bytes(freed)) se eliberează după golirea Coșului."))
                    : (tr("Dezinstalare parțială"), errors.joined(separator: "\n"))
            case .failed(let err):
                message = (tr("Nu am putut dezinstala „\(a.name)”"), err)
            }
        }
    }
}

enum UninstallResult {
    case cancelled
    case done(freed: Int64, errors: [String])
    case failed(String)
}

enum Uninstaller {
    static func run(_ a: AppEntry, leftovers chosen: [Leftover]) async -> UninstallResult {
        if AppScanner.runningApp(a) { return .failed(tr("Închide \(a.name) înainte de dezinstalare.")) }
        if let why = AppScanner.uninstallable(a) { return .failed(why) }
        return await offMain {
            if let err = AppScanner.trashApp(Paths.realpath(a.path)) { return .failed(err) }
            var errors: [String] = []
            var freed = a.size ?? 0
            for l in chosen {
                guard Paths.deletable(l.path) else { errors.append(tr("Sărit (protejat): \(l.display)")); continue }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: l.path), resultingItemURL: nil)
                    freed += l.size
                } catch {
                    errors.append("\(l.display): \(error.localizedDescription)")
                }
            }
            return .done(freed: freed, errors: errors)
        }
    }
}

/// Panoul din dreapta: detalii, ce se mută la Coș (cu bife), închidere automată.
struct AppInspector: View {
    let app: AppEntry
    var uninstall: ([Leftover]) -> Void
    @State private var leftovers: [Leftover]?
    @State private var keep: Set<String> = []
    @State private var confirming = false

    var body: some View {
        let blocked = AppScanner.uninstallable(app)
        let running = AppScanner.runningApp(app)
        let chosen = (leftovers ?? []).filter { !keep.contains($0.path) }
        let bytes = (app.size ?? 0) + chosen.reduce(0) { $0 + $1.size }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.system(size: 18, weight: .bold)).lineLimit(2)
                        HStack(spacing: 8) {
                            if !app.version.isEmpty { Text(app.version).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                            VolumePill(volume: app.volume, long: true)
                        }
                    }
                }
                Text(app.path)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lineSoft))
                HStack(alignment: .top) {
                    stat("APLICAȚIA", Fmt.bytes(app.size))
                    stat("DATE", Fmt.bytes(app.dataSize))
                    stat("FOLOSITĂ", app.lastUsed.map { AppsView.dateFmt.string(from: $0) } ?? "—")
                }
            }
            .padding(22)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !app.volume.isInternal {
                        notice("externaldrive", Theme.extBg, Theme.extFg,
                               tr("Pe \(app.volume.name). Nu ocupă loc pe Mac și nu se dezinstalează de aici."))
                    }
                    if app.hasSystemParts {
                        notice("exclamationmark.triangle", Theme.careBg, Theme.careFg,
                               tr("Are componente de sistem. Folosește dezinstalatorul ei, altfel pot rămâne servicii active."))
                    }
                    if blocked == nil {
                        Text("Se mută la Coș").font(.system(size: 13, weight: .bold))
                        HStack(spacing: 10) {
                            Toggle("", isOn: .constant(true)).toggleStyle(.checkbox).labelsHidden().disabled(true)
                            Text((app.path as NSString).lastPathComponent)
                                .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(app.size)).fontWeight(.semibold).monospacedDigit()
                        }
                        .font(.system(size: 13))
                        if let leftovers {
                            ForEach(leftovers) { l in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(get: { !keep.contains(l.path) },
                                                             set: { on in if on { keep.remove(l.path) } else { keep.insert(l.path) } }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                        .accessibilityLabel(Text(l.display))
                                    Text(l.display).font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1).truncationMode(.head)
                                        .help(l.display)
                                    Spacer()
                                    Text(Fmt.bytes(l.size)).fontWeight(.semibold).monospacedDigit()
                                }
                                .font(.system(size: 13))
                            }
                            Text("Debifează datele pe care vrei să le păstrezi (setări, conturi, istoric). Totul se poate recupera din Coș.")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Caut fișiere rămase…") }
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        if running {
                            notice("power", Theme.safeBg, Theme.safeFg,
                                   tr("\(app.name) rulează. O închid normal înainte; dacă nu se închide în 10 secunde, te întreb dacă o forțez."))
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            VStack(spacing: 10) {
                if blocked == nil {
                    HStack {
                        Text("Total la Coș").foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Fmt.bytes(bytes)).fontWeight(.bold).monospacedDigit()
                    }
                    .font(.system(size: 13))
                }
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help(tr("Arată în Finder"))
                    .accessibilityLabel(Text("Arată în Finder"))
                    Button(blocked != nil ? tr("Pe disc extern") : running ? tr("Închide și dezinstalează") : tr("Dezinstalează")) {
                        confirming = true
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.danger, fill: true))
                    .disabled(blocked != nil || leftovers == nil)
                    .help(blocked ?? "")
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .task {
            let a = app
            leftovers = await offMain { AppScanner.leftovers(for: a) }
        }
        .confirmationDialog(Text("Muți „\(app.name)” la Coș?"), isPresented: $confirming, titleVisibility: .visible) {
            Button("Dezinstalează", role: .destructive) { uninstall(chosen) }
            Button("Anulează", role: .cancel) {}
        } message: {
            Text("\(Fmt.bytes(bytes)) în \(chosen.count + 1) elemente. Totul se poate recupera din Coș până îl golești.")
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.muted)
            Text(value).fontWeight(.bold).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ icon: String, _ bg: Color, _ fg: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .foregroundStyle(fg)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(bg))
    }
}
