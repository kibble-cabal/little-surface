import Foundation

/// The practice models that come with the app. The README says where each one came from.
enum ExampleModel: String, CaseIterable, Identifiable {
    case bust = "Marble Bust"
    case spot = "Spot the Cow"
    case blub = "Blub the Fish"
    case duck = "Rubber Duck"
    case horse = "Horse Head"

    var id: String { rawValue }
    var title: String { rawValue }
    var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: "glb") }
}
