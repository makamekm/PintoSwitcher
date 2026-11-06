import Foundation

enum Settings {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "enabled": true,
            "switchLayout": true,
            "keepSelection": true,
            "controlKey": "right",
            "fixWordBeforeCaret": true,
            "excluded": [String](),
        ])
    }

    static var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// Переключать раскладку после исправления.
    static var switchLayout: Bool {
        get { d.bool(forKey: "switchLayout") }
        set { d.set(newValue, forKey: "switchLayout") }
    }
    /// Оставлять исправленный фрагмент выделенным.
    static var keepSelection: Bool {
        get { d.bool(forKey: "keepSelection") }
        set { d.set(newValue, forKey: "keepSelection") }
    }
    /// Какой Control запускает исправление: "right" (по умолчанию), "left" или "any".
    static var controlKey: String {
        get { d.string(forKey: "controlKey") ?? "right" }
        set { d.set(newValue, forKey: "controlKey") }
    }
    /// Код клавиши Control, который нужно ловить (nil — любой).
    static var controlKeyCode: UInt16? {
        switch controlKey {
        case "left": return 59
        case "any": return nil
        default: return 62
        }
    }
    /// Если буфер пуст — исправлять слово перед курсором (через Accessibility).
    static var fixWordBeforeCaret: Bool {
        get { d.bool(forKey: "fixWordBeforeCaret") }
        set { d.set(newValue, forKey: "fixWordBeforeCaret") }
    }
    static var excluded: Set<String> {
        get { Set(d.stringArray(forKey: "excluded") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "excluded") }
    }
}
