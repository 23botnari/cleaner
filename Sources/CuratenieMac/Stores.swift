import Foundation
import AppKit

struct CleanResult: Sendable {
    let freed: Int64
    let size: Int64
    let errors: [String]
}

// MARK: - Recomandări

@MainActor
final class RecommendationsStore: ObservableObject {
    @Published var targets: [CleanTarget] = []
    @Published var sizes: [String: Int64] = [:]
    @Published var scanning = false
    @Published var scanningNodeModules = false
    @Published var busy: Set<String> = []
    @Published var done: Set<String> = []
    /// Bifele din Recomandări; implicit tot ce e sigur.
    @Published var selected: Set<String> = []

    @Published var diskTotal: Int64 = 0
    @Published var diskFree: Int64 = 0

    private var generation = 0
    private(set) var lastScan: Date?

    var reclaimable: Int64 {
        targets.reduce(0) { $0 + ($1.overlap ? 0 : (sizes[$1.id] ?? 0)) }
    }

    var pendingCount: Int { targets.filter { sizes[$0.id] == nil }.count }

    /// Grupuri sortate descrescător după total, elementele din grup la fel.
    var groups: [(name: String, total: Int64, items: [CleanTarget])] {
        var order: [String] = []
        var byGroup: [String: [CleanTarget]] = [:]
        for t in targets {
            if byGroup[t.group] == nil { order.append(t.group) }
            byGroup[t.group, default: []].append(t)
        }
        return order.map { g in
            let items = byGroup[g]!.enumerated().sorted { a, b in
                let sa = sizes[a.element.id] ?? -1, sb = sizes[b.element.id] ?? -1
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
            let total = items.reduce(Int64(0)) { $0 + ($1.overlap ? 0 : (sizes[$1.id] ?? 0)) }
            return (g, total, items)
        }
        .enumerated()
        .sorted { a, b in a.element.total != b.element.total ? a.element.total > b.element.total : a.offset < b.offset }
        .map(\.element)
    }

    /// Ținte sigure, cu mărime, necurățate încă (implicit bifate; „Curăță doar ce e sigur”).
    var safeIDs: [String] {
        targets.filter { $0.risk == .safe && !$0.overlap && (sizes[$0.id] ?? 0) > 0 && !done.contains($0.id) }.map(\.id)
    }

    var selectedTargets: [CleanTarget] {
        targets.filter { selected.contains($0.id) && (sizes[$0.id] ?? 0) > 0 && !done.contains($0.id) }
    }

    var maxSize: Int64 { max(1, sizes.values.max() ?? 1) }

    func refreshDisk() {
        let url = URL(fileURLWithPath: Paths.home)
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
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
        scanningNodeModules = true
        targets = []
        sizes = [:]
        done = []
        selected = []
        refreshDisk()
        Task {
            let found = await offMain {
                (Targets.staticTargets() + Targets.claudeTargets() + Targets.dockerTargets() + Targets.simRuntimeTargets() + Targets.unavailableSimTargets() + Targets.androidTargets()
                    + Targets.homebrewTargets() + Targets.devCacheTargets() + Targets.iosDeviceTargets() + Targets.downloadsTargets()
                    + Targets.timeMachineTargets() + Targets.browserTargets() + Targets.aiModelTargets()).filter(\.isVisible)
            }
            guard gen == generation else { return }
            targets = found
            scanning = false
            let nmTask = Task { await offMain { Targets.projectArtifactTargets() + Targets.duplicateTargets() } }
            await computeSizes(found, gen: gen)
            let nm = await nmTask.value
            guard gen == generation else { return }
            targets += nm
            scanningNodeModules = false
            await computeSizes(nm, gen: gen)
            lastScan = Date()
        }
    }

    private func computeSizes(_ list: [CleanTarget], gen: Int) async {
        await withTaskGroup(of: (String, Int64).self) { group in
            var it = list.makeIterator()
            func next() -> Bool {
                guard let t = it.next() else { return false }
                group.addTask { (t.id, await offMain { t.size() }) }
                return true
            }
            for _ in 0..<5 { _ = next() }
            for await (id, size) in group {
                guard gen == generation else { group.cancelAll(); return }
                sizes[id] = size
                if size > 0, let t = targets.first(where: { $0.id == id }), t.risk == .safe, !t.overlap { selected.insert(id) }
                _ = next()
            }
        }
    }

    /// Verifică dacă aplicația țintei rulează. Întoarce mesajul de refuz sau nil.
    func blocker(for t: CleanTarget) async -> String? {
        let procs = t.procs
        guard !procs.isEmpty else { return nil }
        let running = await offMain { Procs.running(procs) }
        return running ? tr("Închide \(t.appName ?? tr("aplicația")) înainte de curățare.") : nil
    }

    func clean(_ t: CleanTarget) async -> Result<CleanResult, CleanError> {
        busy.insert(t.id)
        defer { busy.remove(t.id) }
        let before = sizes[t.id]
        let res: Result<CleanResult, CleanError> = await offMain {
            Cleaner.clean(t, knownBefore: before)
        }
        if case .success(let r) = res {
            sizes[t.id] = r.size
            if r.errors.isEmpty || r.size == 0 {
                done.insert(t.id)
                selected.remove(t.id)
            }
            if t.fixedSize != nil, r.errors.isEmpty, let i = targets.firstIndex(where: { $0.id == t.id }) {
                targets[i].fixedSize = 0
            }
        }
        refreshDisk()
        return res
    }
}

struct CleanError: Error {
    let message: String
}

enum Cleaner {
    static func clean(_ t: CleanTarget, knownBefore: Int64?) -> Result<CleanResult, CleanError> {
        if Procs.running(t.procs) {
            return .failure(CleanError(message: tr("Închide \(t.appName ?? tr("aplicația")) înainte de curățare.")))
        }
        let before = knownBefore ?? t.size()
        var errors: [String] = []
        let fm = FileManager.default
        for p in t.resolve() {
            guard Paths.deletable(p) else {
                errors.append(tr("Sărit (protejat): \(p)"))
                continue
            }
            do {
                if t.trash {
                    try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                    continue
                }
                try fm.removeItem(atPath: p)
            } catch where t.trash {
                errors.append("\(p): \(error.localizedDescription)")
            } catch {
                // removeItem se oprește la primul fișier blocat; încearcă rm pentru restul.
                var r = Shell.run("/bin/rm", ["-rf", "--", p])
                if r.code != 0 {
                    // Fișiere read-only / cu flag „uchg” (ex. .app-uri descărcate în cache): deblochează și reîncearcă.
                    Shell.run("/usr/bin/chflags", ["-R", "nouchg,noschg", p], timeout: 300)
                    Shell.run("/bin/chmod", ["-R", "u+w", p], timeout: 300)
                    r = Shell.run("/bin/rm", ["-rf", "--", p])
                }
                if r.code != 0 {
                    errors += r.err.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.prefix(3)
                }
            }
        }
        for c in t.cmds {
            guard let exe = c.first else { continue }
            let r = Shell.run(exe, Array(c.dropFirst()))
            if r.code != 0 {
                let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                errors.append(msg.isEmpty ? tr("Comanda a eșuat: \(c.joined(separator: " "))") : String(msg.prefix(300)))
            }
        }
        var after: Int64
        if t.fixedSize != nil {
            after = errors.isEmpty ? 0 : t.fixedSize!
        } else {
            after = t.size()
        }
        if after < 0 { after = 0 }
        return .success(CleanResult(freed: max(0, before - after), size: after, errors: Array(errors.prefix(12))))
    }
}
