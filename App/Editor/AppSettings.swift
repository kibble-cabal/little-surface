import Foundation
import Observation

enum OneFingerAction: String, CaseIterable, Identifiable {
    case orbit, pan, draw, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .orbit: return "Orbit"
        case .pan: return "Pan"
        case .draw: return "Draw, as a Pencil would"
        case .none: return "Nothing"
        }
    }
}

enum PencilDoubleTapAction: String, CaseIterable, Identifiable {
    case eraser, previousTool, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eraser: return "Switch to eraser"
        case .previousTool: return "Switch to previous tool"
        case .none: return "Nothing"
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Preferences that belong to the person, not the document. Launch arguments can set them too,
/// for example `-oneFingerAction draw`, which is how the simulator drives drawing.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var oneFingerAction: OneFingerAction {
        didSet { defaults.set(oneFingerAction.rawValue, forKey: "oneFingerAction") }
    }
    var twoFingerTapUndoes: Bool {
        didSet { defaults.set(twoFingerTapUndoes, forKey: "twoFingerTapUndoes") }
    }
    var pencilDoubleTap: PencilDoubleTapAction {
        didSet { defaults.set(pencilDoubleTap.rawValue, forKey: "pencilDoubleTap") }
    }
    var orbitInertia: Bool {
        didSet { defaults.set(orbitInertia, forKey: "orbitInertia") }
    }
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    var showsStatusBar: Bool {
        didSet { defaults.set(showsStatusBar, forKey: "showsStatusBar") }
    }
    var hasSeenTutorial: Bool {
        didSet { defaults.set(hasSeenTutorial, forKey: "hasSeenTutorial") }
    }

    private init() {
        defaults.register(defaults: ["twoFingerTapUndoes": true, "orbitInertia": true, "showsStatusBar": true])
        oneFingerAction = OneFingerAction(rawValue: defaults.string(forKey: "oneFingerAction") ?? "") ?? .orbit
        twoFingerTapUndoes = defaults.bool(forKey: "twoFingerTapUndoes")
        pencilDoubleTap = PencilDoubleTapAction(rawValue: defaults.string(forKey: "pencilDoubleTap") ?? "") ?? .eraser
        orbitInertia = defaults.bool(forKey: "orbitInertia")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .light
        showsStatusBar = defaults.bool(forKey: "showsStatusBar")
        hasSeenTutorial = defaults.bool(forKey: "hasSeenTutorial")
    }
}
