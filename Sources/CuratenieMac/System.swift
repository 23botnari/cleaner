import Foundation
import AppKit

// MARK: - Procese externe

struct ShellResult {
    let code: Int32
    let out: String
    let err: String
}

enum Shell {
    /// Rulează un binar cu cale absolută (aplicațiile pornite din Finder au un PATH minimal).
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 1800) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ShellResult(code: -1, out: "", err: error.localizedDescription)
        }
        var errData = Data()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errRead.leave()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        errRead.wait()
        return ShellResult(code: p.terminationStatus,
                           out: String(decoding: outData, as: UTF8.self),
                           err: String(decoding: errData, as: UTF8.self))
    }
}

/// Rulează cod blocant pe un fir de fundal fără să ocupe pool-ul cooperativ Swift.
func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
    }
}

// MARK: - Căi și reguli de protecție

enum Paths {
    static let home: String = NSHomeDirectory()
    static let realHome: String = realpath(home)
    /// Folderul temporar al utilizatorului (/var/folders/…/T), unde stau cache-urile Metro.
    static let realTmp: String = realpath(NSTemporaryDirectory())

    static func hp(_ parts: String...) -> String {
        parts.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func join(_ base: String, _ parts: String...) -> String {
        parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func realpath(_ p: String) -> String {
        if let r = Darwin.realpath(p, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        return (p as NSString).standardizingPath
    }

    static func lexists(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0
    }

    static func isSymlink(_ p: String) -> Bool {
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func existing(_ paths: [String]) -> [String] { paths.filter(lexists) }

    static func children(_ dir: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { join(dir, $0) }
    }

    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }

    static func relative(_ full: String, to base: String = realHome) -> String {
        if full == base { return "." }
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
    }

    /// Calea cu folderul-părinte rezolvat (symlink-ul final nu e urmat), ca în scriptul de referință.
    static func resolvedParent(_ p: String) -> String {
        let ap = ((p as NSString).isAbsolutePath ? p : join(FileManager.default.currentDirectoryPath, p))
        let std = (ap as NSString).standardizingPath
        return join(realpath((std as NSString).deletingLastPathComponent), (std as NSString).lastPathComponent)
    }

    static func underHome(_ real: String) -> Bool {
        real == realHome || real.hasPrefix(realHome + "/")
    }

    /// Foldere care nu se șterg niciodată, indiferent de cerere.
    static let protected: Set<String> = Set([
        home, hp("Library"), hp("Library", "Application Support"), hp("Library", "Group Containers"),
        hp("Library", "Containers"), hp("Library", "Preferences"), hp("Library", "Keychains"),
        hp("Library", "Mail"), hp("Library", "Messages"), hp("Library", "Mobile Documents"),
        hp("Library", "Developer"), hp(".ssh"), hp(".gnupg"), hp(".Trash"),
        hp("Library", "Caches"), hp("Library", "Logs"), hp("Library", "CloudStorage"),
    ].map(realpath))

    /// Subarbori sensibili: nimic din interiorul lor nu se atinge.
    static let protectedTrees: [String] = [
        hp(".ssh"), hp(".gnupg"), hp("Library", "Keychains"), hp("Library", "Mail"),
        hp("Library", "Messages"), hp("Library", "Mobile Documents"), hp("Library", "CloudStorage"),
    ].map(realpath)

    static func deletable(_ p: String) -> Bool {
        let full = resolvedParent(p)
        if full.hasPrefix(realTmp + "/") { return true }
        guard underHome(full), full != realHome, !protected.contains(full) else { return false }
        if protectedTrees.contains(where: { full.hasPrefix($0 + "/") }) { return false }
        let rel = relative(full)
        // Foldere vizibile direct în home (Desktop, Documents etc.) rămân neatinse.
        if !rel.contains("/") && !rel.hasPrefix(".") { return false }
        return true
    }
}

// MARK: - Mărimi

enum Sizer {
    /// Mărimea reală pe disc (bytes) a mai multor căi, fără dubluri (hard link-uri numărate o dată).
    static func du(_ paths: [String]) -> Int64 {
        let paths = Paths.existing(paths)
        var total: Int64 = 0
        var i = 0
        while i < paths.count {
            let chunk = Array(paths[i..<min(i + 200, paths.count)])
            let r = Shell.run("/usr/bin/du", ["-skc", "--"] + chunk, timeout: 1200)
            if let last = r.out.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               let kb = Int64(last.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "") {
                total += kb * 1024
            }
            i += 200
        }
        return total
    }

    static func fileSize(_ p: String) -> Int64 {
        var st = stat()
        guard lstat(p, &st) == 0 else { return 0 }
        return Int64(st.st_blocks) * 512
    }
}

enum Procs {
    static func running(_ patterns: [String]) -> Bool {
        // „=nume” caută numele exact al procesului; altfel tiparul se caută în toată linia de comandă.
        patterns.contains { p in
            let args = p.hasPrefix("=") ? ["-x", String(p.dropFirst())] : ["-f", p]
            return Shell.run("/usr/bin/pgrep", args, timeout: 20).code == 0
        }
    }
}

// MARK: - Full Disk Access

enum FullDiskAccess {
    static func granted() -> Bool {
        if ProcessInfo.processInfo.environment["CURATENIE_FORCE_NO_FDA"] != nil { return false }
        if FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil { return true }
        for p in [Paths.hp("Library", "Safari"), Paths.hp("Library", "Mail"), Paths.hp("Library", "Messages")]
        where Paths.lexists(p) {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: p)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Fmt {
    static func bytes(_ b: Int64?) -> String {
        guard let b else { return "…" }
        if b == 0 { return "0 KB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: b)
    }
}
