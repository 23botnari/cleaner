import SwiftUI
import AppKit

/// Culorile din designul Claude Design, cu variantă pentru modul întunecat.
enum Theme {
    static let accent = dyn(0x067A52, 0x34C77B)
    /// Fundal pentru butoane pline (text alb lizibil și în modul întunecat).
    static let accentFill = dyn(0x067A52, 0x16804C)
    static let accentText = dyn(0x066343, 0x5FD99A)
    static let ground = dyn(0xF4F5F7, 0x1B1C1F)
    static let sidebar = dyn(0xEBEDF0, 0x232428)
    static let sidebarLine = dyn(0xDDE0E4, 0x34363B)
    static let card = dyn(0xFFFFFF, 0x2A2C30)
    static let line = dyn(0xE2E5E9, 0x3A3C42)
    static let lineSoft = dyn(0xF0F1F3, 0x323439)
    static let track = dyn(0xE2E5E9, 0x3A3C42)
    static let text = dyn(0x15171A, 0xECEDEF)
    static let muted = dyn(0x5B636E, 0xA2A8B0)
    static let faint = dyn(0x6B727C, 0x8C929A)
    static let used = dyn(0x8A919B, 0x6E747C)
    static let reclaim = dyn(0x22C55E, 0x2FBF67)
    static let care = dyn(0xF59E0B, 0xE0A030)

    static let safeBg = dyn(0xDDF6E8, 0x173A28)
    static let safeFg = dyn(0x066343, 0x6FDDA2)
    static let careBg = dyn(0xFFF1D6, 0x3D2E12)
    static let careFg = dyn(0x8A5300, 0xF2C46D)
    static let intBg = dyn(0xE3ECFC, 0x1E2D4A)
    static let intFg = dyn(0x1F4FB8, 0x8DB0F5)
    static let extBg = dyn(0xEFE7FB, 0x33264A)
    static let extFg = dyn(0x6232B0, 0xC3A6F5)
    static let danger = dyn(0xB42318, 0xE5534B)

    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let hex = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Componente

struct Card: ViewModifier {
    var radius: CGFloat = 12
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line))
    }
}

extension View {
    func card(radius: CGFloat = 12, padding: CGFloat = 0) -> some View { modifier(Card(radius: radius, padding: padding)) }
}

struct Pill: View {
    let text: String
    let bg: Color
    let fg: Color
    var icon: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 7).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(bg))
        .foregroundStyle(fg)
        .lineLimit(1)
        .fixedSize()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accentFill
    var height: CGFloat = 40
    /// Ocupă toată lățimea disponibilă.
    var fill = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 18).frame(maxWidth: fill ? .infinity : nil).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(enabled ? tint : Theme.track))
            .foregroundStyle(enabled ? Color.white : Theme.faint)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    var tinted = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.85)
            .padding(.horizontal, 14).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9).fill(tinted ? Theme.safeBg : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tinted ? Theme.safeBg : Theme.line))
            .foregroundStyle(tinted ? Theme.safeFg : Theme.text)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// Bara subțire de mărime (verde pentru sigur, chihlimbar pentru „Atenție”).
struct SizeBar: View {
    let fraction: Double
    var color: Color = Theme.reclaim
    var width: CGFloat? = nil
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(width: width, height: 5)
        .accessibilityHidden(true)
    }
}

/// Antetul fiecărui ecran: titlu, subtitlu, acțiuni în dreapta.
struct ScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
    }
}
