import SwiftUI
import AppKit

/// Text tradus pentru valori `String` (nume, descrieri, mesaje). `Text("literal")` se traduce singur;
/// `Text(variabilăString)` nu, așa că șirurile construite în cod trec prin aici.
func tr(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// Cheie dinamică (ex. numele grupului, păstrat în română ca identificator stabil).
func trKey(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

// MARK: - Secțiuni

enum Section: String, Hashable, CaseIterable {
    case overview, rec, big, exp, apps, left, start, settings

    /// Ce apare în lista principală din bara laterală (Setări are butonul ei, jos).
    static let main: [Section] = [.overview, .rec, .big, .exp, .apps, .left, .start]

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Prezentare"
        case .rec: "Recomandări"
        case .big: "Fișiere mari"
        case .exp: "Explorator"
        case .apps: "Aplicații"
        case .left: "Resturi"
        case .start: "Pornire automată"
        case .settings: "Setări"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .rec: "checklist"
        case .big: "doc.text.magnifyingglass"
        case .exp: "folder"
        case .apps: "square.grid.2x2"
        case .left: "shippingbox"
        case .start: "power"
        case .settings: "gearshape"
        }
    }
}

enum GroupInfo {
    static func icon(_ group: String) -> String {
        switch group {
        case "Aplicații de chat": "bubble.left.and.bubble.right"
        case "Dezvoltare": "hammer"
        case "Simulatoare iOS": "iphone"
        case "Sistem și altele": "gearshape"
        case "Browsere": "globe"
        case "Fișiere duplicate": "doc.on.doc"
        case "node_modules din proiecte": "shippingbox"
        case "Build-uri din proiecte": "hammer.circle"
        case "Modele AI locale": "cpu"
        case "Android": "candybarphone"
        case "Claude": "terminal"
        case "Descărcări": "arrow.down.circle"
        case "iPhone / iPad": "ipad.and.iphone"
        default: "folder"
        }
    }

    /// Fundal / culoare pentru iconița categoriei.
    static func tint(_ group: String) -> (Color, Color) {
        switch group {
        case "Claude": (Theme.dyn(0xFCEEE7, 0x3D2A20), Theme.dyn(0xB4532A, 0xF0A07A))
        case "Simulatoare iOS", "iPhone / iPad", "Browsere", "Descărcări": (Theme.intBg, Theme.intFg)
        case "node_modules din proiecte", "Build-uri din proiecte", "Android": (Theme.safeBg, Theme.safeFg)
        case "Dezvoltare": (Theme.extBg, Theme.extFg)
        case "Aplicații de chat": (Theme.dyn(0xE4F6F5, 0x163533), Theme.dyn(0x0B6E69, 0x6FD6CF))
        default: (Theme.dyn(0xF0F1F3, 0x33353A), Theme.dyn(0x3D434B, 0xC5CAD0))
        }
    }
}

// MARK: - Fereastra principală

struct ContentView: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var left: LeftoversStore
    @StateObject private var exp = ExplorerStore()
    @StateObject private var big = ExplorerStore()
    @StateObject private var apps = AppsStore()
    @StateObject private var startup = StartupStore()
    @StateObject private var flow = CleanFlow()
    @State private var section: Section = Section(rawValue: ProcessInfo.processInfo.environment["CURATENIE_TAB"] ?? "") ?? .overview
    @State private var focusGroup: String?
    @State private var hasFDA = FullDiskAccess.granted()

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(section: $section, rec: rec, hasFDA: hasFDA)
                .frame(width: 264)
            Rectangle().fill(Theme.sidebarLine).frame(width: 1)
            VStack(spacing: 0) {
                if !hasFDA { FDABanner { hasFDA = FullDiskAccess.granted() } }
                ScreenHeader(title: section.title, subtitle: subtitle) { refreshButton }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
        }
        .foregroundStyle(Theme.text)
        .ignoresSafeArea(.container, edges: .top)
        .cleanFlow(flow, rec: rec)
        .onAppear {
            rec.scanIfNeeded()
            exp.open(Paths.realHome)
            apps.scan()
            left.scanIfNeeded()
            startup.scanIfNeeded()
            if let dir = ProcessInfo.processInfo.environment["CURATENIE_BIG"] {  // diagnostic
                big.path = dir
                big.findBigFiles()
            } else if section == .big {
                big.findBigFiles()
            }
        }
        .onChange(of: section) { _, s in
            if s == .big && big.mode != .bigFiles && !big.loading { big.findBigFiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFDA = FullDiskAccess.granted()
            rec.refreshDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCleanerSettings)) { _ in section = .settings }
    }

    private var subtitle: String {
        switch section {
        case .overview:
            return rec.lastScan.map { tr("Ultima scanare: \($0.formatted(date: .omitted, time: .shortened)) · \(rec.targets.count) elemente analizate") }
                ?? tr("Se scanează…")
        case .rec:
            if rec.scanning { return tr("Se scanează…") }
            return tr("\(Fmt.bytes(rec.reclaimable)) găsiți în \(rec.targets.count) elemente. Ce e marcat „Sigur” se reface singur.")
        case .big:
            return tr("Fișiere și pachete de peste 50 MB. Vezi exact unde se află, înainte să le muți la Coș.")
        case .exp:
            return tr("Navighează prin folderul tău, sortat după mărime.")
        case .apps:
            return tr("Pe discul intern: \(Fmt.bytes(apps.internalTotal)) (aplicații + datele lor din ~/Library)")
        case .left:
            return tr("Fișiere rămase de la aplicații dezinstalate.")
        case .start:
            return tr("Ce pornește odată cu Mac-ul.")
        case .settings:
            return tr("Limbă, pornire, scanare automată și permisiuni.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview:
            OverviewView(rec: rec, apps: apps, flow: flow) { target in
                switch target {
                case "apps": section = .apps
                case "big": section = .big
                default:
                    focusGroup = target
                    section = .rec
                }
            }
        case .rec: RecommendationsView(store: rec, flow: flow, focusGroup: $focusGroup)
        case .big: ExplorerView(store: big, onChange: { rec.refreshDisk() })
        case .exp: ExplorerView(store: exp, onChange: { rec.refreshDisk() })
        case .apps: AppsView(store: apps, onChange: { rec.refreshDisk() })
        case .left: LeftoversView(store: left, hasFDA: hasFDA, onChange: { rec.refreshDisk() })
        case .start: StartupView(store: startup)
        case .settings: SettingsPage()
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let label = Label(section == .exp || section == .start ? tr("Reîmprospătează") : tr("Scanează din nou"), systemImage: "arrow.clockwise")
        switch section {
        case .overview, .rec:
            Button { rec.scan() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34)).disabled(rec.scanning)
        case .apps:
            Button { apps.scan() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34)).disabled(apps.loading)
        case .left:
            Button { left.scan() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34)).disabled(left.scanning)
        case .start:
            Button { startup.scan() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34)).disabled(startup.loading)
        case .big:
            Button { big.findBigFiles() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34)).disabled(big.loading)
        case .exp:
            Button { exp.refresh() } label: { label }.buttonStyle(SecondaryButtonStyle(height: 34))
        case .settings:
            EmptyView()
        }
    }
}

struct AppSidebar: View {
    @Binding var section: Section
    @ObservedObject var rec: RecommendationsStore
    let hasFDA: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cleaner MacOS")
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 10).padding(.top, 50).padding(.bottom, 14)
            ForEach(Section.main, id: \.self) { s in
                let on = s == section
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.icon).font(.system(size: 14, weight: .medium)).frame(width: 18)
                        Text(s.title).font(.system(size: 13.5, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if s == .rec && rec.reclaimable > 0 {
                            Text(Fmt.bytes(rec.reclaimable))
                                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.safeBg))
                                .foregroundStyle(Theme.safeFg)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .foregroundStyle(on ? Theme.accentText : Theme.text)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.card)
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            Button { section = .settings } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape").font(.system(size: 14, weight: .medium)).frame(width: 18)
                    Text("Setări").font(.system(size: 13.5, weight: section == .settings ? .semibold : .medium))
                    Spacer()
                    Text("⌘,").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10).frame(height: 34)
                .foregroundStyle(section == .settings ? Theme.accentText : Theme.text)
                .background {
                    if section == .settings {
                        RoundedRectangle(cornerRadius: 8).fill(Theme.card)
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Macintosh HD").foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Fmt.bytes(rec.diskFree)) liber").fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 12))
                .lineLimit(1).minimumScaleFactor(0.8)
                DiskStrip(total: rec.diskTotal, used: max(0, rec.diskTotal - rec.diskFree), reclaimable: rec.reclaimable)
                    .frame(height: 6).clipShape(Capsule())
                if hasFDA {
                    Label("Acces complet la disc", systemImage: "checkmark")
                        .font(.system(size: 12)).foregroundStyle(Theme.safeFg)
                } else {
                    Button { FullDiskAccess.openSettings() } label: {
                        Label("Lipsește accesul la disc", systemImage: "exclamationmark.triangle")
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.careFg)
                }
            }
            .card(radius: 10, padding: 12)
        }
        .padding(.horizontal, 12).padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

/// Bara orizontală folosit / se poate elibera / liber.
struct DiskStrip: View {
    let total: Int64
    let used: Int64
    let reclaimable: Int64
    var body: some View {
        GeometryReader { g in
            let t = CGFloat(max(total, 1))
            let rec = CGFloat(min(reclaimable, used))
            HStack(spacing: 0) {
                Rectangle().fill(Theme.used).frame(width: g.size.width * (CGFloat(used) - rec) / t)
                Rectangle().fill(Theme.reclaim).frame(width: g.size.width * rec / t)
                Rectangle().fill(Theme.track)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Inel de stocare

struct StorageRing: View {
    let total: Int64
    let used: Int64
    let reclaimable: Int64
    var lineWidth: CGFloat = 18

    var body: some View {
        let t = Double(max(total, 1))
        let rec = Double(min(reclaimable, used))
        let kept = Double(used) - rec
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: kept / t)
                .stroke(Theme.used, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle().trim(from: kept / t, to: (kept + rec) / t)
                .stroke(Theme.reclaim, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Fmt.bytes(total - used)).font(.system(size: 24, weight: .heavy)).monospacedDigit()
                Text("liber din \(Fmt.bytes(total))").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .animation(.easeOut(duration: 0.4), value: reclaimable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Fmt.bytes(total - used)) liber din \(Fmt.bytes(total)); \(Fmt.bytes(reclaimable)) se pot elibera"))
    }
}

// MARK: - Prezentare

struct OverviewView: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var apps: AppsStore
    @ObservedObject var flow: CleanFlow
    var open: (String) -> Void

    var body: some View {
        let used = max(0, rec.diskTotal - rec.diskFree)
        let safeIDs = rec.safeIDs
        let safeBytes = safeIDs.reduce(Int64(0)) { $0 + (rec.sizes[$1] ?? 0) }
        let computing = rec.scanning || rec.pendingCount > 0
        let groups = rec.groups
        let maxGroup = Double(max(groups.map(\.total).max() ?? 1, 1))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 36) {
                    StorageRing(total: rec.diskTotal, used: used, reclaimable: rec.reclaimable)
                        .frame(width: 176, height: 176)
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("SE POT ELIBERA").font(.system(size: 12.5, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(Theme.accentText)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Fmt.bytes(rec.reclaimable)).font(.system(size: 46, weight: .heavy)).monospacedDigit()
                                if computing { ProgressView().controlSize(.small) }
                            }
                            Text("din care \(Fmt.bytes(safeBytes)) fără niciun risc").foregroundStyle(Theme.muted)
                        }
                        HStack(spacing: 18) {
                            legend(Theme.used, "Folosit", Fmt.bytes(max(0, used - min(rec.reclaimable, used))))
                            legend(Theme.reclaim, "Se poate elibera", Fmt.bytes(rec.reclaimable))
                            legend(Theme.track, "Liber", Fmt.bytes(rec.diskFree))
                        }
                        .font(.system(size: 13))
                        HStack(spacing: 10) {
                            Button { open("") } label: {
                                HStack(spacing: 8) { Text("Revizuiește și curăță"); Image(systemName: "arrow.right") }
                            }
                            .buttonStyle(PrimaryButtonStyle(height: 44))
                            Button("Curăță doar ce e sigur · \(Fmt.bytes(safeBytes))") { flow.start(ids: safeIDs) }
                                .buttonStyle(SecondaryButtonStyle(height: 44, tinted: true))
                                .disabled(safeIDs.isEmpty || flow.running)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .card(radius: 16, padding: 26)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(groups, id: \.name) { g in
                        Button { open(g.name) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    GroupIcon(group: g.name)
                                    Text(trKey(g.name)).fontWeight(.semibold).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Fmt.bytes(g.total)).fontWeight(.bold).monospacedDigit()
                                }
                                SizeBar(fraction: Double(g.total) / maxGroup)
                                Text("\(g.items.count) elemente").font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .card()
                    }
                }

                let topApps = Array(apps.apps.filter { $0.total != nil }.sorted { ($0.total ?? 0) > ($1.total ?? 0) }.prefix(4))
                if !topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Cele mai mari aplicații").font(.system(size: 14, weight: .bold))
                            Spacer()
                            Button("Vezi toate") { open("apps") }.buttonStyle(.plain)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                        }
                        .padding(.bottom, 6)
                        ForEach(topApps) { a in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 20, height: 20)
                                Text(a.name).fontWeight(.medium)
                                Spacer()
                                VolumePill(volume: a.volume)
                                Text(Fmt.bytes(a.total)).fontWeight(.semibold).monospacedDigit().frame(width: 80, alignment: .trailing)
                            }
                            .frame(height: 32)
                        }
                    }
                    .card(padding: 16)
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legend(_ c: Color, _ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(label).foregroundStyle(Theme.muted)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .fixedSize()
    }
}

struct GroupIcon: View {
    let group: String
    var size: CGFloat = 32
    var body: some View {
        let (bg, fg) = GroupInfo.tint(group)
        Image(systemName: GroupInfo.icon(group))
            .font(.system(size: size * 0.48, weight: .medium))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 4).fill(bg))
            .foregroundStyle(fg)
            .accessibilityHidden(true)
    }
}

struct VolumePill: View {
    let volume: VolumeInfo
    var long = false
    var body: some View {
        if volume.isInternal {
            Pill(text: long ? tr("Mac (disc intern)") : tr("Intern"), bg: Theme.intBg, fg: Theme.intFg, icon: "internaldrive")
        } else {
            Pill(text: long ? tr("\(volume.name) (extern)") : volume.name, bg: Theme.extBg, fg: Theme.extFg, icon: "externaldrive")
        }
    }
}

// MARK: - Recomandări

enum RiskFilter: Hashable { case all, safe, care }

struct RecommendationsView: View {
    @ObservedObject var store: RecommendationsStore
    @ObservedObject var flow: CleanFlow
    @Binding var focusGroup: String?
    @State private var group: String?
    @State private var filter: RiskFilter = .all

    private func visible(_ t: CleanTarget) -> Bool {
        switch filter {
        case .all: true
        case .safe: t.risk == .safe
        case .care: t.risk != .safe
        }
    }

    var body: some View {
        let groups = store.groups.compactMap { g -> (name: String, total: Int64, items: [CleanTarget])? in
            let items = g.items.filter(visible)
            guard !items.isEmpty else { return nil }
            return (g.name, items.reduce(0) { $0 + ($1.overlap ? 0 : (store.sizes[$1.id] ?? 0)) }, items)
        }
        let current = groups.first { $0.name == group } ?? groups.first
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    Text("Toate").tag(RiskFilter.all)
                    Text("Sigure").tag(RiskFilter.safe)
                    Text("Atenție").tag(RiskFilter.care)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            if groups.isEmpty {
                VStack(spacing: 10) {
                    if store.scanning || store.scanningNodeModules {
                        ProgressView()
                        Text("Caut ce se poate curăța…").foregroundStyle(Theme.muted)
                    } else {
                        Text("Nimic de curățat.").foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(groups, id: \.name) { g in groupRow(g, active: g.name == current?.name) }
                            if store.scanningNodeModules {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Caut node_modules și duplicate…")
                                }
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 8)
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 300)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    VStack(spacing: 0) {
                        if let current {
                            HStack(alignment: .firstTextBaseline) {
                                Text(trKey(current.name)).font(.system(size: 18, weight: .bold))
                                Spacer()
                                Text("\(current.items.count) elemente · ").foregroundStyle(Theme.muted)
                                    + Text(Fmt.bytes(current.total)).fontWeight(.bold)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
                            Rectangle().fill(Theme.lineSoft).frame(height: 1)
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(current.items) { t in
                                        itemRow(t)
                                        Rectangle().fill(Theme.lineSoft).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.card)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .onAppear {
            if let f = focusGroup, !f.isEmpty { group = f }
            focusGroup = nil
            if group == nil { group = groups.first?.name }
        }
    }

    private func groupRow(_ g: (name: String, total: Int64, items: [CleanTarget]), active: Bool) -> some View {
        let ids = g.items.filter { (store.sizes[$0.id] ?? 0) > 0 && !store.done.contains($0.id) }.map(\.id)
        let on = ids.filter { store.selected.contains($0) }.count
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !ids.isEmpty && on == ids.count },
                set: { v in if v { store.selected.formUnion(ids) } else { store.selected.subtract(ids) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(ids.isEmpty)
                .accessibilityLabel(Text("Selectează tot din \(trKey(g.name))"))
            Button { group = g.name } label: {
                HStack(spacing: 10) {
                    GroupIcon(group: g.name, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(trKey(g.name)).fontWeight(.semibold).lineLimit(1)
                        Text("\(on) din \(ids.count) selectate").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    Text(Fmt.bytes(g.total)).fontWeight(.bold).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 54)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 10).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ t: CleanTarget) -> some View {
        let size = store.sizes[t.id]
        let isDone = store.done.contains(t.id)
        HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: Binding(
                get: { store.selected.contains(t.id) },
                set: { v in if v { store.selected.insert(t.id) } else { store.selected.remove(t.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(isDone || (size ?? 0) == 0)
                .accessibilityLabel(Text(t.name))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(t.name).fontWeight(.semibold)
                    RiskMark(risk: t.risk)
                    if isDone { Pill(text: tr("Gata"), bg: Theme.safeBg, fg: Theme.safeFg, icon: "checkmark") }
                }
                Text(t.desc).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let app = t.appName, !t.procs.isEmpty {
                    Label("Se închide automat: \(app)", systemImage: "power")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                if let size {
                    Text(Fmt.bytes(size)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                SizeBar(fraction: (Double(size ?? 0) / Double(store.maxSize)).squareRoot(),
                        color: t.risk == .safe ? Theme.reclaim : Theme.care, width: 120)
            }
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .opacity(isDone ? 0.55 : 1)
    }

    private var footer: some View {
        let sel = store.selectedTargets
        let bytes = sel.reduce(Int64(0)) { $0 + (store.sizes[$1.id] ?? 0) }
        let care = sel.filter { $0.risk != .safe }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Selectat: \(Fmt.bytes(bytes))").fontWeight(.bold).monospacedDigit()
                Text(care > 0 ? tr("\(sel.count) elemente, din care \(care) marcate „Atenție”") : tr("\(sel.count) elemente, toate sigure"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Doar cele sigure") { store.selected = Set(store.safeIDs) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Deselectează") { store.selected = [] }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(sel.isEmpty)
            Button("Curăță \(Fmt.bytes(bytes))") { flow.start(ids: sel.map(\.id)) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sel.isEmpty || flow.running)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24).frame(height: 68)
        .background(Theme.card)
    }
}

/// Eticheta de risc, ca în design: „Sigur” verde, „Atenție” chihlimbar.
struct RiskMark: View {
    let risk: Risk
    var body: some View {
        switch risk {
        case .safe: Pill(text: tr("Sigur"), bg: Theme.safeBg, fg: Theme.safeFg)
        case .care: Pill(text: tr("Atenție"), bg: Theme.careBg, fg: Theme.careFg)
        case .suspect: Pill(text: tr("Suspect"), bg: Theme.extBg, fg: Theme.extFg)
        }
    }
}

// MARK: - Curățare în bloc

/// Confirmare → închiderea aplicațiilor → curățare secvențială → rezultat. Folosit din Prezentare și Recomandări.
@MainActor
final class CleanFlow: ObservableObject {
    struct Plan: Identifiable {
        let id = UUID()
        let targets: [CleanTarget]
        let bytes: Int64
        let careCount: Int
        let apps: [NSRunningApplication]
        /// Procese fără interfață (sesiuni CLI, Gradle, emulator): țintele lor se sar.
        let skipped: [CleanTarget]
    }

    @Published var plan: Plan?
    @Published var forcePlan: Plan?
    @Published var message: (title: String, body: String)?
    @Published var running = false
    weak var rec: RecommendationsStore?

    func start(ids: [String]) {
        guard let rec, !running else { return }
        let set = Set(ids)
        let targets = rec.targets.filter { set.contains($0.id) && (rec.sizes[$0.id] ?? 0) > 0 && !rec.done.contains($0.id) }
        guard !targets.isEmpty else { return }
        running = true
        Task {
            var apps: [NSRunningApplication] = []
            var skipped: [CleanTarget] = []
            for t in targets where !t.procs.isEmpty {
                let procs = t.procs
                guard await offMain({ Procs.running(procs) }) else { continue }
                let gui = AppQuitter.matching(procs: procs)
                if gui.isEmpty { skipped.append(t) }
                for a in gui where !apps.contains(where: { $0.processIdentifier == a.processIdentifier }) { apps.append(a) }
            }
            let skippedIDs = Set(skipped.map(\.id))
            let run = targets.filter { !skippedIDs.contains($0.id) }
            running = false
            plan = Plan(targets: run,
                        bytes: run.reduce(0) { $0 + (rec.sizes[$1.id] ?? 0) },
                        careCount: run.filter { $0.risk != .safe }.count,
                        apps: apps, skipped: skipped)
        }
    }

    func confirm(_ p: Plan, force: Bool = false) {
        plan = nil
        forcePlan = nil
        guard let rec else { return }
        running = true
        Task {
            if !p.apps.isEmpty, !(await AppQuitter.quit(p.apps, force: force)) {
                running = false
                forcePlan = p
                return
            }
            var freed: Int64 = 0
            var errors: [String] = []
            var trashed = false
            for t in p.targets {
                switch await rec.clean(t) {
                case .success(let r):
                    freed += r.freed
                    errors += r.errors
                    trashed = trashed || t.trash
                case .failure(let e):
                    errors.append("\(t.name): \(e.message)")
                }
            }
            for t in p.skipped { errors.append(tr("Sărit, rulează încă: \(t.appName ?? t.name)")) }
            running = false
            let note = trashed ? "\n" + tr("Fișierele mutate la Coș eliberează spațiu după golirea Coșului.") : ""
            if errors.isEmpty {
                message = (tr("Gata"), tr("Am eliberat \(Fmt.bytes(freed)).") + note)
            } else {
                message = (tr("Curățat parțial"),
                           tr("Am eliberat \(Fmt.bytes(freed)).") + note + "\n\n" + errors.prefix(12).joined(separator: "\n"))
            }
        }
    }
}

extension View {
    func cleanFlow(_ flow: CleanFlow, rec: RecommendationsStore) -> some View {
        modifier(CleanFlowModifier(flow: flow, rec: rec))
    }
}

private struct CleanFlowModifier: ViewModifier {
    @ObservedObject var flow: CleanFlow
    let rec: RecommendationsStore

    func body(content: Content) -> some View {
        content
            .onAppear { flow.rec = rec }
            .sheet(item: $flow.plan) { p in CleanConfirmSheet(plan: p, flow: flow) }
            .alert(Text("Unele aplicații nu s-au închis"),
                   isPresented: Binding(get: { flow.forcePlan != nil }, set: { if !$0 { flow.forcePlan = nil } }),
                   presenting: flow.forcePlan) { p in
                Button("Forțează închiderea", role: .destructive) { flow.confirm(p, force: true) }
                Button("Anulează", role: .cancel) { flow.forcePlan = nil }
            } message: { _ in
                Text("Probabil așteaptă un răspuns (ex. salvarea unui document). Verifică fereastra lor sau forțează închiderea; modificările nesalvate se pierd.")
            }
            .alert(flow.message?.title ?? "",
                   isPresented: Binding(get: { flow.message != nil }, set: { if !$0 { flow.message = nil } })) {
                Button("OK") { flow.message = nil }
            } message: { Text(flow.message?.body ?? "") }
            .overlay {
                if flow.running {
                    ProgressView().controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
    }
}

struct CleanConfirmSheet: View {
    let plan: CleanFlow.Plan
    @ObservedObject var flow: CleanFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Curăță \(Fmt.bytes(plan.bytes))?").font(.title2.weight(.semibold))
            Text(plan.careCount > 0
                 ? tr("\(plan.targets.count) elemente, din care \(plan.careCount) marcate „Atenție”. Ce se șterge definitiv nu mai poate fi recuperat.")
                 : tr("\(plan.targets.count) elemente, toate sigure: se refac singure la nevoie."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.targets) { t in
                        HStack {
                            Text(t.name).lineLimit(1)
                            RiskMark(risk: t.risk)
                            Spacer()
                            Text(Fmt.bytes(flow.rec?.sizes[t.id])).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 180)
            if !plan.apps.isEmpty {
                Label {
                    Text("Se închid: \(plan.apps.compactMap(\.localizedName).joined(separator: ", ")). Dacă vreuna nu se închide în 10 secunde, te întreb dacă o forțez.")
                } icon: { Image(systemName: "power") }
                .font(.callout)
            }
            if !plan.skipped.isEmpty {
                Label {
                    Text("Se sar (rulează și nu se pot închide de aici): \(plan.skipped.map { $0.appName ?? $0.name }.joined(separator: ", ")).")
                } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Anulează", role: .cancel) { flow.plan = nil }.keyboardShortcut(.cancelAction)
                Button(plan.apps.isEmpty ? tr("Curăță") : tr("Închide aplicațiile și curăță")) { flow.confirm(plan) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.targets.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

// MARK: - Setări (limbă)

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ro, en
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Limba sistemului"
        case .ro: "Română"
        case .en: "English"
        }
    }

    /// Prima pornire: româna e limba implicită (engleza se alege din Setări), indiferent de limba sistemului.
    static func applyDefaultOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "languageInitialized") else { return }
        if d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] == nil {
            d.set(["ro"], forKey: "AppleLanguages")
        }
        d.set(true, forKey: "languageInitialized")
    }

    static var current: AppLanguage {
        guard let langs = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = langs.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("ro") ? .ro : .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Limba se schimbă doar la repornire: pornește o copie nouă după ce aceasta se închide.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        AppDelegate.quitting = true
        NSApp.terminate(nil)
    }
}

enum Prefs {
    /// La câte ore se rescanează în fundal (0 = niciodată).
    static let rescanHoursKey = "rescanHours"
    /// Sub câți GB liberi vine notificarea (0 = fără notificare).
    static let lowSpaceGBKey = "lowSpaceGB"

    static var rescanHours: Int { UserDefaults.standard.object(forKey: rescanHoursKey) as? Int ?? 6 }
    static var lowSpaceGB: Int { UserDefaults.standard.object(forKey: lowSpaceGBKey) as? Int ?? 10 }
}

extension Notification.Name {
    static let openCleanerSettings = Notification.Name("openCleanerSettings")
}

/// Setările sunt o pagină a ferestrei principale (⌘, sau din bara de meniu o deschid acolo).
struct OpenSettingsButton<Label: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder var label: Label
    var body: some View {
        Button {
            AppDelegate.showInDock()
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openCleanerSettings, object: nil)
            }
        } label: { label }
    }
}

struct SettingsPage: View {
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var atLogin = LoginItem.enabled
    @State private var hasFDA = FullDiskAccess.granted()
    @AppStorage(Prefs.rescanHoursKey) private var rescanHours = 6
    @AppStorage(Prefs.lowSpaceGBKey) private var lowSpaceGB = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                group("GENERAL") {
                    row("Limbă", Text("Interfața aplicației.")) {
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .onChange(of: language) { _, l in
                            l.apply()
                            languageChanged = true
                        }
                    }
                    if languageChanged {
                        divider
                        HStack {
                            Label("Limba se schimbă după repornire.", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("Repornește acum") { AppLanguage.relaunch() }
                                .buttonStyle(PrimaryButtonStyle(height: 32))
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                    divider
                    row("Pornește la deschiderea Mac-ului", Text("Iconița din bara de meniu urmărește spațiul liber.")) {
                        Toggle("", isOn: Binding(get: { atLogin }, set: { on in
                            LoginItem.set(on)
                            atLogin = LoginItem.enabled
                        }))
                        .toggleStyle(.switch).labelsHidden().tint(Theme.accentFill)
                    }
                }
                group("SCANARE ȘI NOTIFICĂRI") {
                    row("Rescanează automat", Text("Rulează în fundal cât timp iconița e în bara de meniu.")) {
                        Picker("", selection: $rescanHours) {
                            Text("Niciodată").tag(0)
                            Text("La 6 ore").tag(6)
                            Text("Zilnic").tag(24)
                            Text("Săptămânal").tag(168)
                        }
                        .labelsHidden().fixedSize()
                    }
                    divider
                    row("Avertizează când spațiul liber scade sub", Text("Notificare macOS, o dată la fiecare coborâre sub prag.")) {
                        Picker("", selection: $lowSpaceGB) {
                            Text("Niciodată").tag(0)
                            Text("5 GB").tag(5)
                            Text("10 GB").tag(10)
                            Text("20 GB").tag(20)
                            Text("50 GB").tag(50)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                group("PERMISIUNI") {
                    row("Acces complet la disc",
                        Text(hasFDA ? tr("Activ: aplicația vede și cache-urile protejate (WhatsApp, Coș, Containers).")
                            : tr("Lipsește: unele foldere nu se pot scana sau curăța."))) {
                        HStack(spacing: 10) {
                            Pill(text: hasFDA ? tr("Activ") : tr("Lipsește"),
                                 bg: hasFDA ? Theme.safeBg : Theme.careBg, fg: hasFDA ? Theme.safeFg : Theme.careFg,
                                 icon: hasFDA ? "checkmark" : "exclamationmark.triangle.fill")
                            Button("Deschide setarea") { FullDiskAccess.openSettings() }
                                .buttonStyle(SecondaryButtonStyle(height: 32))
                        }
                    }
                }
                group("DESPRE") {
                    row("Cleaner MacOS", Text(tr("Versiunea \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"))) {
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFDA = FullDiskAccess.granted()
            atLogin = LoginItem.enabled
        }
    }

    private var divider: some View { Rectangle().fill(Theme.lineSoft).frame(height: 1) }

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.muted)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }.card()
        }
    }

    private func row<Control: View>(_ title: LocalizedStringKey, _ detail: Text, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                detail.font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}
