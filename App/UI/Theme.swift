import SwiftUI

enum Theme {
    static let corner: CGFloat = 14
    static let touchTarget: CGFloat = 44

    static let page = Color(light: UIColor(red: 0.965, green: 0.955, blue: 0.935, alpha: 1), dark: UIColor(red: 0.11, green: 0.11, blue: 0.115, alpha: 1))
    static let card = Color(light: UIColor(red: 0.995, green: 0.99, blue: 0.98, alpha: 1), dark: UIColor(red: 0.17, green: 0.17, blue: 0.175, alpha: 1))
    // Solid rather than `.secondary`, whose vibrancy vanishes on a material inside a scroll view.
    static let quiet = Color(uiColor: .secondaryLabel)
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// The soft translucent surface all floating controls sit on.
struct PanelBackground: ViewModifier {
    var corner: CGFloat = Theme.corner
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
    }
}

extension View {
    func panel(corner: CGFloat = Theme.corner) -> some View {
        modifier(PanelBackground(corner: corner))
    }
}

/// An icon button with a full-size touch target and a label for assistive technology and pointers.
struct IconButton: View {
    let symbol: String
    let label: String
    var isActive = false
    var isEnabled = true
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .foregroundStyle(isActive ? Color.white : (isEnabled ? Color.primary : Color.secondary.opacity(0.5)))
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A named value with a slider and its readout.
struct ValueSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.2f", $0) }
    var onEditingEnded: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(format(value)).font(.footnote.monospacedDigit()).foregroundStyle(Theme.quiet)
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onEditingEnded?() }
            }
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
    }
}

struct IntStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var zeroLabel: String?

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(value == 0 ? (zeroLabel ?? "0") : "\(value)").font(.footnote.monospacedDigit()).foregroundStyle(Theme.quiet)
            }
        }
        .accessibilityLabel(title)
    }
}

/// Formats world-space lengths compactly, since scene units vary widely.
func lengthText(_ value: Float) -> String {
    if value >= 100 { return String(format: "%.0f", value) }
    if value >= 1 { return String(format: "%.2f", value) }
    return String(format: "%.3f", value)
}
