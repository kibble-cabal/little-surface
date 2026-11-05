import Foundation
import Observation

enum OneFingerAction: String, CaseIterable, Identifiable {
    case orbit, draw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .orbit: return "Turns the model"
        case .draw: return "Draws, as a Pencil would"
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Preferences that belong to the person, not the document. UserDefaults also reads launch arguments,
/// so `-oneFingerAction draw` is how the simulator and UI tests draw without a Pencil.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var oneFingerAction: OneFingerAction {
        didSet { defaults.set(oneFingerAction.rawValue, forKey: "oneFingerAction") }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// Only tests turn this off, so a drag can't carry on spinning the model into the next step.
    let orbitInertia: Bool

    private init() {
        defaults.register(defaults: ["orbitInertia": true])
        oneFingerAction = OneFingerAction(rawValue: defaults.string(forKey: "oneFingerAction") ?? "") ?? .orbit
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light
        orbitInertia = defaults.bool(forKey: "orbitInertia")
    }
}
