import SwiftUI
import AppKit

// MARK: - Model

struct StartupItem: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let label: String
    let program: String?
    /// system (LaunchDaemons) sau gui/<uid> (LaunchAgents).
    let domain: String
    var disabled: Bool
    var loaded: Bool

    var isUser: Bool { Paths.underHome(Paths.resolvedParent(path)) }
    var needsAdmin: Bool { !isUser }

    var scope: String {
        if path.hasPrefix("/Library/LaunchDaemons/") { return tr("Daemon sistem") }
        return isUser ? tr("Agent utilizator") : tr("Agent toți utilizatorii")
    }

    var programMissing: Bool { program.map(LeftoverScanner.missing) ?? true }
}

enum StartupScanner {
    static let uid = getuid()

    /// `launchctl print-disabled <domain>` → etichetele dezactivate.
    static func disabledLabels(_ domain: String) -> Set<String> {
        let r = Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 20)
        var out = Set<String>()
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "\"")
            guard parts.count >= 3 else { continue }
            let state = parts[2]
            if state.contains("disabled") || state.contains("true") { out.insert(String(parts[1])) }
        }
        return out
    }

    static func scan() -> [StartupItem] {
        let user = "gui/\(uid)"
        let disabled = ["system": disabledLabels("system"), user: disabledLabels(user)]
        return LeftoverScanner.launchPlists().compactMap { p -> StartupItem? in
            guard let label = p.label else { return nil }
            let domain = p.path.hasPrefix("/Library/LaunchDaemons/") ? "system" : user
            let loaded = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10).code == 0
            return StartupItem(path: p.path, label: label, program: p.program, domain: domain,
                               disabled: disabled[domain]?.contains(label) ?? false, loaded: loaded)
        }
        .sorted { a, b in a.disabled != b.disabled ? !a.disabled : a.label.localizedStandardCompare(b.label) == .orderedAscending }
    }

    /// Comenzile exacte pentru oprire / pornire. `disable` e persistent (rămâne oprit și după restart).
    static func commands(_ item: StartupItem, enable: Bool) -> [String] {
        let q = LeftoverActions.shq
        let target = "\(item.domain)/\(item.label)"
        return enable
            ? ["/bin/launchctl enable \(q(target))", "/bin/launchctl bootstrap \(q(item.domain)) \(q(item.path)) 2>/dev/null; true"]
            : ["/bin/launchctl disable \(q(target))", "/bin/launchctl bootout \(q(target)) 2>/dev/null; true"]
    }

    static func apply(_ item: StartupItem, enable: Bool) -> String? {
        let cmd = commands(item, enable: enable).joined(separator: "; ")
        let r = item.needsAdmin
            ? Shell.run("/usr/bin/osascript", LeftoverActions.osascriptArgs(LeftoverActions.adminScript, [cmd]), timeout: 300)
            : Shell.run("/bin/sh", ["-c", cmd], timeout: 60)
        guard r.code != 0 else { return nil }
        let msg = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? tr("Comanda a eșuat.") : String(msg.prefix(300))
    }
}

// MARK: - Store

@MainActor
final class StartupStore: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var loading = false
    @Published var busy: String?
    private var generation = 0

    func scan() {
        generation += 1
        let gen = generation
        loading = true
        Task {
            let found = await offMain { StartupScanner.scan() }
            guard gen == generation else { return }
            items = found
            loading = false
        }
    }

    func scanIfNeeded() {
        if generation == 0 { scan() }
    }

    func toggle(_ item: StartupItem) async -> String? {
        busy = item.id
        defer { busy = nil }
        let enable = item.disabled
        let err = await offMain { StartupScanner.apply(item, enable: enable) }
        scan()
        return err
    }
}

// MARK: - View

struct StartupView: View {
    @ObservedObject var store: StartupStore
    @State private var confirm: StartupItem?
    @State private var message: (title: String, body: String)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Servicii pornite automat (LaunchAgents / LaunchDaemons). Dezactivarea e persistentă și reversibilă.")
                    .foregroundStyle(Theme.muted).font(.system(size: 13))
                Spacer()
                Button("Login Items în Setări…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            if store.loading && store.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { i, it in
                            if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                            row(it)
                        }
                    }
                    .card()
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
        }
        .alert(item: Binding(get: { confirm.map(IdentifiedStartup.init) }, set: { confirm = $0?.item })) { w in
            let it = w.item
            let enable = it.disabled
            return Alert(
                title: Text(enable ? tr("Activează „\(it.label)”?") : tr("Dezactivează „\(it.label)”?")),
                message: Text((it.needsAdmin ? tr("Cere parola de administrator.\n\n") : "")
                    + StartupScanner.commands(it, enable: enable).joined(separator: "\n")),
                primaryButton: enable ? .default(Text("Activează")) { run(it) } : .destructive(Text("Dezactivează")) { run(it) },
                secondaryButton: .cancel(Text("Anulează")))
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message?.body ?? "") }
    }

    @ViewBuilder
    private func row(_ it: StartupItem) -> some View {
        HStack(spacing: 14) {
            Circle().fill(it.disabled ? Theme.used : it.loaded ? Theme.reclaim : Theme.care)
                .frame(width: 8, height: 8)
                .help(it.disabled ? tr("Dezactivat") : it.loaded ? tr("Rulează / încărcat") : tr("Activ, neîncărcat acum"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(it.label).fontWeight(.semibold).lineLimit(1)
                    Pill(text: it.scope, bg: Theme.lineSoft, fg: Theme.muted)
                    if it.programMissing { Pill(text: tr("program lipsă"), bg: Theme.careBg, fg: Theme.careFg) }
                }
                Text(it.program ?? tr("fără program"))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Arată în Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) }
                .buttonStyle(SecondaryButtonStyle(height: 30))
            Group {
                if store.busy == it.id {
                    ProgressView().controlSize(.small)
                } else if it.disabled {
                    Button("Activează") { confirm = it }.buttonStyle(PrimaryButtonStyle(height: 30))
                } else {
                    Button("Dezactivează") { confirm = it }.buttonStyle(SecondaryButtonStyle(height: 30))
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .opacity(it.disabled ? 0.65 : 1)
    }

    private func run(_ it: StartupItem) {
        Task {
            if let err = await store.toggle(it) { message = (tr("Nu am putut schimba „\(it.label)”"), err) }
        }
    }
}

struct IdentifiedStartup: Identifiable {
    let item: StartupItem
    var id: String { item.id }
}
