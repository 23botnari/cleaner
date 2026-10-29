import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@main
struct CuratenieMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // În App, nu în fereastră: iconița din bara de meniu le folosește și cu fereastra închisă.
    @StateObject private var rec = RecommendationsStore()
    @StateObject private var left = LeftoversStore()

    var body: some Scene {
        WindowGroup("Cleaner", id: "main") {
            ContentView(rec: rec, left: left)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarPanel(rec: rec, left: left)
        } label: {
            MenuBarLabel(rec: rec, left: left)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Notificarea apare și când Cleaner e aplicația activă.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Ieșire reală doar din meniul din bară sau la logout / oprire.
    static var quitting = false

    /// Rămâne în bara de meniu după închiderea ferestrei; se închide din meniu → Ieșire.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quit din Dock / ⌘Q: închide ferestrele și ascunde iconița din Dock, iconița din bară rămâne.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitting { return .terminateNow }
        for w in sender.windows where w.canBecomeMain { w.close() }
        Self.hideFromDock()
        return .terminateCancel
    }

    /// Redeschis din Finder / Launchpad: revine în Dock; SwiftUI recreează fereastra.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showInDock()
        return true
    }

    static func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hideFromDock() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Diagnostic: CURATENIE_SNAPSHOT=/cale/prefix salvează capturi ale ferestrei (fără permisiune de înregistrare ecran).
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableOnce()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            AppDelegate.quitting = true
        }
        // Ultima fereastră închisă → dispare și din Dock.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0 !== closing && $0.canBecomeMain && $0.isVisible }) { AppDelegate.hideFromDock() }
            }
        }
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()
        guard let prefix = ProcessInfo.processInfo.environment["CURATENIE_SNAPSHOT"] else { return }
        let diag = [
            "fda=\(FullDiskAccess.granted())",
            "tcc=\(FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil)",
            "safari=\((try? FileManager.default.contentsOfDirectory(atPath: Paths.hp("Library", "Safari"))) != nil)",
            "trash=\((try? FileManager.default.contentsOfDirectory(atPath: Paths.hp(".Trash")))?.count ?? -1)",
        ].joined(separator: "\n")
        try? diag.write(toFile: prefix + "-diag.txt", atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["CURATENIE_TARGETS"] != nil {
            DispatchQueue.global().async {
                let list = (Targets.homebrewTargets() + Targets.devCacheTargets() + Targets.iosDeviceTargets() + Targets.downloadsTargets()
                    + Targets.timeMachineTargets() + Targets.browserTargets()).filter(\.isVisible) + Targets.duplicateTargets()
                let dump = list.map { "[\($0.group)] \($0.name) = \(Fmt.bytes($0.size())) (\($0.resolve().count) căi)" }
                    + StartupScanner.scan().map { "[Pornire] \($0.label) \($0.domain) disabled=\($0.disabled) loaded=\($0.loaded)" }
                try? dump.joined(separator: "\n").write(toFile: prefix + "-targets.txt", atomically: true, encoding: .utf8)
            }
        }
        if ProcessInfo.processInfo.environment["CURATENIE_LEFTOVERS"] != nil {
            DispatchQueue.global().async {
                let dump = LeftoverScanner.scan().map { f in
                    "[\(f.kind.title)] \(f.title) (\(f.risk.label))\n" + f.shown.map { "    " + $0 }.joined(separator: "\n")
                        + "\n  plan:\n" + LeftoverActions.plan(f).lines.map { "    " + $0 }.joined(separator: "\n")
                }.joined(separator: "\n")
                try? dump.write(toFile: prefix + "-leftovers.txt", atomically: true, encoding: .utf8)
            }
        }
        for delay in [3.0, 15.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(Int(delay)).png"))
            }
        }
    }
}

enum Tab: Hashable { case rec, exp, apps, left, start }

struct ContentView: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var left: LeftoversStore
    @StateObject private var exp = ExplorerStore()
    @StateObject private var apps = AppsStore()
    @StateObject private var startup = StartupStore()
    @State private var tab: Tab = ["exp": .exp, "apps": .apps, "left": .left, "start": .start][ProcessInfo.processInfo.environment["CURATENIE_TAB"] ?? ""] ?? .rec
    @State private var hasFDA = FullDiskAccess.granted()

    var body: some View {
        VStack(spacing: 0) {
            if !hasFDA { FDABanner { hasFDA = FullDiskAccess.granted() } }
            StorageHeader(store: rec)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            HStack {
                Picker("", selection: $tab) {
                    Text("Recomandări").tag(Tab.rec)
                    Text("Explorator").tag(Tab.exp)
                    Text("Aplicații").tag(Tab.apps)
                    Text("Resturi").tag(Tab.left)
                    Text("Pornire").tag(Tab.start)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 560)
                Spacer()
                if tab == .rec {
                    Button { rec.scan() } label: { Label("Scanează din nou", systemImage: "arrow.clockwise") }
                        .disabled(rec.scanning)
                } else if tab == .apps {
                    Button { apps.scan() } label: { Label("Scanează din nou", systemImage: "arrow.clockwise") }
                        .disabled(apps.loading)
                } else if tab == .left {
                    Button { left.scan() } label: { Label("Scanează din nou", systemImage: "arrow.clockwise") }
                        .disabled(left.scanning)
                } else if tab == .start {
                    Button { startup.scan() } label: { Label("Reîmprospătează", systemImage: "arrow.clockwise") }
                        .disabled(startup.loading)
                } else {
                    Button { exp.refresh() } label: { Label("Reîmprospătează", systemImage: "arrow.clockwise") }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)
            Divider()
            switch tab {
            case .rec: RecommendationsView(store: rec)
            case .exp: ExplorerView(store: exp, onChange: { rec.refreshDisk() })
            case .apps: AppsView(store: apps, onChange: { rec.refreshDisk() })
            case .left: LeftoversView(store: left, hasFDA: hasFDA, onChange: { rec.refreshDisk() })
            case .start: StartupView(store: startup)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            rec.scanIfNeeded()
            exp.open(Paths.realHome)
            apps.scan()
            left.scanIfNeeded()
            startup.scanIfNeeded()
            if let dir = ProcessInfo.processInfo.environment["CURATENIE_BIG"] {  // diagnostic
                exp.path = dir
                exp.findBigFiles()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFDA = FullDiskAccess.granted()
            rec.refreshDisk()
        }
    }
}

// MARK: - Full Disk Access

struct FDABanner: View {
    var recheck: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lipsește accesul complet la disc (Full Disk Access)").font(.headline)
                Text("Fără el, aplicația nu poate vedea sau curăța unele foldere (de ex. WhatsApp, Coșul, unele cache-uri), iar mărimile pot fi mai mici decât în realitate. "
                     + "Deschide setarea, activează „Cleaner”, apoi repornește aplicația.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Deschide setarea") { FullDiskAccess.openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Verifică din nou", action: recheck).buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Bara de stocare

struct StorageHeader: View {
    @ObservedObject var store: RecommendationsStore

    var body: some View {
        let total = max(store.diskTotal, 1)
        let used = max(0, store.diskTotal - store.diskFree)
        let recl = min(store.reclaimable, used)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.bytes(store.diskFree))
                    .font(.system(size: 44, weight: .bold)).monospacedDigit()
                Text("liber din \(Fmt.bytes(store.diskTotal))")
                    .font(.title3).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(Color.gray.opacity(0.75))
                        .frame(width: w * CGFloat(used - recl) / CGFloat(total))
                    Rectangle().fill(Color.green)
                        .frame(width: w * CGFloat(recl) / CGFloat(total))
                    Rectangle().fill(Color.gray.opacity(0.18))
                }
                .animation(.easeOut(duration: 0.5), value: recl)
            }
            .frame(height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 20) {
                legend(.gray.opacity(0.75), "Folosit", Fmt.bytes(used))
                legend(.green, "Se poate elibera", Fmt.bytes(store.reclaimable),
                       extra: store.pendingCount > 0 || store.scanning ? "(se calculează…)" : nil)
                legend(.gray.opacity(0.18), "Liber", Fmt.bytes(store.diskFree))
            }
            .font(.callout)
        }
    }

    private func legend(_ c: Color, _ label: String, _ value: String, extra: String? = nil) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
            if let extra { Text(extra).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Recomandări

struct RiskBadge: View {
    let risk: Risk
    var body: some View {
        let c: Color = switch risk {
        case .safe: .green
        case .care: .orange
        case .suspect: .purple
        }
        Text(risk.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.18)))
            .foregroundStyle(c)
    }
}

struct RecommendationsView: View {
    @ObservedObject var store: RecommendationsStore
    @State private var confirm: CleanTarget?
    @State private var message: (title: String, body: String)?
    @State private var checking: String?
    @State private var quit: QuitPrompt?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if store.scanning {
                    HStack { ProgressView().controlSize(.small); Text("Caut ce se poate curăța…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(store.groups, id: \.name) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(g.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.bytes(g.total)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(g.items.enumerated()), id: \.element.id) { i, t in
                                if i > 0 { Divider() }
                                row(t)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    }
                }
                if store.scanningNodeModules && !store.scanning {
                    HStack { ProgressView().controlSize(.small); Text("Caut foldere node_modules și fișiere duplicate…").foregroundStyle(.secondary) }
                        .padding(.horizontal, 4)
                }
                if !store.scanning && !store.scanningNodeModules && store.targets.isEmpty {
                    Text("Nimic de curățat.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(24)
        }
        .alert(item: Binding(get: { confirm.map(IdentifiedTarget.init) }, set: { confirm = $0?.target })) { wrapped in
            let t = wrapped.target
            return Alert(
                title: Text("Curăță „\(t.name)”?"),
                message: Text("\(Fmt.bytes(store.sizes[t.id])) • \(t.risk.label)\n\n\(t.desc)"
                    + (t.risk == .care ? "\n\nAcțiunea nu poate fi anulată." : "")),
                primaryButton: .destructive(Text("Curăță")) { run(t) },
                secondaryButton: .cancel(Text("Anulează")))
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message?.body ?? "")
        }
        .quitPrompt($quit, message: $message)
    }

    @ViewBuilder
    private func row(_ t: CleanTarget) -> some View {
        let size = store.sizes[t.id]
        let isDone = store.done.contains(t.id)
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(t.name).fontWeight(.semibold)
                    RiskBadge(risk: t.risk)
                }
                Text(t.desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let app = t.appName, !t.procs.isEmpty {
                    Text("Trebuie închis: \(app)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                if let size {
                    Text(Fmt.bytes(size)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                ProgressView(value: Double(size ?? 0), total: Double(store.maxSize))
                    .progressViewStyle(.linear).tint(.gray)
            }
            .frame(width: 140)
            Group {
                if store.busy.contains(t.id) || checking == t.id {
                    ProgressView().controlSize(.small)
                } else if isDone {
                    Label("Gata", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
                } else {
                    Button("Curăță") { ask(t) }
                        .disabled(size == nil || size == 0)
                }
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .opacity(isDone ? 0.55 : 1)
    }

    private func ask(_ t: CleanTarget) {
        checking = t.id
        Task {
            let blocker = await store.blocker(for: t)
            checking = nil
            let apps = blocker == nil ? [] : AppQuitter.matching(procs: t.procs)
            if let blocker, apps.isEmpty {
                // Procese fără interfață (Gradle, emulator, sesiuni CLI): doar mesaj.
                message = ("\(t.appName ?? "Aplicația") rulează", blocker)
            } else if blocker != nil {
                let name = apps.first?.localizedName ?? t.appName ?? "aplicația"
                quit = QuitPrompt(name: name, apps: apps, action: "curățare") { ask(t) }
            } else {
                confirm = t
            }
        }
    }

    private func run(_ t: CleanTarget) {
        Task {
            switch await store.clean(t) {
            case .failure(let e):
                message = ("Nu am putut curăța", e.message)
            case .success(let r):
                if r.errors.isEmpty && t.trash {
                    message = ("Mutat la Coș", "\(Fmt.bytes(r.freed)) se eliberează după golirea Coșului.")
                } else if r.errors.isEmpty {
                    message = ("Gata", "Am eliberat \(Fmt.bytes(r.freed)).")
                } else {
                    message = ("Curățat parțial",
                               "Am eliberat \(Fmt.bytes(r.freed)). Unele elemente nu au putut fi șterse:\n\n" + r.errors.joined(separator: "\n"))
                }
            }
        }
    }
}

struct IdentifiedTarget: Identifiable {
    let target: CleanTarget
    var id: String { target.id }
}

// MARK: - Pornire la login

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Prima pornire: se înregistrează singur; după aceea decide utilizatorul din bara de meniu.
    static func enableOnce() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if set(true) { UserDefaults.standard.set(true, forKey: key) }
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("LoginItem: %@", error.localizedDescription)
            return false
        }
    }
}

// MARK: - Notificări

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Când punctul din bara de meniu devine roșu (sub 10 GB liber).
    static func lowSpace(free: Int64, reclaimable: Int64) {
        let c = UNMutableNotificationContent()
        c.title = "Spațiu puțin pe disc"
        c.body = "Mai ai \(Fmt.bytes(free)) liber." + (reclaimable > 0 ? " Cleaner poate elibera \(Fmt.bytes(reclaimable))." : "")
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowspace", content: c, trigger: nil))
    }
}

// MARK: - Bara de meniu

/// Status după spațiul liber: ≥ 50 GB verde, ≥ 25 GB galben, ≥ 10 GB portocaliu, sub 10 GB roșu.
enum DiskLevel {
    case unknown, ok, low, warn, critical

    @MainActor static func of(_ rec: RecommendationsStore) -> DiskLevel {
        guard rec.diskTotal > 0 else { return .unknown }
        let gb = Double(rec.diskFree) / 1e9
        return gb >= 50 ? .ok : gb >= 25 ? .low : gb >= 10 ? .warn : .critical
    }

    var nsColor: NSColor {
        switch self {
        case .unknown: .systemGray
        case .ok: .systemGreen
        case .low: .systemYellow
        case .warn: .systemOrange
        case .critical: .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

struct MenuBarLabel: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var left: LeftoversStore
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var lastLevel: DiskLevel = .unknown

    /// „C” decupat dintr-un pătrat rotunjit, cu un punct de status în colț.
    /// Nu e template (template pierde culoarea): alb / negru se alege la desenare, după aspectul barei.
    static func icon(_ dot: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let box = NSRect(x: 1, y: 1, width: 16, height: 16)
            (dark ? NSColor.white : NSColor.black).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4.5, yRadius: 4.5).fill()
            let c = NSAttributedString(string: "C", attributes: [
                .font: NSFont.systemFont(ofSize: 13.5, weight: .heavy), .foregroundColor: NSColor.black])
            let cs = c.size()
            let ctx = NSGraphicsContext.current
            ctx?.compositingOperation = .destinationOut
            c.draw(at: NSPoint(x: box.midX - cs.width / 2, y: box.midY - cs.height / 2))
            // Inel transparent în jurul punctului, ca să se vadă pe pătrat.
            let dotRect = NSRect(x: r.maxX - 8, y: r.maxY - 8, width: 7, height: 7)
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.2, dy: -1.2)).fill()
            ctx?.compositingOperation = .sourceOver
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.icon(DiskLevel.of(rec).nsColor))
        }
        .task {
            rec.scanIfNeeded()
            left.scanIfNeeded()
        }
        .onReceive(tick) { _ in
            rec.refreshDisk()
            // Rescanare la 6 ore, ca „se poate elibera” din notificare să fie actual.
            if !rec.scanning, let last = rec.lastScan, Date().timeIntervalSince(last) > 6 * 3600 {
                rec.scan()
                left.scan()
            }
            let level = DiskLevel.of(rec)
            if level == .critical && lastLevel != .critical {
                Notifier.lowSpace(free: rec.diskFree, reclaimable: rec.reclaimable)
            }
            lastLevel = level
        }
    }
}

struct MenuBarPanel: View {
    @ObservedObject var rec: RecommendationsStore
    @ObservedObject var left: LeftoversStore
    @Environment(\.openWindow) private var openWindow
    @State private var atLogin = LoginItem.enabled

    var body: some View {
        let total = max(rec.diskTotal, 1)
        let used = max(0, rec.diskTotal - rec.diskFree)
        let safe = left.findings.filter { $0.risk == .safe }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(rec.diskFree)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                Text("liber din \(Fmt.bytes(rec.diskTotal))").foregroundStyle(.secondary)
            }
            ProgressView(value: Double(used), total: Double(total)).tint(DiskLevel.of(rec).color)
            VStack(alignment: .leading, spacing: 6) {
                row("sparkles", "Se poate elibera",
                    rec.scanning || rec.pendingCount > 0 ? "\(Fmt.bytes(rec.reclaimable))…" : Fmt.bytes(rec.reclaimable))
                row("shippingbox", "Resturi găsite",
                    left.scanning ? "…" : "\(left.findings.count)" + (safe > 0 ? " (\(safe) sigure)" : ""))
            }
            Toggle("Pornește la deschiderea Mac-ului", isOn: Binding(get: { atLogin }, set: { on in
                LoginItem.set(on)
                atLogin = LoginItem.enabled
            }))
            .toggleStyle(.checkbox).font(.callout)
            Divider()
            HStack {
                Button("Deschide Cleaner") {
                    AppDelegate.showInDock()
                    openWindow(id: "main")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    rec.scan()
                    left.scan()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Scanează din nou")
                .disabled(rec.scanning || left.scanning)
                Spacer()
                Button("Ieșire") {
                    AppDelegate.quitting = true
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            rec.refreshDisk()
            atLogin = LoginItem.enabled
        }
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack {
            Label(label, systemImage: icon).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
    }
}
