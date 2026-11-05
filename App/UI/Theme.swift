import SwiftUI

enum Theme {
    static let corner: CGFloat = 18
    static let touchTarget: CGFloat = 44

    /// The same paper the model sits on.
    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
            : UIColor(red: 0.965, green: 0.955, blue: 0.93, alpha: 1)
    })
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
