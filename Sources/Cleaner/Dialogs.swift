import SwiftUI

// MARK: - Dialoguri proprii (în locul alertelor și foilor de sistem)

struct DialogButton {
    enum Kind { case normal, primary, destructive, cancel }
    let title: String
    var kind: Kind = .normal
    var action: () -> Void = {}

    static func cancel(_ action: @escaping () -> Void = {}) -> DialogButton {
        DialogButton(title: tr("Anulează"), kind: .cancel, action: action)
    }

    static func ok(_ action: @escaping () -> Void = {}) -> DialogButton {
        DialogButton(title: "OK", kind: .primary, action: action)
    }
}

struct AppDialog: Identifiable {
    let id = UUID()
    var title = ""
    var message = ""
    var buttons: [DialogButton] = []
    /// Conținut propriu (fostele „sheet”-uri); are butoanele lui.
    var content: AnyView?
    var onDismiss: () -> Void = {}
}

/// Dialogul afișat peste fereastra principală; unul singur odată.
@MainActor
final class DialogCenter: ObservableObject {
    static let shared = DialogCenter()
    @Published var current: AppDialog?

    func choose(_ b: DialogButton, in d: AppDialog) {
        b.action()
        d.onDismiss()
        if current?.id == d.id { current = nil }
    }

    /// Esc / click în afara dialogului: ca „Anulează”, dacă există; un dialog doar cu OK se închide.
    /// Dialogurile cu conținut propriu se închid doar din butoanele lor.
    func dismiss(_ d: AppDialog) {
        if let cancel = d.buttons.first(where: { $0.kind == .cancel }) {
            choose(cancel, in: d)
        } else if d.content == nil, d.buttons.count <= 1 {
            d.buttons.first?.action()
            d.onDismiss()
            if current?.id == d.id { current = nil }
        }
    }
}

private struct DialogPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let make: () -> AppDialog
    @State private var shown: UUID?

    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, on in
            let center = DialogCenter.shared
            if on {
                var d = make()
                let binding = $isPresented
                d.onDismiss = { binding.wrappedValue = false }
                shown = d.id
                center.current = d
            } else if let shown, center.current?.id == shown {
                center.current = nil
            }
        }
    }
}

extension View {
    /// Confirmare cu butoane; textele se citesc în momentul afișării.
    func appDialog(isPresented: Binding<Bool>, title: @escaping () -> String, message: @escaping () -> String,
                   buttons: @escaping () -> [DialogButton]) -> some View {
        modifier(DialogPresenter(isPresented: isPresented) {
            AppDialog(title: title(), message: message(), buttons: buttons())
        })
    }

    /// Mesaj simplu cu OK.
    func appMessage(_ message: Binding<(title: String, body: String)?>) -> some View {
        appDialog(isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
                  title: { message.wrappedValue?.title ?? "" }, message: { message.wrappedValue?.body ?? "" },
                  buttons: { [.ok()] })
    }

    /// Dialog cu conținut propriu.
    func appSheet<V: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> V) -> some View {
        modifier(DialogPresenter(isPresented: isPresented) { AppDialog(content: AnyView(content())) })
    }
}

/// Stratul care desenează dialogul curent; se pune o singură dată, peste toată fereastra.
struct DialogHost: View {
    @ObservedObject private var center = DialogCenter.shared

    var body: some View {
        ZStack {
            if let d = center.current {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { center.dismiss(d) }
                    .transition(.opacity)
                Group {
                    if let custom = d.content { custom } else { standard(d) }
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                .padding(24)
                .foregroundStyle(Theme.text)
                .onExitCommand { center.dismiss(d) }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .id(d.id)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.easeOut(duration: 0.15), value: center.current?.id)
    }

    private func standard(_ d: AppDialog) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(d.title).font(.system(size: 17, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            if !d.message.isEmpty {
                ScrollView {
                    Text(d.message).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // Anulează în stânga, acțiunea principală în dreapta.
                ForEach(Array(d.buttons.sorted { ($0.kind == .cancel ? 0 : 1) < ($1.kind == .cancel ? 0 : 1) }.enumerated()), id: \.offset) { _, b in
                    button(b, in: d)
                }
            }
            .padding(.top, 6)
        }
        .padding(22)
        .frame(width: 440)
    }

    @ViewBuilder
    private func button(_ b: DialogButton, in d: AppDialog) -> some View {
        let act = { center.choose(b, in: d) }
        switch b.kind {
        case .cancel:
            Button(b.title, action: act).buttonStyle(SecondaryButtonStyle(height: 36)).keyboardShortcut(.cancelAction)
        case .normal:
            Button(b.title, action: act).buttonStyle(SecondaryButtonStyle(height: 36))
        case .primary:
            Button(b.title, action: act).buttonStyle(PrimaryButtonStyle(height: 36)).keyboardShortcut(.defaultAction)
        case .destructive:
            Button(b.title, action: act).buttonStyle(PrimaryButtonStyle(tint: Theme.danger, height: 36))
        }
    }
}

// MARK: - Schelete de încărcare

/// Dreptunghi care pulsează cât timp se încarcă datele.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius).fill(Theme.track)
            .frame(width: width, height: height)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// Rânduri-schelet pentru liste (iconiță, două linii de text, mărime).
struct SkeletonRows: View {
    var count = 8
    var icon: CGFloat = 32
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 12)
            }
            // ScrollView blocat: pe ferestre joase rândurile în plus se taie în loc să mărească pagina.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                        HStack(spacing: 14) {
                            SkeletonBlock(width: icon, height: icon, radius: icon / 4)
                            VStack(alignment: .leading, spacing: 7) {
                                // Lățimi maxime, nu fixe: lista se poate îngusta fără să împingă fereastra.
                                SkeletonBlock(height: 12).frame(maxWidth: CGFloat(150 + (i * 53) % 130), alignment: .leading)
                                SkeletonBlock(height: 10).frame(maxWidth: CGFloat(240 + (i * 37) % 160), alignment: .leading)
                            }
                            Spacer()
                            SkeletonBlock(width: 64, height: 12)
                        }
                        .padding(.horizontal, 16).frame(height: 58)
                    }
                }
                .card()
            }
            .scrollDisabled(true)
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label ?? tr("Se încarcă…")))
    }
}
