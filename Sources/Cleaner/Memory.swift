import SwiftUI
import AppKit
import Darwin
import UserNotifications

// MARK: - Citiri de sistem

struct MemoryStats: Sendable {
    let total: UInt64
    /// Ca în Activity Monitor: memoria aplicațiilor + wired + comprimată.
    let used: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    /// Fișiere ținute în RAM ca să se deschidă repede; macOS le eliberează singur.
    let cached: UInt64
    let swapUsed: UInt64
    /// 1 normal, 2 avertizare, 4 critic (kern.memorystatus_vm_pressure_level).
    let pressure: Int

    var available: UInt64 { total > used ? total - used : 0 }
    var freeFraction: Double { Double(available) / Double(max(total, 1)) }
}

/// Un proces al utilizatorului curent (ale sistemului nu se pot citi fără root).
struct ProcSample: Sendable {
    let pid: pid_t
    let path: String
    let footprint: UInt64
    /// Timp CPU total, în nanosecunde.
    let cpuNs: UInt64
}

enum SysInfo {
    private static let host = mach_host_self()
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(tb.denom, 1)))
    }()

    static func memory() -> MemoryStats {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        let page = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let internalPages = UInt64(s.internal_page_count)
        let purgeable = UInt64(s.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(s.wire_count) * page
        let compressed = UInt64(s.compressor_page_count) * page
        let cached = (UInt64(s.external_page_count) + purgeable) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        return MemoryStats(total: total, used: min(total, app + wired + compressed), app: app, wired: wired,
                           compressed: compressed, cached: cached, swapUsed: swap.xsu_used, pressure: Int(level))
    }

    /// Tick-uri CPU cumulate (toate nucleele): ocupate și totale.
    static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    static func processes() -> [ProcSample] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let uid = getuid()
        var out: [ProcSample] = []
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, got)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbi_uid == uid else { continue }
            var ru = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let path = String(cString: pathBuf)
            let ticks = ru.ri_user_time + ru.ri_system_time
            out.append(ProcSample(pid: pid, path: path, footprint: ru.ri_phys_footprint,
                                  cpuNs: ticks * timebase.numer / timebase.denom))
        }
        return out
    }
}

// MARK: - Procese grupate pe aplicație

struct ProcGroup: Identifiable, Sendable {
    /// Calea aplicației (.app) sau „pid:<n>” pentru un proces de sine stătător.
    let id: String
    let name: String
    let appPath: String?
    let pids: [pid_t]
    let memory: UInt64
    /// Procente dintr-un nucleu, ca în Activity Monitor (poate trece de 100).
    let cpu: Double
    let canQuit: Bool
}

enum ProcGrouping {
    /// Procese de-ale sistemului care rulează sub utilizatorul tău: oprirea lor strică sesiunea.
    private static let protectedNames: Set<String> = [
        "loginwindow", "Dock", "Finder", "SystemUIServer", "ControlCenter", "WindowManager", "NotificationCenter",
        "Spotlight", "launchd", "cfprefsd", "distnoted", "UserEventAgent", "TextInputMenuAgent", "universalaccessd",
    ]
    private static let systemPrefixes = ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/",
                                         "/System/iOSSupport/"]

    /// Prima componentă „.app” din cale: ajutoarele Chrome / Electron se adună la aplicația lor.
    static func appPath(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func group(_ procs: [ProcSample], cpu: [pid_t: Double], names: [String: String]) -> [ProcGroup] {
        let me = Bundle.main.bundlePath
        var byKey: [String: [ProcSample]] = [:]
        for p in procs {
            let key = appPath(p.path) ?? "pid:\(p.pid)"
            byKey[key, default: []].append(p)
        }
        return byKey.map { key, list in
            let app = key.hasPrefix("pid:") ? nil : key
            let path = app ?? list[0].path
            let name = app.map { names[$0] ?? ((($0 as NSString).lastPathComponent as NSString).deletingPathExtension) }
                ?? toolName(list[0].path)
            let system = systemPrefixes.contains { path.hasPrefix($0) }
            let canQuit = path != me && !system && !protectedNames.contains(name)
            return ProcGroup(id: key, name: name, appPath: app, pids: list.map(\.pid),
                             memory: list.reduce(0) { $0 + $1.footprint },
                             cpu: list.reduce(0) { $0 + (cpu[$1.pid] ?? 0) }, canQuit: canQuit)
        }
    }

    /// Uneltele instalate pe versiuni (…/claude/versions/2.1.3) au ca nume doar versiunea: adaug unealta.
    static func toolName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return path }
        guard last.first?.isNumber == true else { return last }
        let tool = parts.dropLast().reversed().first { !["versions", "bin", "libexec"].contains($0) && $0.first?.isNumber != true }
        return tool.map { "\($0) \(last)" } ?? last
    }

    /// Numele afișat al aplicațiilor (din Info.plist), citit o singură dată.
    static func names(for apps: [String], known: [String: String]) -> [String: String] {
        var out = known
        for a in apps where out[a] == nil {
            let info = Bundle(path: a)?.localizedInfoDictionary ?? Bundle(path: a)?.infoDictionary
            out[a] = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                ?? ((a as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return out
    }
}

// MARK: - Monitor

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var memory: MemoryStats?
    /// 0…1, toate nucleele.
    @Published private(set) var cpu: Double = 0
    @Published private(set) var groups: [ProcGroup] = []

    /// Bazele pentru vizualizare (la 2 s) și pentru alerte (la 60 s) sunt separate: altfel s-ar strica una pe alta.
    private struct Baseline {
        var ticks: (busy: UInt64, total: UInt64)?
        var procCPU: [pid_t: UInt64] = [:]
        var time: UInt64 = 0
    }
    private var view = Baseline()
    private var alert = Baseline()
    private var names: [String: String] = [:]
    private var refreshing = false

    /// Când a fost fiecare aplicație ultima dată în față (doar de la pornirea Cleaner).
    private var lastActive: [pid_t: Date] = [:]
    private let started = Date()
    private var activationObserver: NSObjectProtocol?

    private init() {
        if let f = NSWorkspace.shared.frontmostApplication { lastActive[f.processIdentifier] = Date() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { SystemMonitor.shared.lastActive[pid] = Date() }
        }
    }

    private var ramLow = false
    private var cpuHigh = false
    private var lastRamAlert: Date?
    private var lastCPUAlert: Date?

    private struct Sample: Sendable {
        let memory: MemoryStats
        let ticks: (busy: UInt64, total: UInt64)
        let procs: [ProcSample]
        let time: UInt64
    }

    private static func sample() async -> Sample {
        await offMain {
            Sample(memory: SysInfo.memory(), ticks: SysInfo.cpuTicks(), procs: SysInfo.processes(),
                   time: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
        }
    }

    private static func load(_ s: Sample, since b: Baseline) -> (cpu: Double, perProc: [pid_t: Double]) {
        var total = 0.0
        if let t = b.ticks, s.ticks.total > t.total {
            total = Double(s.ticks.busy - min(s.ticks.busy, t.busy)) / Double(s.ticks.total - t.total)
        }
        var per: [pid_t: Double] = [:]
        let dt = Double(s.time - min(s.time, b.time))
        if b.time > 0, dt > 0 {
            for p in s.procs {
                if let old = b.procCPU[p.pid], p.cpuNs >= old { per[p.pid] = Double(p.cpuNs - old) / dt * 100 }
            }
        }
        return (min(max(total, 0), 1), per)
    }

    private static func baseline(_ s: Sample) -> Baseline {
        Baseline(ticks: s.ticks, procCPU: Dictionary(s.procs.map { ($0.pid, $0.cpuNs) }, uniquingKeysWith: { a, _ in a }),
                 time: s.time)
    }

    private func groups(_ s: Sample, per: [pid_t: Double]) -> [ProcGroup] {
        names = ProcGrouping.names(for: Set(s.procs.compactMap { ProcGrouping.appPath($0.path) }).sorted(), known: names)
        return ProcGrouping.group(s.procs, cpu: per, names: names)
    }

    /// Pentru secțiunea Memorie.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let s = await Self.sample()
        let l = Self.load(s, since: view)
        let first = view.ticks == nil
        view = Self.baseline(s)
        memory = s.memory
        if !first { cpu = l.cpu }
        groups = groups(s, per: l.perProc)
        // Câte citiri la rând (la 2 s) a stat fiecare grup peste 80% CPU.
        var nextHot: [String: Int] = [:]
        if !first { for g in groups where g.cpu > 80 { nextHot[g.id] = (hotCount[g.id] ?? 0) + 1 } }
        hotCount = nextHot
    }

    private var hotCount: [String: Int] = [:]

    // MARK: Recomandări

    /// Procese de sistem care se repornesc singure dacă le închizi (launchd le pornește imediat la loc).
    static let selfRestarting: Set<String> = ["ControlCenter", "Control Center", "Dock", "NotificationCenter",
                                              "Notification Center", "SystemUIServer", "Finder", "WindowManager", "Spotlight"]
    private static let browsers: Set<String> = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Firefox", "Opera",
                                                "Vivaldi", "Chromium", "Zen", "Comet", "Dia"]
    private static let electron: Set<String> = ["Code", "Visual Studio Code", "Cursor", "Windsurf", "Slack", "Microsoft Teams",
                                                "Discord", "Notion", "Figma", "Spotify", "WhatsApp", "Postman", "Obsidian"]

    static var uptimeDays: Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return 0 }
        return Int(Date().timeIntervalSince1970 - Double(tv.tv_sec)) / 86_400
    }

    func tips() -> [MemoryTip] {
        guard let m = memory else { return [] }
        var out: [MemoryTip] = []
        let gb: UInt64 = 1_000_000_000
        let tight = m.pressure >= 2 || m.freeFraction < 0.10 || m.swapUsed > m.total / 4

        // Procese care țin procesorul ocupat de cel puțin 30 s.
        for g in groups where (hotCount[g.id] ?? 0) >= 15 && g.canQuit {
            out.append(MemoryTip(id: "hot:" + g.id, icon: "flame", level: .warn,
                                 title: tr("\(g.name) ține procesorul ocupat"),
                                 detail: tr("Folosește \(Int(g.cpu.rounded()))% CPU de peste 30 de secunde. Dacă nu lucrează la ceva anume (export, build, indexare), probabil s-a blocat: închide-o."),
                                 action: .quit(g)))
        }
        // Procese de sistem cu scurgeri de memorie: se repornesc singure.
        for g in groups where Self.selfRestarting.contains(g.name) && g.memory > gb {
            out.append(MemoryTip(id: "leak:" + g.id, icon: "drop.triangle", level: .warn,
                                 title: tr("\(g.name) folosește \(Fmt.bytes(Int64(g.memory)))"),
                                 detail: tr("De obicei are sub 200 MB: e o scurgere de memorie în macOS. Repornirea e sigură; sistemul îl pornește imediat la loc."),
                                 action: .restart(g)))
        }
        // Mașina virtuală Docker.
        if let vm = groups.first(where: { $0.name.hasPrefix("com.apple.Virtualization.VirtualMachine") }), vm.memory > 2 * gb,
           let docker = groups.first(where: { $0.name == "Docker" && $0.canQuit }) {
            out.append(MemoryTip(id: "docker", icon: "shippingbox", level: tight ? .warn : .info,
                                 title: tr("Docker ține \(Fmt.bytes(Int64(vm.memory))) pentru mașina virtuală"),
                                 detail: tr("Memoria rămâne rezervată chiar și fără containere pornite. Închide Docker Desktop când nu-l folosești sau scade limita din Settings → Resources."),
                                 action: .quit(docker)))
        }
        // Browsere și aplicații Electron mari.
        for g in groups where g.canQuit {
            if Self.browsers.contains(g.name), g.memory > 3 * gb {
                out.append(MemoryTip(id: "browser:" + g.id, icon: "globe", level: tight ? .warn : .info,
                                     title: tr("\(g.name): \(Fmt.bytes(Int64(g.memory))) în \(g.pids.count) procese"),
                                     detail: tr("Fiecare tab și extensie e un proces separat. Închide taburile de care nu ai nevoie sau pornește economisirea memoriei din setările browserului."),
                                     action: .quit(g)))
            } else if Self.electron.contains(g.name), g.memory > 2 * gb {
                out.append(MemoryTip(id: "electron:" + g.id, icon: "macwindow.on.rectangle", level: .info,
                                     title: tr("\(g.name) folosește \(Fmt.bytes(Int64(g.memory)))"),
                                     detail: tr("Aplicațiile Electron cresc în timp. Închide ferestrele sau proiectele nefolosite; o repornire o aduce de obicei la o fracțiune."),
                                     action: .quit(g)))
            }
        }
        // Aceeași unealtă CLI în mai multe versiuni: sesiuni vechi, uitate prin terminale.
        let versioned = groups.filter { $0.appPath == nil && $0.canQuit && $0.name.split(separator: " ").last?.first?.isNumber == true }
        for (tool, list) in Dictionary(grouping: versioned, by: { String($0.name.split(separator: " ").first ?? "") }) where list.count > 1 {
            let newest = list.map { String($0.name.split(separator: " ").last ?? "") }.max { $0.compare($1, options: .numeric) == .orderedAscending }
            for g in list where !g.name.hasSuffix(" " + (newest ?? "")) {
                out.append(MemoryTip(id: "old:" + g.id, icon: "terminal", level: .info,
                                     title: tr("Rulează o versiune veche de \(tool)"),
                                     detail: tr("\(g.name) (PID \(g.pids[0]), \(Fmt.bytes(Int64(g.memory)))) e probabil o sesiune uitată într-un terminal; versiunea curentă e \(newest ?? "")."),
                                     action: .quit(g)))
            }
        }
        // Aplicații deschise fără ferestre.
        let idle = idleApps().filter { $0.reason == tr("Nicio fereastră deschisă") }
        let idleBytes = idle.reduce(UInt64(0)) { $0 + $1.group.memory }
        if idle.count > 0, idleBytes > 300_000_000 {
            out.append(MemoryTip(id: "idle", icon: "moon.zzz", level: tight ? .warn : .info,
                                 title: tr("\(idle.count) aplicații deschise fără ferestre țin \(Fmt.bytes(Int64(idleBytes)))"),
                                 detail: idle.prefix(4).map(\.group.name).joined(separator: ", ") + (idle.count > 4 ? "…" : ""),
                                 action: .idle))
        }
        // Swap mare și Mac nerepornit de mult.
        if m.swapUsed > m.total / 4 {
            let days = Self.uptimeDays
            out.append(MemoryTip(id: "swap", icon: "arrow.left.arrow.right", level: m.pressure >= 2 ? .warn : .info,
                                 title: tr("\(Fmt.bytes(Int64(m.swapUsed))) de memorie mutată pe disc"),
                                 detail: days >= 7
                                    ? tr("Mac-ul nu a mai fost repornit de \(days) zile. O repornire golește swap-ul și oprește procesele uitate.")
                                    : tr("RAM-ul nu ajunge pentru ce ai deschis acum, iar Mac-ul încetinește. Închide aplicațiile mari pe care nu le folosești."),
                                 action: nil))
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }

    /// Repornește un proces de sistem care se repornește singur (SIGTERM; launchd îl pornește la loc).
    func restart(_ g: ProcGroup) {
        guard Self.selfRestarting.contains(g.name) else { return }
        g.pids.forEach { kill($0, SIGTERM) }
    }

    /// Din bara de meniu, o dată pe minut: RAM liber sub 5% sau CPU liber sub 10% (în medie, pe ultimul minut).
    func checkAlerts() async {
        let s = await Self.sample()
        let l = Self.load(s, since: alert)
        let first = alert.ticks == nil
        alert = Self.baseline(s)
        if memory == nil { memory = s.memory }
        guard !first, Prefs.loadAlerts else { return }
        let now = Date()
        func due(_ last: Date?) -> Bool { last.map { now.timeIntervalSince($0) > 30 * 60 } ?? true }

        let ramIsLow = s.memory.freeFraction < 0.05
        if ramIsLow && !ramLow && due(lastRamAlert) {
            let top = groups(s, per: l.perProc).filter(\.canQuit).max { $0.memory < $1.memory }
            Notifier.highLoad(ram: true, percent: Int((s.memory.freeFraction * 100).rounded()),
                              top: top?.name, topValue: top.map { Fmt.bytes(Int64($0.memory)) })
            lastRamAlert = now
        }
        // Revine la normal abia peste 10%, ca să nu vină notificări la fiecare oscilație.
        ramLow = ramIsLow || (ramLow && s.memory.freeFraction < 0.10)

        let cpuIsHigh = l.cpu > 0.90
        if cpuIsHigh && !cpuHigh && due(lastCPUAlert) {
            let top = groups(s, per: l.perProc).filter(\.canQuit).max { $0.cpu < $1.cpu }
            Notifier.highLoad(ram: false, percent: Int(((1 - l.cpu) * 100).rounded()),
                              top: top?.name, topValue: top.map { "\(Int($0.cpu.rounded()))%" })
            lastCPUAlert = now
        }
        cpuHigh = cpuIsHigh || (cpuHigh && l.cpu > 0.75)
    }

    // MARK: Acțiuni

    private func runningApps(_ g: ProcGroup) -> [NSRunningApplication] {
        guard let app = g.appPath else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app }
    }

    /// Închidere normală: aplicația poate cere salvarea documentelor.
    func quit(_ g: ProcGroup) {
        guard g.canQuit else { return }
        let apps = runningApps(g)
        if apps.isEmpty { g.pids.forEach { kill($0, SIGTERM) } } else { apps.forEach { $0.terminate() } }
    }

    /// Forțare: modificările nesalvate se pierd.
    func forceQuit(_ g: ProcGroup) {
        guard g.canQuit else { return }
        runningApps(g).forEach { $0.forceTerminate() }
        g.pids.forEach { kill($0, SIGKILL) }
    }

    /// O aplicație deschisă care pare nefolosită.
    struct IdleApp: Identifiable {
        let group: ProcGroup
        let reason: String
        var id: String { group.id }
    }

    static let idleMinutes: Double = 30

    /// Aplicații obișnuite (cu iconiță în Dock) fără nicio fereastră, sau neaduse în față de 30+ minute.
    /// Aplicația din față, Finder-ul și Cleaner-ul nu intră niciodată.
    func idleApps() -> [IdleApp] {
        let windows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var withWindows = Set<pid_t>()
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: Any]
            if let h = b?["Height"] as? Double, h < 60 { continue }
            if let pid = w[kCGWindowOwnerPID as String] as? Int { withWindows.insert(pid_t(pid)) }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cutoff = Date().addingTimeInterval(-Self.idleMinutes * 60)
        let trackedLongEnough = started < cutoff
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != front
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != "com.apple.finder"
        }
        var out: [IdleApp] = []
        for g in groups where g.canQuit {
            guard let app = apps.first(where: { $0.bundleURL?.path == g.appPath }) else { continue }
            let pid = app.processIdentifier
            if !withWindows.contains(pid) {
                out.append(IdleApp(group: g, reason: tr("Nicio fereastră deschisă")))
            } else if trackedLongEnough, (lastActive[pid] ?? started) < cutoff {
                out.append(IdleApp(group: g, reason: tr("Nefolosită de peste 30 de minute")))
            }
        }
        return out.sorted { $0.group.memory > $1.group.memory }
    }

    /// Mai rulează vreun proces din grup?
    func isRunning(_ g: ProcGroup) -> Bool {
        g.pids.contains { kill($0, 0) == 0 }
    }
}

// MARK: - Recomandări

struct MemoryTip: Identifiable {
    enum Level: Int { case info, warn }
    enum Action { case quit(ProcGroup), restart(ProcGroup), idle }
    let id: String
    let icon: String
    let level: Level
    let title: String
    let detail: String
    let action: Action?
}

// MARK: - Notificare

extension Notifier {
    static func highLoad(ram: Bool, percent: Int, top: String?, topValue: String?) {
        let c = UNMutableNotificationContent()
        let culprit = top.flatMap { t in topValue.map { tr("\(t) folosește \($0).") } } ?? ""
        if ram {
            c.title = tr("Memoria e aproape plină")
            c.body = tr("Mai e liber doar \(percent)% din RAM. \(culprit) Închide ce nu folosești, ca Mac-ul să nu încetinească.")
        } else {
            c.title = tr("Procesorul e foarte încărcat")
            c.body = tr("Procesorul e liber doar \(percent)% de cel puțin un minut. \(culprit) Închide ce nu folosești, ca Mac-ul să nu încetinească.")
        }
        c.sound = .default
        c.userInfo = ["section": Section.memory.rawValue]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ram ? "highram" : "highcpu", content: c, trigger: nil))
    }
}

// MARK: - Secțiunea Memorie

struct MemoryView: View {
    @ObservedObject private var mon = SystemMonitor.shared
    @State private var byCPU = false
    @State private var confirmQuit: ProcGroup?
    @State private var confirmForce: ProcGroup?
    @State private var stuck: ProcGroup?
    @State private var idle: [SystemMonitor.IdleApp]?
    @State private var dismissed: Set<String> = []
    @State private var confirmRestart: ProcGroup?
    @State private var showAllTips = false

    var body: some View {
        VStack(spacing: 0) {
            if let m = mon.memory {
                HStack(spacing: 12) {
                    ramCard(m)
                    cpuCard
                    swapCard(m)
                }
                .padding(.horizontal, 28).padding(.bottom, 12)
                Text("macOS folosește RAM-ul liber drept cache, deci „ocupat” e normal. Contează presiunea: cât timp e verde, nu e nimic de făcut.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 12)
                tipsCard
                Rectangle().fill(Theme.line).frame(height: 1)
                list
            } else {
                SkeletonRows(label: tr("Citesc memoria și procesele…")).padding(.horizontal, 28)
            }
        }
        .task {
            while !Task.isCancelled {
                await mon.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .appDialog(isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } }),
                   title: { tr("Închizi \(confirmQuit?.name ?? "")?") },
                   message: { tr("Aplicația se închide normal și îți poate cere să salvezi documentele deschise.") },
                   buttons: {
                       let g = confirmQuit
                       return [DialogButton(title: tr("Închide"), kind: .primary) { if let g { quit(g) } }, .cancel()]
                   })
        .appDialog(isPresented: Binding(get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } }),
                   title: { tr("Forțezi închiderea \(confirmForce?.name ?? "")?") },
                   message: { tr("Se oprește imediat. Modificările nesalvate se pierd.") },
                   buttons: {
                       let g = confirmForce
                       return [DialogButton(title: tr("Forțează închiderea"), kind: .destructive) { if let g { mon.forceQuit(g) } }, .cancel()]
                   })
        .appDialog(isPresented: Binding(get: { confirmRestart != nil }, set: { if !$0 { confirmRestart = nil } }),
                   title: { tr("Repornești \(confirmRestart?.name ?? "")?") },
                   message: { tr("Se închide și macOS îl pornește imediat la loc, cu memoria curată. Nu pierzi nimic.") },
                   buttons: {
                       let g = confirmRestart
                       return [DialogButton(title: tr("Repornește"), kind: .primary) { if let g { mon.restart(g) } }, .cancel()]
                   })
        .appSheet(isPresented: Binding(get: { idle != nil }, set: { if !$0 { idle = nil } })) {
            IdleAppsSheet(apps: idle ?? []) { chosen in
                idle = nil
                for g in chosen { mon.quit(g) }
            }
        }
        .appDialog(isPresented: Binding(get: { stuck != nil }, set: { if !$0 { stuck = nil } }),
                   title: { tr("\(stuck?.name ?? "") nu s-a închis") },
                   message: { tr("Poate așteaptă un răspuns de la tine (de exemplu, salvarea unui document) sau nu mai răspunde. Verifică fereastra aplicației sau forțează închiderea; modificările nesalvate se pierd.") },
                   buttons: {
                       let g = stuck
                       return [DialogButton(title: tr("Forțează închiderea"), kind: .destructive) { if let g { mon.forceQuit(g) } }, .cancel()]
                   })
    }

    private func quit(_ g: ProcGroup) {
        mon.quit(g)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if mon.isRunning(g) { stuck = g }
        }
    }

    // MARK: Recomandări

    @ViewBuilder
    private var tipsCard: some View {
        let tips = mon.tips().filter { !dismissed.contains($0.id) }
        if !tips.isEmpty {
            let shown = showAllTips ? tips : Array(tips.prefix(3))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Recomandări", systemImage: "lightbulb").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    if tips.count > 3 {
                        Button(showAllTips ? tr("Mai puține") : tr("Toate (\(tips.count))")) { showAllTips.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentText)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                ForEach(shown) { t in
                    Rectangle().fill(Theme.lineSoft).frame(height: 1)
                    tipRow(t)
                }
            }
            .card(radius: 12)
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
    }

    private func tipRow(_ t: MemoryTip) -> some View {
        let color = t.level == .warn ? Theme.care : Theme.accentText
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: t.icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.16)))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).fontWeight(.semibold)
                Text(t.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch t.action {
            case .quit(let g):
                Button("Închide") { confirmQuit = g }.buttonStyle(SecondaryButtonStyle(height: 28))
            case .restart(let g):
                Button("Repornește") { confirmRestart = g }.buttonStyle(SecondaryButtonStyle(height: 28))
            case .idle:
                Button("Alege…") { idle = mon.idleApps() }.buttonStyle(SecondaryButtonStyle(height: 28))
            case nil:
                EmptyView()
            }
            Button { dismissed.insert(t.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.faint)
                .help(tr("Ascunde recomandarea"))
                .accessibilityLabel(Text("Ascunde recomandarea"))
                .padding(.top, 4)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Carduri

    private func pressure(_ m: MemoryStats) -> (String, Color) {
        switch m.pressure {
        case 4...: (tr("Presiune critică"), Theme.danger)
        case 2...: (tr("Presiune ridicată"), Theme.care)
        default: m.freeFraction < 0.05 ? (tr("Aproape plină"), Theme.care) : (tr("Presiune normală"), Theme.reclaim)
        }
    }

    private func card<C: View>(_ title: LocalizedStringKey, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12, padding: 14)
    }

    private func ramCard(_ m: MemoryStats) -> some View {
        let (label, color) = pressure(m)
        return card("Memorie (RAM)", icon: "memorychip") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(Int64(m.used))).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                Text("din \(Fmt.bytes(Int64(m.total)))").foregroundStyle(Theme.muted)
            }
            SizeBar(fraction: Double(m.used) / Double(max(m.total, 1)), color: color, width: nil)
            HStack {
                Pill(text: label, bg: color.opacity(0.18), fg: color, icon: "circle.fill")
                Spacer()
                Text("\(Fmt.bytes(Int64(m.available))) disponibil").font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
            }
        }
        .help(tr("Aplicații: \(Fmt.bytes(Int64(m.app))) · Rezervată sistemului: \(Fmt.bytes(Int64(m.wired))) · Comprimată: \(Fmt.bytes(Int64(m.compressed))) · Cache de fișiere: \(Fmt.bytes(Int64(m.cached)))"))
    }

    private var cpuCard: some View {
        let color = mon.cpu > 0.9 ? Theme.danger : mon.cpu > 0.7 ? Theme.care : Theme.reclaim
        return card("Procesor (CPU)", icon: "cpu") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((mon.cpu * 100).rounded()))%").font(.system(size: 22, weight: .heavy)).monospacedDigit()
                Text("ocupat").foregroundStyle(Theme.muted)
            }
            SizeBar(fraction: mon.cpu, color: color, width: nil)
            Text("\(ProcessInfo.processInfo.activeProcessorCount) nuclee · \(Int(((1 - mon.cpu) * 100).rounded()))% liber")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
        }
    }

    private func swapCard(_ m: MemoryStats) -> some View {
        card("Swap și comprimare", icon: "arrow.left.arrow.right") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(Int64(m.swapUsed))).font(.system(size: 22, weight: .heavy)).monospacedDigit()
                Text("pe disc").foregroundStyle(Theme.muted)
            }
            SizeBar(fraction: Double(m.compressed) / Double(max(m.total, 1)), color: Theme.care, width: nil)
            Text("\(Fmt.bytes(Int64(m.compressed))) comprimat în RAM")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
        }
        .help(tr("Când RAM-ul nu ajunge, macOS comprimă memoria, apoi o mută pe disc (swap). Mult swap înseamnă un Mac mai lent."))
    }

    // MARK: Listă

    private var list: some View {
        let sorted = mon.groups.sorted { byCPU ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : $0.memory > $1.memory }
        let shown = Array(sorted.prefix(60))
        return VStack(spacing: 0) {
            HStack {
                Text("Aplicații și procese").fontWeight(.bold)
                Text("· doar ale tale").foregroundStyle(Theme.muted)
                Spacer()
                Button {
                    idle = mon.idleApps()
                } label: {
                    Label("Închide aplicațiile nefolosite", systemImage: "moon.zzz")
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
                .help(tr("Aplicații fără nicio fereastră deschisă sau neaduse în față de peste 30 de minute."))
                Picker("", selection: $byCPU) {
                    Text("Memorie").tag(false)
                    Text("CPU").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 24).padding(.vertical, 10)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { g in
                        row(g)
                        Rectangle().fill(Theme.lineSoft).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
    }

    private func row(_ g: ProcGroup) -> some View {
        let maxMem = Double(max(mon.groups.map(\.memory).max() ?? 1, 1))
        return HStack(spacing: 14) {
            Group {
                if let app = g.appPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable()
                } else {
                    Image(systemName: "terminal").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ground))
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.name).fontWeight(.semibold).lineLimit(1)
                Text(g.pids.count > 1 ? tr("\(g.pids.count) procese") : "PID \(g.pids[0])")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(Int64(g.memory))).fontWeight(.bold).monospacedDigit()
                SizeBar(fraction: (Double(g.memory) / maxMem).squareRoot(), color: Theme.reclaim, width: 100)
            }
            .frame(width: 120, alignment: .trailing)
            Text(String(format: "%.0f%%", g.cpu))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(g.cpu > 80 ? Theme.care : Theme.text)
                .frame(width: 56, alignment: .trailing)
            Button("Închide") { confirmQuit = g }
                .buttonStyle(SecondaryButtonStyle(height: 28))
                .disabled(!g.canQuit)
                .help(g.canQuit ? "" : tr("Proces al sistemului: nu se închide de aici."))
        }
        .padding(.horizontal, 24).frame(height: 56)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Închide") { confirmQuit = g }.disabled(!g.canQuit)
            Button("Forțează închiderea") { confirmForce = g }.disabled(!g.canQuit)
            if let app = g.appPath {
                Button("Arată în Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
            }
        }
    }
}

/// Alegerea aplicațiilor nefolosite de închis; toate bifate implicit.
struct IdleAppsSheet: View {
    let apps: [SystemMonitor.IdleApp]
    let done: ([ProcGroup]) -> Void
    @State private var off: Set<String> = []

    var body: some View {
        let chosen = apps.filter { !off.contains($0.id) }.map(\.group)
        let bytes = chosen.reduce(UInt64(0)) { $0 + $1.memory }
        VStack(alignment: .leading, spacing: 14) {
            Text("Închizi aplicațiile nefolosite?").font(.system(size: 17, weight: .bold))
            if apps.isEmpty {
                Text("Nu am găsit aplicații nefolosite: toate au ferestre deschise și le-ai folosit recent.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { done([]) }.buttonStyle(PrimaryButtonStyle(height: 36)).keyboardShortcut(.defaultAction) }
            } else {
                Text("Se închid normal: dacă au documente nesalvate, îți cer confirmarea.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                            row(a)
                        }
                    }
                    .card(radius: 10)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Anulează") { done([]) }.buttonStyle(SecondaryButtonStyle(height: 36)).keyboardShortcut(.cancelAction)
                    Button(tr("Închide \(chosen.count) · ~\(Fmt.bytes(Int64(bytes)))")) { done(chosen) }
                        .buttonStyle(PrimaryButtonStyle(height: 36)).keyboardShortcut(.defaultAction)
                        .disabled(chosen.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func row(_ a: SystemMonitor.IdleApp) -> some View {
        let on = !off.contains(a.id)
        let flip = { if on { off.insert(a.id) } else { off.remove(a.id) } }
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { on }, set: { _ in flip() }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(Text(a.group.name))
            if let app = a.group.appPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(a.group.name).fontWeight(.semibold).lineLimit(1)
                Text(a.reason).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(Fmt.bytes(Int64(a.group.memory))).fontWeight(.semibold).monospacedDigit()
        }
        .padding(.horizontal, 14).frame(height: 50)
        .togglesCheckbox(flip)
    }
}
