import Foundation

enum L10n {
    static var language: String = {
        if let chosen = UserDefaults.standard.string(forKey: "interfaceLanguage"), ["en", "ru"].contains(chosen) { return chosen }
        return Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en"
    }()

    static func setLanguage(_ language: String) {
        guard ["en", "ru"].contains(language) else { return }
        self.language = language
        UserDefaults.standard.set(language, forKey: "interfaceLanguage")
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let localized = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = localized?.localizedString(forKey: key, value: nil, table: nil) ?? key
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
