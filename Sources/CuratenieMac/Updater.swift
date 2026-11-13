import Foundation
import AppKit
import Security

/// O versiune publicată pe GitHub Releases.
struct AppRelease: Equatable, Sendable {
    let version: String
    let notes: String
    /// DMG-ul atașat release-ului (nil = se poate doar deschide pagina).
    let dmg: URL?
    let page: URL
}

struct UpdateError: Error {
    let message: String
}

/// Actualizări din GitHub Releases: verifică, descarcă DMG-ul, îi verifică semnătura și înlocuiește aplicația.
@MainActor
final class UpdateStore: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(AppRelease)
        case downloading(AppRelease, Double)
        case installing(AppRelease)
        case failed(String)
    }

    static let repo = "23botnari/cleaner"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let autoCheckKey = "updateAutoCheck"
    static let skippedKey = "updateSkippedVersion"
    private static let lastCheckKey = "updateLastCheck"

    @Published var state: State = .idle
    /// Ultima versiune mai nouă găsită (rămâne și cât se descarcă sau după o eroare).
    @Published var release: AppRelease?
    private var progressObservation: NSKeyValueObservation?
    private var checkedThisLaunch = false

    /// CURATENIE_VERSION simulează o versiune mai veche (diagnostic).
    static var currentVersion: String {
        ProcessInfo.processInfo.environment["CURATENIE_VERSION"]
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }

    var busy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Verificarea automată: la fiecare pornire, apoi cel mult o dată la 24 h; doar dacă e pornită din Setări.
    func checkIfDue() {
        guard Self.autoCheck, !busy else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard !checkedThisLaunch || Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        checkedThisLaunch = true
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !busy else { return }
        state = .checking
        do {
            let found = try await Self.fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            guard Self.isNewer(found.version, than: Self.currentVersion) else {
                release = nil
                state = manual ? .upToDate : .idle
                return
            }
            if !manual, UserDefaults.standard.string(forKey: Self.skippedKey) == found.version {
                state = .idle
                return
            }
            release = found
            state = .available(found)
        } catch {
            state = manual ? .failed(tr("Nu am putut verifica actualizările: \(Self.describe(error))")) : .idle
        }
    }

    func skip(_ r: AppRelease) {
        UserDefaults.standard.set(r.version, forKey: Self.skippedKey)
        release = nil
        state = .idle
    }

    func openPage(_ r: AppRelease) {
        NSWorkspace.shared.open(r.page)
    }

    func install(_ r: AppRelease) {
        guard !busy else { return }
        guard let dmg = r.dmg else { openPage(r); return }
        state = .downloading(r, 0)
        Task {
            do {
                let file = try await download(dmg) { [weak self] p in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(r, p) }
                    }
                }
                state = .installing(r)
                let bundle = Bundle.main.bundlePath
                let staged = try await offMain { Self.stage(dmg: file.path, over: bundle) }.get()
                if !Self.swapAndRelaunch(bundle: bundle, staged: staged) {
                    state = .failed(tr("Nu am putut porni instalarea."))
                }
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    // MARK: - Rețea

    private static func fetchLatest() async throws -> AppRelease {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CleanerMacOS-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let page = (o["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError(message: tr("Răspuns neașteptat de la GitHub."))
        }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        return AppRelease(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                          notes: (o["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                          dmg: dmg, page: page)
    }

    private func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        defer { progressObservation = nil }
        return try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: UpdateError(message: tr("Descărcarea a eșuat.")))
                    return
                }
                // Fișierul temporar dispare la ieșirea din handler: îl mut imediat.
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("CleanerUpdate-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    // MARK: - Verificare și instalare

    /// Versiunea nouă trebuie să satisfacă „designated requirement” al aplicației care rulează:
    /// același bundle ID, semnat de aceeași identitate. Un build ad-hoc nu trece niciodată.
    nonisolated static func signedLikeMe(_ appPath: String) -> Bool {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return false }
        var meStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement else { return false }
        var other: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &other) == errSecSuccess, let other else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidityWithErrors(other, flags, requirement, nil) == errSecSuccess
    }

    /// Montează DMG-ul, copiază aplicația lângă cea instalată și îi verifică semnătura. Întoarce calea copiei.
    nonisolated static func stage(dmg: String, over bundle: String) -> Result<String, UpdateError> {
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: dmg) }
        let parent = (bundle as NSString).deletingLastPathComponent
        guard bundle.hasSuffix(".app"), fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: bundle) else {
            return .failure(UpdateError(message: tr("Nu pot scrie în \(parent). Descarcă versiunea nouă manual.")))
        }
        let mount = Paths.join(NSTemporaryDirectory(), "CleanerUpdate-\(UUID().uuidString)")
        let attach = Shell.run("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount], timeout: 120)
        guard attach.code == 0 else {
            return .failure(UpdateError(message: tr("Nu am putut deschide imaginea descărcată.")))
        }
        defer { Shell.run("/usr/bin/hdiutil", ["detach", mount, "-force"], timeout: 60) }
        guard let app = Paths.children(mount).first(where: { $0.hasSuffix(".app") && !Paths.isSymlink($0) }) else {
            return .failure(UpdateError(message: tr("Imaginea descărcată nu conține aplicația.")))
        }
        let staged = Paths.join(parent, ".CleanerUpdate-\(UUID().uuidString).app")
        guard Shell.run("/usr/bin/ditto", [app, staged], timeout: 300).code == 0 else {
            try? fm.removeItem(atPath: staged)
            return .failure(UpdateError(message: tr("Nu am putut copia versiunea nouă.")))
        }
        let sameID = Bundle(path: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier
        guard sameID, signedLikeMe(staged) else {
            try? fm.removeItem(atPath: staged)
            return .failure(UpdateError(message: tr("Semnătura versiunii descărcate nu se potrivește cu a aplicației instalate. Nu am instalat nimic.")))
        }
        return .success(staged)
    }

    /// După ce aplicația se închide: versiunea veche e pusă deoparte, cea nouă îi ia locul și pornește.
    /// Dacă mutarea eșuează, versiunea veche revine la loc.
    private static func swapAndRelaunch(bundle: String, staged: String) -> Bool {
        let backup = Paths.join((bundle as NSString).deletingLastPathComponent, ".CleanerOld-\(UUID().uuidString).app")
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        if /bin/mv "$2" "$4" && /bin/mv "$3" "$2"; then
          /bin/rm -rf "$4"
        else
          [ -d "$2" ] || /bin/mv "$4" "$2"
          /bin/rm -rf "$3"
        fi
        /usr/bin/open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), bundle, staged, backup]
        do { try p.run() } catch {
            try? FileManager.default.removeItem(atPath: staged)
            return false
        }
        AppDelegate.quitting = true
        NSApp.terminate(nil)
        return true
    }
}
