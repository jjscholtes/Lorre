import SwiftUI

enum DS {
    enum ColorToken {
        static let bgApp = Color(hex: 0xFFFFFF)
        static let bgPanel = Color(hex: 0xF6F6F4)
        static let bgPanelAlt = Color(hex: 0xFAFAF8)
        static let fgPrimary = Color(hex: 0x111111)
        static let fgSecondary = Color(hex: 0x616161)
        static let fgTertiary = Color(hex: 0x8C8C8C)
        static let borderSoft = Color(hex: 0xDDDDDD)
        static let borderStrong = Color(hex: 0xBDBDBD)
        static let fieldBg = Color(hex: 0xFFFFFF)
        static let fieldBorder = Color(hex: 0xDDDDDD)
        static let fieldText = Color(hex: 0x000000)
        static let fieldPlaceholder = Color(hex: 0x616161)
        static let chipBg = Color(hex: 0xF6F6F4)
        static let chipBorder = Color(hex: 0xDDDDDD)
        static let black = Color(hex: 0x111111)
        static let white = Color(hex: 0xFFFFFF)
        static let statusReady = Color(hex: 0x2E7D32)
        static let statusPreparing = Color(hex: 0x9A6A00)
        static let statusError = Color(hex: 0xB3261E)
        static let statusIdle = Color(hex: 0x8C8C8C)
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
    }

    enum Space {
        static let x1: CGFloat = 4
        static let x1_5: CGFloat = 6
        static let x2: CGFloat = 8
        static let x2_5: CGFloat = 10
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
    }

    enum FontStyle {
        static let appTitle = Font.system(size: 22, weight: .semibold)
        static let panelTitle = Font.system(size: 20, weight: .semibold)
        static let stageStatus = Font.system(size: 14, weight: .medium)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let control = Font.system(size: 12, weight: .semibold)
        static let helper = Font.system(size: 11, weight: .regular)
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let monoStrong = Font.system(size: 12, weight: .semibold, design: .monospaced)
        static let timer = Font.system(size: 18, weight: .semibold, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

struct SecondaryControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.FontStyle.control)
            .foregroundStyle(DS.ColorToken.fgPrimary)
            .padding(.horizontal, DS.Space.x3)
            .padding(.vertical, DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(configuration.isPressed ? DS.ColorToken.bgPanel : DS.ColorToken.bgPanelAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
            )
    }
}

struct PrimaryControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(DS.FontStyle.control)
            .foregroundStyle(
                isEnabled
                    ? DS.ColorToken.white.opacity(pressed ? 0.9 : 1)
                    : DS.ColorToken.fgSecondary
            )
            .padding(.horizontal, DS.Space.x3)
            .padding(.vertical, DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(
                        isEnabled
                            ? DS.ColorToken.black.opacity(pressed ? 0.92 : 1)
                            : DS.ColorToken.bgPanelAlt
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(isEnabled ? .clear : DS.ColorToken.borderStrong, lineWidth: 1)
            )
    }
}

extension View {
    func dsPanelSurface(selected: Bool = false, alt: Bool = false, cornerRadius: CGFloat = DS.Radius.md) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? DS.ColorToken.bgPanel : (alt ? DS.ColorToken.bgPanelAlt : DS.ColorToken.bgPanel))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft, lineWidth: 1)
            )
    }
}
