import Foundation

/// The four English voice groups shipped in Kokoro's voices-v1.0.bin.
enum VoiceGroup: Int, CaseIterable {
    case usFemale, usMale, ukFemale, ukMale

    var label: String { ["US ♀", "US ♂", "UK ♀", "UK ♂"][rawValue] }
    var prefix: String { ["af", "am", "bf", "bm"][rawValue] }
    var accessibilityLabel: String {
        ["American female", "American male", "British female", "British male"][rawValue]
    }

    var voices: [String] {
        switch self {
        case .usFemale: return ["alloy", "aoede", "bella", "heart", "jessica", "kore", "nicole", "nova", "river", "sarah", "sky"].map { "af_\($0)" }
        case .usMale: return ["adam", "echo", "eric", "fenrir", "liam", "michael", "onyx", "puck", "santa"].map { "am_\($0)" }
        case .ukFemale: return ["alice", "emma", "isabella", "lily"].map { "bf_\($0)" }
        case .ukMale: return ["daniel", "fable", "george", "lewis"].map { "bm_\($0)" }
        }
    }

    static func of(_ voice: String) -> VoiceGroup {
        allCases.first { voice.hasPrefix($0.prefix + "_") } ?? .usFemale
    }
}

enum Voices {
    static let defaultVoice = "af_aoede"

    static func displayName(_ voice: String) -> String {
        let name = voice.split(separator: "_", maxSplits: 1).last.map(String.init) ?? voice
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func isKnown(_ voice: String) -> Bool {
        VoiceGroup.allCases.contains { $0.voices.contains(voice) }
    }
}

/// User preferences, stored in UserDefaults.
enum Settings {
    static let speeds: [Double] = [0.8, 1.0, 1.2, 1.5]

    static var voice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "voice") ?? Voices.defaultVoice
            return Voices.isKnown(stored) ? stored : Voices.defaultVoice
        }
        set { UserDefaults.standard.set(newValue, forKey: "voice") }
    }

    enum Highlight: String, CaseIterable {
        case blue, yellow
        var title: String { self == .yellow ? "Yellow" : "Light blue" }
    }

    static var highlight: Highlight {
        get { Highlight(rawValue: UserDefaults.standard.string(forKey: "highlight") ?? "") ?? .blue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "highlight") }
    }

    static var showMiniPlayer: Bool {
        get { UserDefaults.standard.object(forKey: "showMiniPlayer") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showMiniPlayer") }
    }

    static var speed: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "speed")
            return speeds.contains(stored) ? stored : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "speed") }
    }
}
