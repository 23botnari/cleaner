import SwiftUI
import AppKit

/// Text tradus pentru valori `String` (nume, descrieri, mesaje). `Text("literal")` se traduce singur;
/// `Text(variabilăString)` nu, așa că șirurile construite în cod trec prin aici.
func tr(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// Cheie dinamică (ex. numele grupului, păstrat în română ca identificator stabil).
func trKey(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

// MARK: - Secțiuni

enum Section: String, Hashable, CaseIterable {
    case overview, rec, dev, memory, big, exp, apps, left, start, history, settings

    /// Ce apare în lista principală din bara laterală (Setări are butonul ei, jos).
    static let main: [Section] = [.overview, .rec, .dev, .memory, .big, .exp, .apps, .left, .start, .history]

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Prezentare"
        case .rec: "Recomandări"
        case .dev: "Dezvoltator"
        case .memory: "Memorie și procese"
        case .big: "Fișiere mari"
        case .exp: "Explorator"
        case .apps: "Aplicații"
        case .left: "Resturi"
        case .start: "Pornire automată"
        case .history: "Istoric"
        case .settings: "Setări"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .rec: "checklist"
        case .dev: "hammer"
        case .memory: "memorychip"
        case .big: "doc.text.magnifyingglass"
        case .exp: "folder"
        case .apps: "square.grid.2x2"
        case .left: "shippingbox"
        case .start: "power"
        case .history: "clock.arrow.circlepath"
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
        case "Versiuni de unelte": "square.stack.3d.up"
        default: "folder"
        }
    }

    /// Fundal / culoare pentru iconița categoriei.
    static func tint(_ group: String) -> (Color, Color) {
        switch group {
        case "Claude": (Theme.dyn(0xFCEEE7, 0x3D2A20), Theme.dyn(0xB4532A, 0xF0A07A))
        case "Simulatoare iOS", "iPhone / iPad", "Browsere", "Descărcări": (Theme.intBg, Theme.intFg)
        case "node_modules din proiecte", "Build-uri din proiecte", "Android": (Theme.safeBg, Theme.safeFg)
        case "Dezvoltare", "Versiuni de unelte": (Theme.extBg, Theme.extFg)
        case "Aplicații de chat": (Theme.dyn(0xE4F6F5, 0x163533), Theme.dyn(0x0B6E69, 0x6FD6CF))
        default: (Theme.dyn(0xF0F1F3, 0x33353A), Theme.dyn(0x3D434B, 0xC5CAD0))
        }
    }
}

// MARK: - Fereastra principală

struct ContentView: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var left: LeftoversStore
    @ObservedObject var update: UpdateStore
    @StateObject private var exp = ExplorerStore()
    @StateObject private var big = ExplorerStore()
    @State private var askDevMode = false
    @StateObject private var apps = AppsStore()
    @StateObject private var startup = StartupStore()
    @StateObject private var flow = CleanFlow()
    @State private var section: Section = Section(rawValue: ProcessInfo.processInfo.environment["CLEANER_TAB"] ?? "") ?? .overview
    @State private var focusGroup: String?
    @State private var hasFDA = FullDiskAccess.granted()
    @State private var expLoaded = false

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(section: $section, rec: rec, update: update, hasFDA: hasFDA)
                .frame(width: 284)
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
        .overlay { DialogHost() }
        .onAppear {
            // Doar ce se vede din prima; restul secțiunilor se încarcă la prima deschidere.
            rec.scanIfNeeded()
            apps.scan()
            left.scanIfNeeded()
            if let dir = ProcessInfo.processInfo.environment["CLEANER_BIG"] {  // diagnostic
                big.path = dir
                big.findBigFiles()
            }
            load(section)
            if !Profile.asked { askDevMode = true }
        }
        .appSheet(isPresented: $askDevMode) { DevModeQuestion { askDevMode = false } }
        .onChange(of: section) { _, s in load(s) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFDA = FullDiskAccess.granted()
            rec.refreshDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCleanerSettings)) { _ in section = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .openCleanerSection)) { n in
            if let s = (n.object as? String).flatMap(Section.init(rawValue:)) { section = s }
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileChanged)) { _ in
            if section == .dev && !Profile.devMode { section = .rec }
            rec.scan()
        }
    }

    /// Încărcare la prima deschidere a secțiunii.
    private func load(_ s: Section) {
        switch s {
        case .big:
            if big.mode != .bigFiles && !big.loading { big.findBigFiles() }
        case .exp:
            if !expLoaded {
                expLoaded = true
                exp.open(Paths.realHome)
            }
        case .start:
            startup.scanIfNeeded()
        default:
            break
        }
    }

    private var subtitle: String {
        switch section {
        case .overview:
            return rec.lastScan.map { tr("Ultima scanare: \($0.formatted(date: .omitted, time: .shortened)) · \(rec.targets.count) elemente analizate") }
                ?? tr("Se scanează…")
        case .rec:
            if rec.scanning { return tr("Se scanează…") }
            let n = rec.targets.filter { !$0.isDev }.count
            return tr("\(Fmt.bytes(rec.reclaimable(dev: false))) găsiți în \(n) elemente. Ce e marcat „Sigur” se reface singur.")
        case .dev:
            if rec.scanning { return tr("Se scanează…") }
            let n = rec.targets.filter(\.isDev).count
            return tr("\(Fmt.bytes(rec.reclaimable(dev: true))) în \(n) elemente de dezvoltare: cache-uri, build-uri și dependențe care se refac.")
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
        case .history:
            return tr("Ce ai curățat din aplicație și cât spațiu ai eliberat.")
        case .memory:
            return tr("Cât RAM și procesor folosesc aplicațiile, actualizat la 2 secunde.")
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
                case "dev": section = .dev
                default:
                    focusGroup = target
                    section = rec.targets.contains { $0.group == target && $0.isDev } ? .dev : .rec
                }
            }
        case .rec: RecommendationsView(store: rec, flow: flow, focusGroup: $focusGroup, dev: false)
        case .dev: RecommendationsView(store: rec, flow: flow, focusGroup: $focusGroup, dev: true)
        case .big: ExplorerView(store: big, onChange: { rec.refreshDisk() })
        case .exp: ExplorerView(store: exp, onChange: { rec.refreshDisk() })
        case .apps: AppsView(store: apps, onChange: { rec.refreshDisk() })
        case .left: LeftoversView(store: left, hasFDA: hasFDA, onChange: { rec.refreshDisk() })
        case .start: StartupView(store: startup)
        case .history: HistoryView()
        case .memory: MemoryView()
        case .settings: SettingsPage(update: update)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let label = Label(section == .exp || section == .start ? tr("Reîmprospătează") : tr("Scanează din nou"), systemImage: "arrow.clockwise")
        switch section {
        case .overview, .rec, .dev:
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
        case .settings, .history, .memory:
            EmptyView()
        }
    }
}

struct AppSidebar: View {
    @Binding var section: Section
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var update: UpdateStore
    let hasFDA: Bool
    @AppStorage(Profile.devModeKey) private var devMode = false
    static let devTint = Theme.dyn(0xB45309, 0xF5A524)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Iconul are margine transparentă (grila macOS), de aici dimensiunea mai mare și padding-ul negativ.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .padding(.leading, -3)
                Text("Cleaner")
                    .font(.system(size: 15, weight: .bold))
            }
            .contentShape(Rectangle())
            .onTapGesture { section = .overview }
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 10).padding(.top, 46).padding(.bottom, 10)
            ForEach(Section.main.filter { $0 != .dev || devMode }, id: \.self) { s in
                let on = s == section
                let badge = s == .rec ? rec.reclaimable(dev: false) : s == .dev ? rec.reclaimable(dev: true) : 0
                // Recomandări verde, Dezvoltator chihlimbar: fundal ușor colorat când sunt deschise.
                let tint: Color? = s == .rec ? Theme.reclaim : s == .dev ? Self.devTint : nil
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.icon).font(.system(size: 14, weight: .medium)).frame(width: 18)
                        Text(s.title).font(.system(size: 13.5, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        if badge > 0 {
                            Text(Fmt.bytes(badge))
                                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(Capsule().fill(s == .dev ? Self.devTint.opacity(0.2) : Theme.safeBg))
                                .foregroundStyle(s == .dev ? Self.devTint : Theme.safeFg)
                        }
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .foregroundStyle(on ? (s == .dev ? Self.devTint : Theme.accentText) : Theme.text)
                    .background {
                        if on {
                            if let tint {
                                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.14))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.22)))
                            } else {
                                RoundedRectangle(cornerRadius: 8).fill(Theme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            if let r = update.release {
                Button { section = .settings } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .medium)).frame(width: 18)
                        Text("Versiunea \(r.version) e disponibilă").font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.safeBg))
                    .foregroundStyle(Theme.safeFg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }
            Button { NSWorkspace.shared.open(UpdateStore.repoURL) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "star").font(.system(size: 13, weight: .medium)).frame(width: 18)
                    Text("Dă-ne o stea pe GitHub").font(.system(size: 12.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(UpdateStore.repoURL.absoluteString)
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
    @State private var contentWidth: CGFloat = 900

    /// Coloane echilibrate: cât mai puține rânduri, apoi carduri împărțite egal (4 → 2+2 sau 4, niciodată 3+1).
    private func gridColumns(_ n: Int) -> [GridItem] {
        let fit = max(1, Int((contentWidth + 12) / (260 + 12)))
        let rows = max(1, Int(ceil(Double(max(n, 1)) / Double(fit))))
        let cols = max(1, Int(ceil(Double(max(n, 1)) / Double(rows))))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: cols)
    }

    var body: some View {
        let used = max(0, rec.diskTotal - rec.diskFree)
        // Prezentarea arată doar curățarea generală; ce ține de dezvoltare stă în secțiunea Dezvoltator.
        let reclaimable = rec.reclaimable(dev: false)
        let devBytes = rec.reclaimable(dev: true)
        let safeIDs = rec.safeIDs(dev: false)
        let safeBytes = safeIDs.reduce(Int64(0)) { $0 + (rec.sizes[$1] ?? 0) }
        let computing = rec.scanning || rec.pendingCount > 0
        let groups = rec.groups.compactMap { g -> (name: String, total: Int64, items: [CleanTarget])? in
            let items = g.items.filter { !$0.isDev }
            guard !items.isEmpty else { return nil }
            return (g.name, items.reduce(0) { $0 + ($1.overlap ? 0 : (rec.sizes[$1.id] ?? 0)) }, items)
        }
        let maxGroup = Double(max(groups.map(\.total).max() ?? 1, 1))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 36) {
                    StorageRing(total: rec.diskTotal, used: used, reclaimable: reclaimable)
                        .frame(width: 176, height: 176)
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("SE POT ELIBERA").font(.system(size: 12.5, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(Theme.accentText)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Fmt.bytes(reclaimable)).font(.system(size: 46, weight: .heavy)).monospacedDigit()
                                if computing { ProgressView().controlSize(.small) }
                            }
                            Text("din care \(Fmt.bytes(safeBytes)) fără niciun risc").foregroundStyle(Theme.muted)
                            if devBytes > 0 {
                                Button { open("dev") } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "hammer")
                                        Text("încă \(Fmt.bytes(devBytes)) în Dezvoltator")
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    }
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentText)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).padding(.top, 6)
                            }
                        }
                        HStack(spacing: 18) {
                            legend(Theme.used, "Folosit", Fmt.bytes(max(0, used - min(reclaimable, used))))
                            legend(Theme.reclaim, "Se poate elibera", Fmt.bytes(reclaimable))
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

                LazyVGrid(columns: gridColumns(groups.isEmpty ? 4 : groups.count), spacing: 12) {
                    if groups.isEmpty && rec.scanning {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    SkeletonBlock(width: 32, height: 32, radius: 8)
                                    SkeletonBlock(width: 90)
                                    Spacer()
                                    SkeletonBlock(width: 56)
                                }
                                SkeletonBlock(height: 6, radius: 3)
                                SkeletonBlock(width: 70, height: 10)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .card()
                        }
                    }
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

                // Doar discul intern: aplicațiile de pe discuri externe nu ocupă loc pe Mac.
                let topApps = Array(apps.apps.filter { $0.total != nil && $0.volume.isInternal }.sorted { ($0.total ?? 0) > ($1.total ?? 0) }.prefix(4))
                if topApps.isEmpty && apps.loading {
                    SkeletonRows(count: 4, icon: 20).frame(height: 4 * 58 + 2)
                }
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            .padding(.horizontal, 28).padding(.bottom, 28)
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
    /// true = secțiunea Dezvoltator (doar ținte cu `tech`); false = Recomandări (restul).
    let dev: Bool
    @State private var group: String?
    @State private var filter: RiskFilter = .all
    @State private var techFilter: Tech?
    @AppStorage("devViewByProject") private var byProject = false

    private func visible(_ t: CleanTarget) -> Bool {
        guard t.isDev == dev else { return false }
        if dev, let techFilter, t.tech != techFilter { return false }
        switch filter {
        case .all: return true
        case .safe: return t.risk == .safe
        case .care: return t.risk != .safe
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
                if dev { techMenu }
                Spacer()
                if dev {
                    Picker("", selection: $byProject) {
                        Text("Categorii").tag(false)
                        Text("Proiecte").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            if dev && byProject && !groups.isEmpty {
                ProjectsList(store: store, flow: flow, items: groups.flatMap(\.items))
            } else if groups.isEmpty {
                if store.scanning || store.scanningNodeModules {
                    SkeletonRows(label: tr("Caut ce se poate curăța…")).padding(.horizontal, 28).padding(.top, 16)
                } else {
                    Text("Nimic de curățat.").foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

    /// Ecosistemele găsite pe Mac, cu mărimea lor: filtrează lista; „Ascunde” le scoate din scanare.
    private var techMenu: some View {
        let devTargets = store.targets.filter { $0.isDev && !store.done.contains($0.id) }
        var sizes: [Tech: Int64] = [:]
        for t in devTargets where !t.overlap { if let k = t.tech { sizes[k, default: 0] += store.sizes[t.id] ?? 0 } }
        let present = Set(devTargets.compactMap(\.tech))
        let techs = Tech.allCases.filter(present.contains).sorted { (sizes[$0] ?? 0) > (sizes[$1] ?? 0) }
        return Menu {
            Button { techFilter = nil; group = nil } label: { Label("Toate tehnologiile", systemImage: "square.grid.2x2") }
            Divider()
            ForEach(techs) { t in
                Button { techFilter = t; group = nil } label: {
                    Label("\(t.title) · \(Fmt.bytes(sizes[t] ?? 0))", systemImage: techFilter == t ? "checkmark" : t.icon)
                }
            }
            if let t = techFilter {
                Divider()
                Button(role: .destructive) { hide(t) } label: { Label("Ascunde \(t.title)", systemImage: "eye.slash") }
                    .help(tr("Nu se mai caută și nu mai apare aici. Îl poți readuce din Setări."))
            }
        } label: {
            Label(techFilter?.title ?? tr("Toate tehnologiile"), systemImage: techFilter?.icon ?? "square.grid.2x2")
        }
        .fixedSize()
        .padding(.leading, 8)
        .onChange(of: present) { _, p in if let t = techFilter, !p.contains(t), !store.scanning { techFilter = nil } }
    }

    private func hide(_ t: Tech) {
        if techFilter == t { techFilter = nil }
        Profile.setHidden(t, true)
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
        .togglesCheckbox(enabled: !isDone && (size ?? 0) > 0) {
            if store.selected.contains(t.id) { store.selected.remove(t.id) } else { store.selected.insert(t.id) }
        }
        .opacity(isDone ? 0.55 : 1)
    }

    private var footer: some View {
        // Doar lista afișată: selecția din cealaltă secțiune rămâne neatinsă.
        let sel = store.selectedTargets(dev: dev)
        let scope = Set(store.targets.filter { $0.isDev == dev }.map(\.id))
        let bytes = sel.reduce(Int64(0)) { $0 + (store.sizes[$1.id] ?? 0) }
        let care = sel.filter { $0.risk != .safe }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Selectat: \(Fmt.bytes(bytes))").fontWeight(.bold).monospacedDigit()
                Text(care > 0 ? tr("\(sel.count) elemente, din care \(care) marcate „Atenție”") : tr("\(sel.count) elemente, toate sigure"))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Doar cele sigure") { store.selected = store.selected.subtracting(scope).union(store.safeIDs(dev: dev)) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Deselectează") { store.selected.subtract(scope) }
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

/// Țintele din Dezvoltator grupate pe proiect (node_modules, build-uri, cache-uri ale aceluiași folder).
struct ProjectsList: View {
    @ObservedObject var store: RecommendationsStore
    @ObservedObject var flow: CleanFlow
    let items: [CleanTarget]
    static let staleDays: Double = 90

    private struct Project: Identifiable {
        let id: String
        let last: Date
        let items: [CleanTarget]
        let total: Int64
    }

    private func makeProjects() -> [Project] {
        var byPath: [String: [CleanTarget]] = [:]
        for t in items { if let p = t.project { byPath[p, default: []].append(t) } }
        var list: [Project] = []
        for (path, its) in byPath {
            let total: Int64 = its.reduce(Int64(0)) { acc, t in acc + (store.sizes[t.id] ?? 0) }
            let pending = its.contains { t in store.sizes[t.id] == nil }
            guard total > 0 || pending else { continue }
            let last: Date = its.compactMap(\.lastActive).max() ?? .distantPast
            list.append(Project(id: path, last: last, items: its, total: total))
        }
        return list.sorted { a, b in a.total != b.total ? a.total > b.total : a.id < b.id }
    }

    var body: some View {
        let projects = makeProjects()
        let cutoff = Date().addingTimeInterval(-Self.staleDays * 24 * 3600)
        // Doar ce e „Sigur”: artefactele marcate „Atenție” (medii virtuale, vendor…) nu intră în curățarea rapidă.
        let stale = projects.filter { $0.last < cutoff }.flatMap(\.items)
            .filter { $0.risk == .safe && (store.sizes[$0.id] ?? 0) > 0 && !store.done.contains($0.id) }
        let staleBytes = stale.reduce(Int64(0)) { $0 + (store.sizes[$1.id] ?? 0) }
        let loose = items.count - projects.reduce(0) { $0 + $1.items.count }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(projects.count) proiecte").fontWeight(.bold)
                    Text(loose > 0 ? tr("Cache-urile globale (\(loose)) sunt în vederea pe categorii.") : tr("Doar folderele care se pot reface."))
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    flow.start(ids: stale.map(\.id))
                } label: {
                    Label(tr("Curăță proiectele inactive de 90+ zile · \(Fmt.bytes(staleBytes))"), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle(height: 32))
                .disabled(stale.isEmpty || flow.running)
                .help(tr("Doar elementele „Sigur” din proiectele neatinse de cel puțin 90 de zile."))
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            if projects.isEmpty {
                Text(store.scanningNodeModules ? tr("Caut proiectele…") : tr("Niciun proiect cu foldere de curățat."))
                    .foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projects) { p in
                            row(p)
                            Rectangle().fill(Theme.lineSoft).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
    }

    private func location(_ path: String) -> String {
        Paths.underHome(path) ? "~/" + Paths.relative(path, to: Paths.home) : path
    }

    private func artifactChip(_ t: CleanTarget) -> some View {
        let size: Int64 = store.sizes[t.id] ?? 0
        let label: String = (t.artifact ?? t.name) + " · " + Fmt.bytes(size)
        let border: Color = t.risk == .safe ? Theme.line : Theme.care.opacity(0.6)
        return Text(label)
            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.ground))
            .overlay(Capsule().strokeBorder(border))
            .opacity(store.done.contains(t.id) ? 0.5 : 1)
            .help(t.desc)
    }

    private func row(_ p: Project) -> some View {
        let ids = p.items.filter { (store.sizes[$0.id] ?? 0) > 0 && !store.done.contains($0.id) }.map(\.id)
        let on = ids.filter { store.selected.contains($0) }.count
        let days = Int(Date().timeIntervalSince(p.last) / (24 * 3600))
        let stale = Double(days) >= Self.staleDays
        return HStack(alignment: .top, spacing: 14) {
            Toggle("", isOn: Binding(
                get: { !ids.isEmpty && on == ids.count },
                set: { v in if v { store.selected.formUnion(ids) } else { store.selected.subtract(ids) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(ids.isEmpty)
                .accessibilityLabel(Text((p.id as NSString).lastPathComponent))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text((p.id as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    if p.items.contains(where: \.external) {
                        Pill(text: tr("Extern"), bg: Theme.extBg, fg: Theme.extFg, icon: "externaldrive")
                    }
                    if stale { Pill(text: tr("Inactiv"), bg: Theme.safeBg, fg: Theme.safeFg, icon: "moon.zzz") }
                }
                Text(location(p.id)).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    .help(p.id)
                HStack(spacing: 6) {
                    ForEach(p.items) { t in artifactChip(t) }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.bytes(p.total)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                Text(p.last == .distantPast ? "—" : days == 0 ? tr("activ azi") : tr("activ acum \(days) zile"))
                    .font(.system(size: 12)).foregroundStyle(stale ? Theme.safeFg : Theme.muted)
            }
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .togglesCheckbox(enabled: !ids.isEmpty) {
            if on == ids.count { store.selected.subtract(ids) } else { store.selected.formUnion(ids) }
        }
    }
}

/// Întrebarea de la prima pornire.
struct DevModeQuestion: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "hammer")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.extBg))
                .foregroundStyle(Theme.extFg)
                .accessibilityHidden(true)
            Text("Ești dezvoltator?").font(.system(size: 19, weight: .bold))
            Text("Dacă da, apare secțiunea Dezvoltator: cache-uri de pachete, build-uri din proiecte, simulatoare și versiuni vechi de unelte, pentru orice limbaj (JavaScript, Python, Rust, Go, Java, PHP, .NET, C++ și multe altele). Dacă nu, aplicația nu le caută deloc.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Poți schimba oricând din Setări.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Spacer()
                Button("Nu") { answer(false) }.buttonStyle(SecondaryButtonStyle(height: 36))
                Button("Da, sunt dezvoltator") { answer(true) }.buttonStyle(PrimaryButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func answer(_ dev: Bool) {
        Profile.answer(developer: dev)
        done()
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

/// Confirmare → (opțional) închiderea aplicațiilor → curățare secvențială → rezultat. Folosit din Prezentare și Recomandări.
/// Țintele blocate de o aplicație care rulează se sar, dacă nu bifezi închiderea ei.
@MainActor
final class CleanFlow: ObservableObject {
    /// O aplicație (sau proces CLI) care rulează și blochează unele ținte.
    struct Blocker: Identifiable {
        let id: String
        let name: String
        let apps: [NSRunningApplication]
        let targets: [CleanTarget]
        /// Doar procesele CLI (sesiuni, Gradle, emulator) nu se pot închide de aici.
        var quittable: Bool { !apps.isEmpty }
    }

    struct Plan: Identifiable {
        let id = UUID()
        /// Țintele libere, care se curăță oricum.
        let targets: [CleanTarget]
        let blockers: [Blocker]
    }

    @Published var plan: Plan?
    @Published var forcePlan: (plan: Plan, quit: Set<String>)?
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
            var free: [CleanTarget] = []
            var blockers: [Blocker] = []
            for t in targets {
                let procs = t.procs
                guard !procs.isEmpty, await offMain({ Procs.running(procs) }) else { free.append(t); continue }
                let key = t.appName ?? procs.joined(separator: ",")
                if let i = blockers.firstIndex(where: { $0.id == key }) {
                    let b = blockers[i]
                    blockers[i] = Blocker(id: b.id, name: b.name, apps: b.apps, targets: b.targets + [t])
                } else {
                    blockers.append(Blocker(id: key, name: key, apps: AppQuitter.matching(procs: procs), targets: [t]))
                }
            }
            running = false
            plan = Plan(targets: free, blockers: blockers)
        }
    }

    func confirm(_ p: Plan, quit: Set<String>, force: Bool = false) {
        plan = nil
        forcePlan = nil
        guard let rec else { return }
        running = true
        Task {
            let chosen = p.blockers.filter { quit.contains($0.id) && $0.quittable }
            var seen = Set<pid_t>()
            let apps = chosen.flatMap(\.apps).filter { seen.insert($0.processIdentifier).inserted }
            if !apps.isEmpty, !(await AppQuitter.quit(apps, force: force)) {
                running = false
                forcePlan = (p, quit)
                return
            }
            var freed: Int64 = 0
            var errors: [String] = []
            var trashed = false
            for t in p.targets + chosen.flatMap(\.targets) {
                switch await rec.clean(t) {
                case .success(let r):
                    freed += r.freed
                    errors += r.errors
                    trashed = trashed || t.trash
                case .failure(let e):
                    errors.append("\(t.name): \(e.message)")
                }
            }
            let skipped = p.blockers.filter { !chosen.map(\.id).contains($0.id) }
            running = false
            let cleaned = p.targets + chosen.flatMap(\.targets)
            HistoryStore.shared.record(.clean, title: cleaned.count == 1 ? cleaned[0].name : tr("\(cleaned.count) elemente curățate"),
                                       detail: cleaned.count == 1 ? trKey(cleaned[0].group) : cleaned.prefix(4).map(\.name).joined(separator: ", "),
                                       bytes: freed, trashed: trashed)
            let note = trashed ? "\n" + tr("Fișierele mutate la Coș eliberează spațiu după golirea Coșului.") : ""
            let skipNote = skipped.isEmpty ? "" : "\n" + tr("Sărite (rulează): \(skipped.map(\.name).joined(separator: ", ")).")
            if errors.isEmpty {
                message = (tr("Gata"), tr("Am eliberat \(Fmt.bytes(freed)).") + note + skipNote)
            } else {
                message = (tr("Curățat parțial"),
                           tr("Am eliberat \(Fmt.bytes(freed)).") + note + skipNote + "\n\n" + errors.prefix(12).joined(separator: "\n"))
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
            .appSheet(isPresented: Binding(get: { flow.plan != nil }, set: { if !$0 { flow.plan = nil } })) {
                if let p = flow.plan { CleanConfirmSheet(plan: p, flow: flow) }
            }
            .appDialog(isPresented: Binding(get: { flow.forcePlan != nil }, set: { if !$0 { flow.forcePlan = nil } }),
                       title: { tr("Unele aplicații nu s-au închis") },
                       message: { tr("Probabil așteaptă un răspuns (ex. salvarea unui document). Verifică fereastra lor sau forțează închiderea; modificările nesalvate se pierd.") },
                       buttons: {
                           let f = flow.forcePlan
                           return [DialogButton(title: tr("Forțează închiderea"), kind: .destructive) {
                                       if let f { flow.confirm(f.plan, quit: f.quit, force: true) }
                                   }, .cancel()]
                       })
            .appMessage($flow.message)
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
    /// Aplicațiile bifate pentru închidere; implicit niciuna, țintele lor se sar.
    @State private var quit: Set<String> = []

    private var included: [CleanTarget] {
        plan.targets + plan.blockers.filter { quit.contains($0.id) }.flatMap(\.targets)
    }
    private var bytes: Int64 { included.reduce(0) { $0 + (flow.rec?.sizes[$1.id] ?? 0) } }
    private var careCount: Int { included.filter { $0.risk != .safe }.count }
    private var quitting: Bool { plan.blockers.contains { quit.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Curăță \(Fmt.bytes(bytes))?").font(.title2.weight(.semibold))
            Text(careCount > 0
                 ? tr("\(included.count) elemente, din care \(careCount) marcate „Atenție”. Ce se șterge definitiv nu mai poate fi recuperat.")
                 : tr("\(included.count) elemente, toate sigure: se refac singure la nevoie."))
                .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.targets) { t in targetRow(t) }
                }
            }
            .frame(maxHeight: 180)
            if !plan.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rulează acum — se sar, dacă nu bifezi închiderea:")
                        .font(.callout.weight(.semibold))
                    ForEach(plan.blockers) { b in blockerRow(b) }
                }
            }
            HStack {
                Spacer()
                Button("Anulează") { flow.plan = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle(height: 36))
                Button(quitting ? tr("Închide și curăță") : tr("Curăță")) { flow.confirm(plan, quit: quit) }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .keyboardShortcut(.defaultAction)
                    .disabled(included.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func targetRow(_ t: CleanTarget) -> some View {
        HStack {
            Text(t.name).lineLimit(1)
            RiskMark(risk: t.risk)
            Spacer()
            Text(Fmt.bytes(flow.rec?.sizes[t.id])).monospacedDigit().foregroundStyle(Theme.muted)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func blockerRow(_ b: CleanFlow.Blocker) -> some View {
        let size = b.targets.reduce(Int64(0)) { $0 + (flow.rec?.sizes[$1.id] ?? 0) }
        HStack(alignment: .firstTextBaseline) {
            if b.quittable {
                Toggle(isOn: Binding(get: { quit.contains(b.id) },
                                     set: { if $0 { quit.insert(b.id) } else { quit.remove(b.id) } })) {
                    Text("Închide \(b.name)").lineLimit(1)
                }
                .toggleStyle(.checkbox)
            } else {
                Label { Text("\(b.name) — închide-l manual").lineLimit(1) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(Theme.careFg)
            }
            Spacer()
            Text(Fmt.bytes(size)).monospacedDigit().foregroundStyle(Theme.muted)
        }
        .font(.callout)
        .help(b.targets.map(\.name).joined(separator: "\n"))
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
    /// Notificare când RAM-ul liber scade sub 5% sau procesorul liber sub 10%.
    static let loadAlertsKey = "loadAlerts"

    static var rescanHours: Int { UserDefaults.standard.object(forKey: rescanHoursKey) as? Int ?? 6 }
    static var lowSpaceGB: Int { UserDefaults.standard.object(forKey: lowSpaceGBKey) as? Int ?? 4 }
    static var loadAlerts: Bool { UserDefaults.standard.object(forKey: loadAlertsKey) as? Bool ?? true }
}

extension Notification.Name {
    static let openCleanerSettings = Notification.Name("openCleanerSettings")
    /// Deschide o secțiune (`Section.rawValue` în `object`), de exemplu din click pe notificare.
    static let openCleanerSection = Notification.Name("openCleanerSection")
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
    @ObservedObject var update: UpdateStore
    @AppStorage(Profile.devModeKey) private var devMode = false
    @AppStorage(Profile.hiddenKey) private var hiddenRaw = ""
    @AppStorage(UpdateStore.autoCheckKey) private var autoUpdate = true
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var atLogin = LoginItem.enabled
    @State private var hasFDA = FullDiskAccess.granted()
    @AppStorage(Prefs.rescanHoursKey) private var rescanHours = 6
    @AppStorage(Prefs.lowSpaceGBKey) private var lowSpaceGB = 4
    @AppStorage(Prefs.loadAlertsKey) private var loadAlerts = true
    @State private var confirmUninstall = false
    @State private var uninstallError: (title: String, body: String)?

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
                group("PROFIL") {
                    row("Sunt dezvoltator", Text("Adaugă secțiunea Dezvoltator: cache-uri, build-uri și versiuni vechi de unelte, pentru orice limbaj de programare. Oprit, acestea nu se mai caută.")) {
                        Toggle("", isOn: Binding(get: { devMode }, set: { on in Profile.answer(developer: on) }))
                            .toggleStyle(.switch).labelsHidden().tint(Theme.accentFill)
                    }
                    let hidden = Tech.allCases.filter(Profile.decode(hiddenRaw).contains)
                    if devMode && !hidden.isEmpty {
                        divider
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ecosisteme ascunse").fontWeight(.semibold)
                                Text("Nu se caută și nu apar în secțiunea Dezvoltator.")
                                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                            }
                            ForEach(hidden) { t in
                                HStack(spacing: 10) {
                                    Image(systemName: t.icon).frame(width: 18).foregroundStyle(Theme.muted)
                                    Text(t.title)
                                    Spacer()
                                    Button("Arată") { Profile.setHidden(t, false) }
                                        .buttonStyle(SecondaryButtonStyle(height: 28))
                                }
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
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
                            Text("4 GB").tag(4)
                            Text("5 GB").tag(5)
                            Text("10 GB").tag(10)
                            Text("20 GB").tag(20)
                            Text("50 GB").tag(50)
                        }
                        .labelsHidden().fixedSize()
                    }
                    divider
                    row("Avertizează când Mac-ul e încărcat", Text("Notificare când RAM-ul liber scade sub 5% sau procesorul e liber sub 10% timp de un minut, cu aplicația care consumă cel mai mult.")) {
                        Toggle("", isOn: $loadAlerts).toggleStyle(.switch).labelsHidden().tint(Theme.accentFill)
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
                    row("Cleaner", Text(tr("Versiunea \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))") + updateStatus)) {
                        Button("Caută actualizări") { Task { await update.check(manual: true) } }
                            .buttonStyle(SecondaryButtonStyle(height: 32))
                            .disabled(update.busy)
                    }
                    if let r = update.release {
                        divider
                        updateRow(r)
                    }
                    divider
                    row("Caută actualizări automat", Text("O dată pe zi, din GitHub Releases. Instalarea pornește doar când o confirmi.")) {
                        Toggle("", isOn: $autoUpdate).toggleStyle(.switch).labelsHidden().tint(Theme.accentFill)
                    }
                    divider
                    row("Cod sursă pe GitHub", Text("Gratuit și open source (licență MIT). Dacă îți e de folos, o stea pe GitHub îi ajută și pe alții să-l găsească. Acolo poți raporta și probleme.")) {
                        HStack(spacing: 8) {
                            Button("Raportează o problemă") { NSWorkspace.shared.open(UpdateStore.repoURL.appendingPathComponent("issues")) }
                                .buttonStyle(SecondaryButtonStyle(height: 32))
                            Button { NSWorkspace.shared.open(UpdateStore.repoURL) } label: {
                                Label("Dă-ne o stea", systemImage: "star.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle(height: 32))
                        }
                    }
                }
                group("DEZINSTALARE") {
                    row("Dezinstalează Cleaner", Text("Mută aplicația la Coș, împreună cu setările, istoricul și cache-urile ei, și oprește pornirea la login. Ce ai curățat nu se schimbă.")) {
                        Button("Dezinstalează…") { confirmUninstall = true }
                            .buttonStyle(SecondaryButtonStyle(height: 32))
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
        .appDialog(isPresented: $confirmUninstall,
                   title: { tr("Dezinstalezi Cleaner?") },
                   message: { tr("Aplicația, setările, istoricul și cache-urile ei se mută la Coș, iar Cleaner se închide. Le poți recupera din Coș până îl golești.") },
                   buttons: { [.cancel(), DialogButton(title: tr("Dezinstalează"), kind: .destructive) {
                       if let err = SelfUninstall.run() {
                           // Dialogul curent se închide după acțiune; mesajul apare imediat după.
                           DispatchQueue.main.async { uninstallError = (tr("Nu s-a putut dezinstala"), err) }
                       }
                   }] })
        .appMessage($uninstallError)
    }

    private var divider: some View { Rectangle().fill(Theme.lineSoft).frame(height: 1) }


    /// Completează rândul cu versiunea: rezultatul ultimei verificări.
    private var updateStatus: String {
        switch update.state {
        case .checking: " · " + tr("Se verifică…")
        case .upToDate: " · " + tr("Ai ultima versiune.")
        case .failed(let m) where update.release == nil: "\n" + m
        default: ""
        }
    }

    @ViewBuilder
    private func updateRow(_ r: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Versiunea \(r.version) e disponibilă").fontWeight(.semibold)
                    switch update.state {
                    case .downloading(_, let p):
                        ProgressView(value: p).frame(maxWidth: 260)
                    case .installing:
                        Text("Se instalează; aplicația repornește singură.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    case .failed(let m):
                        Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    default:
                        Text("Se descarcă, i se verifică semnătura, apoi aplicația repornește.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Sari peste") { update.skip(r) }
                    .buttonStyle(SecondaryButtonStyle(height: 32)).disabled(update.busy)
                Button("Pagina versiunii") { update.openPage(r) }
                    .buttonStyle(SecondaryButtonStyle(height: 32))
                Button("Instalează și repornește") { update.install(r) }
                    .buttonStyle(PrimaryButtonStyle(height: 32)).disabled(update.busy)
            }
            if !r.notes.isEmpty {
                Text(r.notes).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    .lineLimit(8).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

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
