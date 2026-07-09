import Foundation
import SwiftUI

// MARK: - Language Enum
enum Language: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    static var `default`: Language {
        guard let preferred = Locale.preferredLanguages.first else { return .english }
        if preferred.hasPrefix("zh") { return .chinese }
        return .english
    }
}

// MARK: - Localization Manager
class LocalizationManager: ObservableObject {
    @Published var currentLanguage: Language {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    static let shared = LocalizationManager()

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.currentLanguage = Language(rawValue: saved) ?? Language.default
    }

    /// Translate a pair of (English, Chinese) strings.
    func translate(_ en: String, _ zh: String) -> String {
        currentLanguage == .chinese ? zh : en
    }

    /// Translate with format arguments (e.g. "%d selected").
    func translate(_ en: String, _ zh: String, _ args: CVarArg...) -> String {
        let format = currentLanguage == .chinese ? zh : en
        return String(format: format, arguments: args)
    }
}

// MARK: - Standalone convenience (for use outside SwiftUI views)
func loc(_ en: String, _ zh: String) -> String {
    LocalizationManager.shared.translate(en, zh)
}

func loc(_ en: String, _ zh: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.translate(en, zh, args)
}
