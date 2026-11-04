import SwiftUI

enum Theme {
    static let corner: CGFloat = 18
    static let touchTarget: CGFloat = 44

    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    // Solid rather than `.secondary`, whose vibrancy vanishes on a material inside a scroll view.
    static let quiet = Color(uiColor: .secondaryLabel)
    /// Matches how the viewport draws selected elements.
    static let selection = Color(uiColor: .systemBlue)
}

/// The surface floating controls sit on: the system's glass where there is one.
struct PanelBackground: ViewModifier {
    var corner: CGFloat = Theme.corner
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }
}

extension View {
    func panel(corner: CGFloat = Theme.corner) -> some View {
        modifier(PanelBackground(corner: corner))
    }

    /// A system button in a capsule. Disabled buttons dim on their own.
    @ViewBuilder
    func pillButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
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
                .foregroundStyle(isActive ? Color.white : (isEnabled ? Color.primary : Color(uiColor: .tertiaryLabel)))
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor)
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
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(Theme.quiet)
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
                Text(title)
                Spacer()
                Text(value == 0 ? (zeroLabel ?? "0") : "\(value)").monospacedDigit().foregroundStyle(Theme.quiet)
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
