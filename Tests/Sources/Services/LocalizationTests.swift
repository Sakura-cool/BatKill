//  LocalizationTests.swift
//  BatKill Tests
//
//  Unit tests for LocalizationManager and Language enum.
//  Tests translation logic, language detection, and persistence.

import Foundation

final class LocalizationTests: TestCase {
    let name = "LocalizationTests"
    
    private let originalLanguage: String
    
    init() {
        // Save original language preference
        originalLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
    }
    
    func setUp() {
        // Don't modify UserDefaults to avoid affecting other tests
    }
    
    func tearDown() {
        // Restore original language
        if originalLanguage.isEmpty {
            UserDefaults.standard.removeObject(forKey: "appLanguage")
        } else {
            UserDefaults.standard.set(originalLanguage, forKey: "appLanguage")
        }
    }
    
    func run() {
        testLanguageRawValues()
        testLanguageDisplayName()
        testLanguageDefault()
        testLocalizationManagerTranslate()
        testLocalizationManagerTranslateWithArgs()
        testLocFunction()
        testLocFunctionWithArgs()
    }
    
    // MARK: - Language Enum Tests
    
    private func testLanguageRawValues() {
        runTest("Language raw values") {
            XCTAssertEqual(Language.english.rawValue, "en")
            XCTAssertEqual(Language.chinese.rawValue, "zh-Hans")
        }
    }
    
    private func testLanguageDisplayName() {
        runTest("Language display names") {
            XCTAssertEqual(Language.english.displayName, "English")
            XCTAssertEqual(Language.chinese.displayName, "简体中文")
        }
    }
    
    private func testLanguageDefault() {
        runTest("Language default detection") {
            let defaultLang = Language.default
            
            // Check system preferred language
            if let preferred = Locale.preferredLanguages.first {
                if preferred.hasPrefix("zh") {
                    XCTAssertEqual(defaultLang, .chinese, "Chinese system should default to Chinese")
                } else {
                    XCTAssertEqual(defaultLang, .english, "Non-Chinese system should default to English")
                }
            } else {
                XCTAssertEqual(defaultLang, .english, "No preferred language should default to English")
            }
        }
    }
    
    // MARK: - LocalizationManager Tests
    
    private func testLocalizationManagerTranslate() {
        runTest("LocalizationManager translate simple strings") {
            let lm = LocalizationManager.shared
            
            // Test translation based on current language
            let result = lm.translate("Hello", "你好")
            
            if lm.currentLanguage == .chinese {
                XCTAssertEqual(result, "你好", "Should return Chinese when language is Chinese")
            } else {
                XCTAssertEqual(result, "Hello", "Should return English when language is English")
            }
        }
    }
    
    private func testLocalizationManagerTranslateWithArgs() {
        runTest("LocalizationManager translate with format arguments") {
            let lm = LocalizationManager.shared
            
            let result = lm.translate("%d items", "%d 个项目", 5)
            
            if lm.currentLanguage == .chinese {
                XCTAssertEqual(result, "5 个项目", "Should format Chinese string")
            } else {
                XCTAssertEqual(result, "5 items", "Should format English string")
            }
        }
    }
    
    // MARK: - loc() Function Tests
    
    private func testLocFunction() {
        runTest("loc() function translates strings") {
            let lm = LocalizationManager.shared
            let result = loc("Test", "测试")
            
            if lm.currentLanguage == .chinese {
                XCTAssertEqual(result, "测试")
            } else {
                XCTAssertEqual(result, "Test")
            }
        }
    }
    
    private func testLocFunctionWithArgs() {
        runTest("loc() function with format arguments") {
            let lm = LocalizationManager.shared
            let result = loc("Count: %d", "数量: %d", 42)
            
            if lm.currentLanguage == .chinese {
                XCTAssertEqual(result, "数量: 42")
            } else {
                XCTAssertEqual(result, "Count: 42")
            }
        }
    }
}
