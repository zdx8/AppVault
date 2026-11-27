import SwiftUI
import AppKit

enum AppThemeMode: String, CaseIterable {
    case light
    case dark

    var colorScheme: ColorScheme {
        self == .light ? .light : .dark
    }

    var nsAppearance: NSAppearance? {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }

    var label: String {
        self == .light ? "浅色" : "深色"
    }

    var toggleIcon: String {
        self == .light ? "moon.fill" : "sun.max.fill"
    }
}

/// 同步窗口顶栏透明背景色与主题外观，确保 macOS 顶栏与主界面同色。
struct WindowTitlebarStyler: NSViewRepresentable {
    let themeMode: AppThemeMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applyStyle(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyStyle(to: nsView.window)
        }
    }

    private func applyStyle(to window: NSWindow?) {
        let appearance = themeMode.nsAppearance
        NSApp?.appearance = appearance
        guard let window else { return }
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = ShadcnTokens.nsBackground(for: themeMode)
    }
}

/// 遵循 shadcn/ui (Zinc) 规范的原生明暗自适应设计令牌。
enum ShadcnTokens {
    static let lightBgNS = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    static let darkBgNS = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.043, alpha: 1)

    static func nsBackground(for mode: AppThemeMode) -> NSColor {
        mode == .light ? lightBgNS : darkBgNS
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // Core surfaces
    static let background = dynamic(
        light: lightBgNS,
        dark: darkBgNS
    )
    static let card = dynamic(
        light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.062, alpha: 1)
    )
    static let muted = dynamic(
        light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1), // hsl(240 4.8% 95.9%)
        dark: NSColor(srgbRed: 0.153, green: 0.153, blue: 0.165, alpha: 1)  // hsl(240 3.7% 15.9%)
    )
    static let secondary = muted

    // Foregrounds
    static let foreground = dynamic(
        light: NSColor(srgbRed: 0.039, green: 0.039, blue: 0.043, alpha: 1),
        dark: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    )
    static let mutedForeground = dynamic(
        light: NSColor(srgbRed: 0.443, green: 0.443, blue: 0.478, alpha: 1), // hsl(240 3.8% 46.1%)
        dark: NSColor(srgbRed: 0.631, green: 0.631, blue: 0.667, alpha: 1)  // hsl(240 5% 64.9%)
    )
    static let primary = dynamic(
        light: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1), // hsl(240 5.9% 10%)
        dark: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    )
    static let primaryForeground = dynamic(
        light: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.094, green: 0.094, blue: 0.106, alpha: 1)
    )

    // Borders
    static let border = dynamic(
        light: NSColor(srgbRed: 0.894, green: 0.894, blue: 0.906, alpha: 1), // hsl(240 5.9% 90%)
        dark: NSColor(srgbRed: 0.153, green: 0.153, blue: 0.165, alpha: 1)
    )

    // Status semantics
    static let emeraldBg = dynamic(
        light: NSColor(srgbRed: 0.925, green: 0.992, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.039, green: 0.161, blue: 0.118, alpha: 1)
    )
    static let emeraldFg = dynamic(
        light: NSColor(srgbRed: 0.016, green: 0.471, blue: 0.341, alpha: 1),
        dark: NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
    )
    static let emeraldBorder = dynamic(
        light: NSColor(srgbRed: 0.655, green: 0.953, blue: 0.816, alpha: 1),
        dark: NSColor(srgbRed: 0.086, green: 0.310, blue: 0.227, alpha: 1)
    )

    static let amberBg = dynamic(
        light: NSColor(srgbRed: 0.996, green: 0.969, blue: 0.878, alpha: 1),
        dark: NSColor(srgbRed: 0.176, green: 0.125, blue: 0.043, alpha: 1)
    )
    static let amberFg = dynamic(
        light: NSColor(srgbRed: 0.627, green: 0.369, blue: 0.016, alpha: 1),
        dark: NSColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1)
    )
    static let amberBorder = dynamic(
        light: NSColor(srgbRed: 0.988, green: 0.878, blue: 0.569, alpha: 1),
        dark: NSColor(srgbRed: 0.341, green: 0.239, blue: 0.075, alpha: 1)
    )

    static let redBg = dynamic(
        light: NSColor(srgbRed: 0.996, green: 0.945, blue: 0.945, alpha: 1),
        dark: NSColor(srgbRed: 0.184, green: 0.059, blue: 0.059, alpha: 1)
    )
    static let redFg = dynamic(
        light: NSColor(srgbRed: 0.776, green: 0.125, blue: 0.125, alpha: 1),
        dark: NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1)
    )
    static let redBorder = dynamic(
        light: NSColor(srgbRed: 0.988, green: 0.804, blue: 0.804, alpha: 1),
        dark: NSColor(srgbRed: 0.361, green: 0.125, blue: 0.125, alpha: 1)
    )

    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 8
    static let radiusLG: CGFloat = 10
}

enum ShadcnBadgeTone {
    case neutral, emerald, amber, red
}

struct ShadcnBadge: View {
    let text: String
    var tone: ShadcnBadgeTone = .neutral
    var showDot: Bool = false

    private var bg: Color {
        switch tone {
        case .neutral: return ShadcnTokens.secondary
        case .emerald: return ShadcnTokens.emeraldBg
        case .amber: return ShadcnTokens.amberBg
        case .red: return ShadcnTokens.redBg
        }
    }

    private var fg: Color {
        switch tone {
        case .neutral: return ShadcnTokens.mutedForeground
        case .emerald: return ShadcnTokens.emeraldFg
        case .amber: return ShadcnTokens.amberFg
        case .red: return ShadcnTokens.redFg
        }
    }

    private var border: Color {
        switch tone {
        case .neutral: return ShadcnTokens.border
        case .emerald: return ShadcnTokens.emeraldBorder
        case .amber: return ShadcnTokens.amberBorder
        case .red: return ShadcnTokens.redBorder
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(fg)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(bg, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}

struct ShadcnButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, outline, ghost, destructive }
    let variant: Variant
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 28 : 32)
            .background(backgroundColor(pressed: configuration.isPressed))
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: ShadcnTokens.radiusSM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShadcnTokens.radiusSM, style: .continuous)
                    .stroke(borderColor, lineWidth: variant == .outline ? 1 : 0)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        switch variant {
        case .primary: return ShadcnTokens.primary
        case .secondary: return ShadcnTokens.secondary
        case .outline: return pressed ? ShadcnTokens.muted : ShadcnTokens.background
        case .ghost: return pressed ? ShadcnTokens.muted : Color.clear
        case .destructive: return ShadcnTokens.redFg
        }
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary: return ShadcnTokens.primaryForeground
        case .secondary, .outline, .ghost: return ShadcnTokens.foreground
        case .destructive: return Color.white
        }
    }

    private var borderColor: Color {
        variant == .outline ? ShadcnTokens.border : Color.clear
    }
}

enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
