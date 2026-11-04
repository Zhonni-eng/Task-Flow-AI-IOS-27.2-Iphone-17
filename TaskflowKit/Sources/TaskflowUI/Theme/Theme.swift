// Taskflow's visual identity - the design tokens of src/styles/theme.css (dark theme, mint accent)
// as SwiftUI values, plus the label palette of src/utils/labelColor.js.
import SwiftUI
import TaskflowCore

public enum Theme {
    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    // Backgrounds
    public static let bgApp = hex(0x0B0F14)
    public static let bgSidebar = hex(0x0E131A)
    public static let bgSurface = hex(0x121821)
    public static let bgColumn = hex(0x111720)
    public static let bgCard = hex(0x18202B)
    public static let bgCardHover = hex(0x1C2531)
    public static let bgElevated = hex(0x1F2935)

    // Borders
    public static let borderSubtle = hex(0x1E2732)
    public static let borderDefault = hex(0x263140)
    public static let borderStrong = hex(0x33404F)

    // Text
    public static let textPrimary = hex(0xE8EDF3)
    public static let textSecondary = hex(0xA3AFBD)
    public static let textMuted = hex(0x8592A3)

    // Accent and states
    public static let accent = hex(0x2EE6B6)
    public static let accentStrong = hex(0x19C99C)
    public static let accentSoft = hex(0x2EE6B6, 0.12)
    public static let accentGlow = hex(0x2EE6B6, 0.28)
    public static let danger = hex(0xFF6B7A)
    public static let dangerSoft = hex(0xFF6B7A, 0.12)
    public static let warning = hex(0xF7B955)
    public static let warningSoft = hex(0xF7B955, 0.12)
    public static let info = hex(0x6AA8FF)
    public static let infoSoft = hex(0x6AA8FF, 0.12)
    public static let neutral = hex(0x8B98AA)
    public static let neutralSoft = hex(0x8B98AA, 0.12)

    // Shape
    public static let radiusSm: CGFloat = 6
    public static let radiusMd: CGFloat = 10
    public static let radiusLg: CGFloat = 14

    public static let fast = Animation.easeOut(duration: 0.14)
    public static let standard = Animation.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.2)

    /// Priority colors: high = danger, medium = warning, low = accent.
    public static func priority(_ priority: Priority) -> Color {
        switch priority {
        case .high: return danger
        case .medium: return warning
        case .low: return accent
        }
    }

    /// Column accents for the board headers.
    public static func status(_ status: TaskStatus) -> Color {
        switch status {
        case .todo: return info
        case .inProgress: return warning
        case .done: return accent
        }
    }

    static let labelPalette: [UInt32] = [0xA78BFA, 0x6AA8FF, 0xF59EC5, 0x4FD6E6, 0x2EE6B6, 0xFF8A6B, 0xF7B955, 0x9FD36A]

    /// Stable color for a user-defined label, derived from its text (same hash as the Windows app).
    public static func label(_ label: String) -> Color {
        var hash: Int32 = 0
        for unit in label.lowercased().utf16 { hash = hash &* 31 &+ Int32(unit) }
        let index = Int(hash == Int32.min ? 0 : abs(hash)) % labelPalette.count
        return hex(labelPalette[index])
    }
}

/// The card surface of the original (bg-card, border-default, radius-md, card shadow).
struct CardBackground: ViewModifier {
    var highlighted = false
    /// A colored edge on the leading side (the List view's priority).
    var stripe: Color?
    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .leading) {
                    highlighted ? Theme.bgCardHover : Theme.bgCard
                    if let stripe { stripe.frame(width: 4) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(highlighted ? Theme.accent.opacity(0.6) : Theme.borderDefault, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
    }
}

extension View {
    func cardSurface(highlighted: Bool = false, stripe: Color? = nil) -> some View { modifier(CardBackground(highlighted: highlighted, stripe: stripe)) }

    /// A small rounded chip (labels, categories, filters).
    func chip(_ color: Color, filled: Bool = false) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? Theme.bgApp : color)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}
