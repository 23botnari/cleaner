import Foundation
import CryptoKit

extension Targets {
    static let brewCLI: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// „…would free approximately 222MB of disk space.” → bytes.
    static func parseBrewFree(_ out: String) -> Int64 {
        guard let r = out.range(of: "approximately ") else { return 0 }
        return parseDockerSize(String(out[r.upperBound...]))
    }

    static func homebrewTargets() -> [CleanTarget] {
        guard let brew = brewCLI else { return [] }
        let r = Shell.run(brew, ["cleanup", "-n", "-s", "--prune=all"], timeout: 120)
        return [CleanTarget(
            id: "brew", group: "Dezvoltare", name: "Homebrew: versiuni vechi și descărcări",
            desc: "Rulează „brew cleanup -s --prune=all”: șterge versiunile vechi ale pachetelor și kit-urile descărcate. Versiunile curente rămân.",
            cmds: [[brew, "cleanup", "-s", "--prune=all"]],
            fixedSize: parseBrewFree(r.out + r.err))]
    }

    static func devCacheTargets() -> [CleanTarget] {
        let g = "Dezvoltare"
        let C = Paths.hp("Library", "Caches")
        let tmp = Paths.realTmp
        return [
            CleanTarget(id: "yarn", group: g, name: "Yarn: cache",
                        desc: "Pachete descărcate de Yarn. Se redescarcă la următorul yarn install.",
                        resolve: { Paths.existing([Paths.join(C, "Yarn"), Paths.hp(".yarn", "berry", "cache")]) }),
            CleanTarget(id: "bun", group: g, name: "Bun: cache",
                        desc: "Pachete descărcate de Bun. Se redescarcă la următorul bun install.",
                        resolve: { Paths.existing([Paths.hp(".bun", "install", "cache")]) }),
            CleanTarget(id: "cocoapods", group: g, name: "CocoaPods: cache",
                        desc: "Pod-uri descărcate. Se redescarcă la următorul pod install.",
                        resolve: { Paths.existing([Paths.join(C, "CocoaPods")]) }),
            CleanTarget(id: "pip", group: g, name: "Python: cache pip / uv",
                        desc: "Pachete Python descărcate. Se redescarcă la următoarea instalare.",
                        resolve: { Paths.existing([Paths.join(C, "pip"), Paths.hp(".cache", "uv"), Paths.join(C, "uv")]) }),
            CleanTarget(id: "metro", group: g, name: "React Native / Expo: cache Metro",
                        desc: "Cache-ul bundler-ului Metro din folderul temporar. Se reface la următorul start (echivalent cu --clear).",
                        procs: ["expo start", "react-native start", "@expo/cli"], appName: "serverul Metro / Expo",
                        resolve: { Paths.children(tmp).filter { p in
                            let n = (p as NSString).lastPathComponent
                            return n.hasPrefix("metro-") || n.hasPrefix("haste-map-") || n.hasPrefix("react-native-packager-cache-")
                        } }),
        ]
    }

    static func iosDeviceTargets() -> [CleanTarget] {
        let g = "iPhone / iPad"
        var L: [CleanTarget] = []
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        for b in Paths.children(Paths.hp("Library", "Application Support", "MobileSync", "Backup")) where Paths.isDir(b) {
            let info = NSDictionary(contentsOfFile: Paths.join(b, "Info.plist"))
            let device = info?["Device Name"] as? String ?? "dispozitiv necunoscut"
            let date = (info?["Last Backup Date"] as? Date).map { df.string(from: $0) } ?? "?"
            L.append(CleanTarget(
                id: "iosbackup:" + b, group: g, name: "Backup \(device) (\(date))",
                desc: "Backup local făcut din Finder. Șterge-l doar dacă ai backup în iCloud sau unul mai nou; altfel datele din el se pierd.",
                risk: .care, procs: ["AMPDeviceDiscoveryAgent", "AMPDevicesAgent"], appName: "sincronizarea iPhone (deconectează telefonul)",
                resolve: { Paths.existing([b]) }))
        }
        L.append(CleanTarget(
            id: "ipsw", group: g, name: "Firmware iOS descărcat (.ipsw)",
            desc: "Imagini de sistem pentru restaurarea iPhone / iPad. Se descarcă din nou la nevoie.",
            resolve: {
                let dirs = ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"].map { Paths.hp("Library", "iTunes", $0) }
                return (dirs + [Paths.hp("Downloads")]).flatMap(Paths.children).filter { $0.lowercased().hasSuffix(".ipsw") }
            }))
        return L
    }

    /// Fișiere din ~/Downloads (primul nivel) cu extensia dată, adăugate acum mai mult de `days` zile.
    static func oldDownloads(_ exts: Set<String>, days: Double) -> [String] {
        let cutoff = Date().addingTimeInterval(-days * 24 * 3600)
        return Paths.children(Paths.hp("Downloads")).filter { p in
            guard exts.contains((p as NSString).pathExtension.lowercased()), !Paths.isSymlink(p) else { return false }
            let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            guard let d = v?.addedToDirectoryDate ?? v?.creationDate else { return false }
            return d < cutoff
        }
    }

    static func downloadsTargets() -> [CleanTarget] {
        let g = "Descărcări"
        return [
            CleanTarget(id: "dl-installers", group: g, name: "Kit-uri de instalare mai vechi de 5 zile",
                        desc: "Fișiere .dmg, .pkg și .xip din Descărcări. Aplicațiile instalate nu sunt atinse. Se mută la Coș.",
                        trash: true,
                        resolve: { oldDownloads(["dmg", "pkg", "mpkg", "xip"], days: 5) }),
            CleanTarget(id: "dl-archives", group: g, name: "Arhive mai vechi de 5 zile",
                        desc: "Fișiere .zip, .rar, .7z, .tar.gz din Descărcări. Verifică să le fi dezarhivat dacă ai nevoie de conținut. Se mută la Coș.",
                        risk: .care, trash: true,
                        resolve: { oldDownloads(["zip", "rar", "7z", "tgz", "gz", "bz2", "xz"], days: 5) }),
        ]
    }

    static func timeMachineTargets() -> [CleanTarget] {
        let r = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30)
        let snaps = r.out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
        guard !snaps.isEmpty else { return [] }
        // Mărimea exactă nu se poate citi fără root; spațiul „purgeable” al volumului e cea mai bună estimare.
        let v = try? URL(fileURLWithPath: Paths.home).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let purgeable = (v?.volumeAvailableCapacityForImportantUsage ?? 0) - Int64(v?.volumeAvailableCapacity ?? 0)
        let cmd = "/usr/bin/tmutil deletelocalsnapshots /"
        return [CleanTarget(
            id: "tmsnap", group: "Sistem și altele", name: "Time Machine: \(snaps.count) snapshot-uri locale",
            desc: "Copii locale păstrate de Time Machine până la următorul backup pe disc. Backup-urile de pe discul extern nu sunt atinse. "
                + "Mărimea e estimată (spațiu „purgeable”). Cere parola de administrator.",
            risk: .care,
            cmds: [["/usr/bin/osascript", "-e", "on run argv", "-e", "do shell script (item 1 of argv) with administrator privileges",
                    "-e", "end run", cmd]],
            fixedSize: max(purgeable, 1))]
    }

    static func browserTargets() -> [CleanTarget] {
        let AS = Paths.hp("Library", "Application Support")
        let C = Paths.hp("Library", "Caches")
        let chromium: [(id: String, name: String, proc: String, support: String, caches: [String])] = [
            ("brave", "Brave", "Brave Browser.app/Contents/MacOS", "BraveSoftware/Brave-Browser", ["BraveSoftware/Brave-Browser"]),
            ("chrome", "Chrome", "Google Chrome.app/Contents/MacOS", "Google/Chrome", ["Google/Chrome"]),
            ("edge", "Edge", "Microsoft Edge.app/Contents/MacOS", "Microsoft Edge", ["Microsoft Edge"]),
        ]
        let perProfile = ["Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache",
                          "Service Worker/CacheStorage", "Service Worker/ScriptCache"]
        var L: [CleanTarget] = chromium.map { b in
            CleanTarget(
                id: "browser-" + b.id, group: "Browsere", name: "\(b.name): cache",
                desc: "Imagini și fișiere ale site-urilor, păstrate ca paginile să se încarce mai repede. Istoricul, parolele, tab-urile și login-urile rămân.",
                procs: [b.proc], appName: b.name,
                resolve: {
                    let profiles = Paths.children(Paths.join(AS, b.support)).filter { p in
                        let n = (p as NSString).lastPathComponent
                        return n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile"
                    }
                    return Paths.existing(b.caches.map { Paths.join(C, $0) }
                        + profiles.flatMap { p in perProfile.map { Paths.join(p, $0) } })
                })
        }
        L.append(CleanTarget(
            id: "browser-firefox", group: "Browsere", name: "Firefox: cache",
            desc: "Cache-ul paginilor. Istoricul, parolele și login-urile rămân.",
            procs: ["firefox"], appName: "Firefox",
            resolve: { Paths.existing([Paths.join(C, "Firefox", "Profiles")]) }))
        L.append(CleanTarget(
            id: "browser-safari", group: "Browsere", name: "Safari: cache",
            desc: "Cache-ul paginilor (necesită Full Disk Access). Istoricul și login-urile rămân.",
            procs: ["Safari.app/Contents/MacOS"], appName: "Safari",
            resolve: { Paths.existing([Paths.join(C, "com.apple.Safari"), Paths.join(C, "com.apple.WebKit.Networking")]) }))
        return L
    }

    /// Fișiere identice (≥ 1 MB) în Descărcări, Desktop și Documente. Păstrează cea mai veche copie, restul la Coș.
    static func duplicateTargets() -> [CleanTarget] {
        let fm = FileManager.default
        var bySize: [Int64: [String]] = [:]
        let skipDirs: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", "build", ".build"]

        func walk(_ dir: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") && !skipDirs.contains(n) {
                let p = Paths.join(dir, n)
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                // Fișierele din iCloud nedescărcate (dataless) nu se citesc: ar porni descărcarea.
                if st.st_flags & 0x4000_0000 != 0 { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    // Pachetele (.app, .photoslibrary…) au extensie: nu intrăm în ele.
                    if depth < 6, (n as NSString).pathExtension.isEmpty { walk(p, depth: depth + 1) }
                case S_IFREG where st.st_size >= 1_000_000:
                    bySize[Int64(st.st_size), default: []].append(p)
                default: break
                }
            }
        }
        for root in ["Downloads", "Desktop", "Documents"] { walk(Paths.hp(root), depth: 0) }

        func hash(_ p: String, limit: Int?) -> String? {
            guard let h = FileHandle(forReadingAtPath: p) else { return nil }
            defer { try? h.close() }
            var sha = SHA256()
            var read = 0
            while true {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                sha.update(data: chunk)
                read += chunk.count
                if let limit, read >= limit { break }
            }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var groups: [(size: Int64, files: [String])] = []
        for (size, files) in bySize where files.count > 1 {
            // Întâi primul MB, apoi tot fișierul doar pentru cele care încă se potrivesc.
            let quick = Dictionary(grouping: files) { hash($0, limit: 1 << 20) ?? UUID().uuidString }
            for cand in quick.values where cand.count > 1 {
                let full = Dictionary(grouping: cand) { hash($0, limit: nil) ?? UUID().uuidString }
                for same in full.values where same.count > 1 { groups.append((size, same)) }
            }
        }
        func created(_ p: String) -> Date {
            (try? fm.attributesOfItem(atPath: p)[.creationDate] as? Date) ?? .distantFuture
        }
        return groups.sorted { $0.size * Int64($0.files.count - 1) > $1.size * Int64($1.files.count - 1) }.prefix(200).map { g in
            let sorted = g.files.sorted { created($0) < created($1) }
            let keep = sorted[0], extra = Array(sorted.dropFirst())
            return CleanTarget(
                id: "dup:" + keep, group: "Fișiere duplicate",
                name: "„\((keep as NSString).lastPathComponent)” — \(extra.count) \(extra.count == 1 ? "copie" : "copii")",
                desc: "Păstrez originalul (cel mai vechi): \(Paths.relative(keep)). La Coș: " + extra.map { Paths.relative($0) }.joined(separator: ", "),
                risk: .care, trash: true,
                resolve: { Paths.existing(extra) })
        }
    }
}
