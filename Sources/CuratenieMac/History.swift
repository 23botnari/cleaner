import SwiftUI

/// O curățare făcută din aplicație.
struct HistoryEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case clean, trash, uninstall, cache, leftovers

        var icon: String {
            switch self {
            case .clean: "sparkles"
            case .trash: "trash"
            case .uninstall: "square.grid.2x2"
            case .cache: "internaldrive"
            case .leftovers: "shippingbox"
            }
        }
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    let bytes: Int64
    /// Mutat la Coș: spațiul se eliberează abia după golirea Coșului.
    let trashed: Bool
}

/// Istoricul curățărilor, păstrat local (ultimele 300).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let key = "cleanHistory"
    private static let limit = 300

    @Published private(set) var entries: [HistoryEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
    }

    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    func record(_ kind: HistoryEntry.Kind, title: String, detail: String = "", bytes: Int64, trashed: Bool = false) {
        guard bytes > 0 else { return }
        entries.insert(HistoryEntry(date: Date(), kind: kind, title: title, detail: detail, bytes: bytes, trashed: trashed), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.bytes(store.total)).font(.system(size: 26, weight: .heavy)).monospacedDigit()
                Text("în \(store.entries.count) curățări").foregroundStyle(Theme.muted)
                Spacer()
                Button("Șterge istoricul") { confirmingClear = true }
                    .buttonStyle(SecondaryButtonStyle(height: 30))
                    .disabled(store.entries.isEmpty)
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            if store.entries.isEmpty {
                Text("Încă nu ai curățat nimic din aplicație.").foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                            row(e)
                        }
                    }
                    .card()
                    .padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
        }
        .appDialog(isPresented: $confirmingClear, title: { tr("Ștergi istoricul?") },
                   message: { tr("Se șterge doar lista de aici; fișierele curățate nu sunt afectate.") },
                   buttons: { [DialogButton(title: tr("Șterge istoricul"), kind: .destructive) { store.clear() }, .cancel()] })
    }

    private func row(_ e: HistoryEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: e.kind.icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.safeBg))
                .foregroundStyle(Theme.safeFg)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).fontWeight(.semibold).lineLimit(1)
                if !e.detail.isEmpty {
                    Text(e.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if e.trashed { Pill(text: tr("La Coș"), bg: Theme.careBg, fg: Theme.careFg, icon: "trash") }
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.bytes(e.bytes)).fontWeight(.bold).monospacedDigit()
                Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 16).frame(height: 58)
    }
}
