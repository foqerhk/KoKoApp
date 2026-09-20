import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chineseSimplified

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .english: return Locale(identifier: "en")
        case .chineseSimplified: return Locale(identifier: "zh-Hans")
        }
    }

    /// AppleLanguages override; nil means follow system.
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .english: return ["en"]
        case .chineseSimplified: return ["zh-Hans"]
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    private static let defaultsKey = "koko.appLanguage"
    private static let appleLanguagesBackupKey = "koko.AppleLanguages.backup"

    @Published var language: AppLanguage {
        didSet { apply(language) }
    }

    var resolvedLocale: Locale {
        language.locale ?? .autoupdatingCurrent
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
        apply(language, persist: false)
    }

    private func apply(_ language: AppLanguage, persist: Bool = true) {
        if persist {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
        if let langs = language.appleLanguages {
            if UserDefaults.standard.array(forKey: Self.appleLanguagesBackupKey) == nil,
               let current = UserDefaults.standard.array(forKey: "AppleLanguages") {
                UserDefaults.standard.set(current, forKey: Self.appleLanguagesBackupKey)
            }
            UserDefaults.standard.set(langs, forKey: "AppleLanguages")
        } else if let backup = UserDefaults.standard.array(forKey: Self.appleLanguagesBackupKey) {
            UserDefaults.standard.set(backup, forKey: "AppleLanguages")
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesBackupKey)
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        objectWillChange.send()
    }
}
