//  LocalizationManager.swift
//  BatKill
//
//  Bilingual (English / Simplified Chinese) localization system for the
//  entire application. Provides both a SwiftUI-friendly ObservableObject
//  and standalone convenience functions for use outside views.
//
//  Language preference is persisted in UserDefaults under "appLanguage"
//  and defaults to the system's preferred language on first launch.
//
//  Usage:
//    // Inside SwiftUI views (observed via @EnvironmentObject):
//    lm.translate("English text", "中文文案")
//
//    // Outside SwiftUI views:
//    loc("English text", "中文文案")
//    loc("%d selected", "%d 个已选择", count)

import Foundation
import SwiftUI

// MARK: - Language Enum

/// Supported application languages.
enum Language: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    /// Human-readable display name for the language.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }

    /// Auto-detects the preferred language from the system locale.
    /// Falls back to English if the system language is not Chinese.
    static var `default`: Language {
        guard let preferred = Locale.preferredLanguages.first else { return .english }
        if preferred.hasPrefix("zh") { return .chinese }
        return .english
    }
}

// MARK: - Localization Manager

/// Central localization manager that holds the current language selection
/// and provides translation methods. Persists the language choice to
/// UserDefaults so it survives app restarts.
///
/// Access via the shared singleton: `LocalizationManager.shared`.
class LocalizationManager: ObservableObject {
    /// The currently active language. Setting this value persists the
    /// choice to UserDefaults immediately.
    @Published var currentLanguage: Language {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    /// Shared singleton instance.
    static let shared = LocalizationManager()

    /// Initializes with the saved language preference, or falls back
    /// to the system-detected default.
    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        self.currentLanguage = Language(rawValue: saved) ?? Language.default
    }

    /// Returns the appropriate string for the current language.
    ///
    /// - Parameters:
    ///   - en: English string.
    ///   - zh: Simplified Chinese string.
    /// - Returns: The string matching the current language.
    func translate(_ en: String, _ zh: String) -> String {
        currentLanguage == .chinese ? zh : en
    }

    /// Returns the appropriate formatted string for the current language,
    /// substituting format arguments.
    ///
    /// - Parameters:
    ///   - en: English format string.
    ///   - zh: Simplified Chinese format string.
    ///   - args: Format arguments (e.g., count, name).
    /// - Returns: The formatted string matching the current language.
    func translate(_ en: String, _ zh: String, _ args: CVarArg...) -> String {
        let format = currentLanguage == .chinese ? zh : en
        return String(format: format, arguments: args)
    }
}

// MARK: - Standalone Convenience Functions

/// Translates a string pair using the shared localization manager.
/// Intended for use outside SwiftUI views where `@EnvironmentObject`
/// is not available.
///
/// - Parameters:
///   - en: English string.
///   - zh: Simplified Chinese string.
/// - Returns: The string matching the current language.
func loc(_ en: String, _ zh: String) -> String {
    LocalizationManager.shared.translate(en, zh)
}

/// Translates and formats a string pair using the shared localization manager.
///
/// - Parameters:
///   - en: English format string.
///   - zh: Simplified Chinese format string.
///   - args: Format arguments.
/// - Returns: The formatted string matching the current language.
func loc(_ en: String, _ zh: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.translate(en, zh, args)
}
