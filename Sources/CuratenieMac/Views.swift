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

    init() {
        AppLanguage.applyDefaultOnce()
    }

    var body: some Scene {
        WindowGroup("Cleaner MacOS", id: "main") {
            ContentView(rec: rec, left: left)
                .frame(minWidth: 1120, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Setări…") { NotificationCenter.default.post(name: .openCleanerSettings, object: nil) }
                    .keyboardShortcut(",")
            }
        }

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
        if let sz = ProcessInfo.processInfo.environment["CURATENIE_WINSIZE"]?.split(separator: "x").compactMap({ Double($0) }), sz.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.setContentSize(NSSize(width: sz[0], height: sz[1]))
            }
        }
        for delay in [3.0, 15.0, 45.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let view = win.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                // Efectele de transparență nu se desenează în cache: pune dedesubt fundalul ferestrei.
                let img = NSImage(size: view.bounds.size)
                img.lockFocus()
                win.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                }
                rep.draw(in: view.bounds)
                img.unlockFocus()
                if let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
                    try? out.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(prefix)-\(Int(delay)).png"))
                }
            }
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
                Text("Fără el, aplicația nu poate vedea sau curăța unele foldere (de ex. WhatsApp, Coșul, unele cache-uri), iar mărimile pot fi mai mici decât în realitate. Deschide setarea, activează „Cleaner MacOS”, apoi repornește aplicația.")
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

// MARK: - Pornire la login

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Prima pornire: se înregistrează singur; după aceea decide utilizatorul din bara de meniu.
    static func enableOnce() {
        let d = UserDefaults.standard
        let key = "loginItemConfigured"
        if !d.bool(forKey: key) {
            if set(true) { d.set(true, forKey: key) }
            d.set(true, forKey: "loginItemMigratedToCleanerMacOS")
            return
        }
        // Redenumirea în „Cleaner MacOS” mută .app-ul: o singură dată, reînregistrează elementul de login.
        if !d.bool(forKey: "loginItemMigratedToCleanerMacOS") {
            if !enabled { set(true) }
            d.set(true, forKey: "loginItemMigratedToCleanerMacOS")
        }
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
        c.title = tr("Spațiu puțin pe disc")
        c.body = reclaimable > 0
            ? tr("Mai ai \(Fmt.bytes(free)) liber. Cleaner MacOS poate elibera \(Fmt.bytes(reclaimable)).")
            : tr("Mai ai \(Fmt.bytes(free)) liber.")
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
    @State private var wasLow = false

    /// Același semn ca iconița aplicației: inel deschis; segmentul din gol are culoarea statusului.
    /// Nu e template (template pierde culoarea): inelul e alb / negru după aspectul barei.
    static func icon(_ dot: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = NSPoint(x: r.midX, y: r.midY)
            func arc(_ a: CGFloat, _ b: CGFloat, _ color: NSColor) {
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: 6.2, startAngle: a, endAngle: b, clockwise: false)
                p.lineWidth = 2.6
                p.lineCapStyle = .round
                color.setStroke()
                p.stroke()
            }
            arc(100, 360, dark ? .white : .black)
            arc(34, 66, dot)
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
            let hours = Prefs.rescanHours
            if hours > 0, !rec.scanning, let last = rec.lastScan, Date().timeIntervalSince(last) > Double(hours) * 3600 {
                rec.scan()
                left.scan()
            }
            let level = DiskLevel.of(rec)
            let limit = Int64(Prefs.lowSpaceGB) * 1_000_000_000
            let low = limit > 0 && rec.diskTotal > 0 && rec.diskFree < limit
            if low && !wasLow { Notifier.lowSpace(free: rec.diskFree, reclaimable: rec.reclaimable) }
            wasLow = low
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
                row("sparkles", tr("Se poate elibera"),
                    rec.scanning || rec.pendingCount > 0 ? "\(Fmt.bytes(rec.reclaimable))…" : Fmt.bytes(rec.reclaimable))
                row("shippingbox", tr("Resturi găsite"),
                    left.scanning ? "…" : (safe > 0 ? tr("\(left.findings.count) (\(safe) sigure)") : "\(left.findings.count)"))
            }
            Toggle("Pornește la deschiderea Mac-ului", isOn: Binding(get: { atLogin }, set: { on in
                LoginItem.set(on)
                atLogin = LoginItem.enabled
            }))
            .toggleStyle(.checkbox).font(.callout)
            Divider()
            HStack {
                Button("Deschide Cleaner MacOS") {
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
                OpenSettingsButton { Image(systemName: "gearshape") }
                    .help("Setări")
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
