import Foundation

/// The available avatar faces for the floating window.
enum FaceKind: String, CaseIterable, Identifiable {
    case orb
    case lobster

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .orb: "Orb"
        case .lobster: "Lobster"
        }
    }

    // MARK: - Persistence

    private static let defaultsKey = "selectedFaceKind"

    static var current: FaceKind {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let kind = FaceKind(rawValue: raw) else { return .orb }
            return kind
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
