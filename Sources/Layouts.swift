import Carbon
import Foundation

/// Одно нажатие клавиши, записанное в буфер набора.
struct KeyStroke: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
    /// Символ(ы), которые реально появились на экране.
    let text: String
    /// Раскладка, в которой было сделано нажатие.
    let layoutID: String

    var isSpace: Bool { text == " " || text == "\u{00A0}" }
}

/// Раскладка клавиатуры с таблицей «клавиша → символ», построенной через UCKeyTranslate.
final class KeyboardLayout {
    struct Key { let keyCode: UInt16; let shift: Bool }

    let id: String
    let name: String
    let languages: [String]
    let source: TISInputSource

    /// table[keyCode][mod]: mod = (shift ? 1 : 0) | (caps ? 2 : 0)
    private var table: [[String?]]
    /// Обратная таблица «символ → клавиша».
    private(set) var reverse: [Character: Key] = [:]

    var isEnglish: Bool {
        if languages.first == "en" { return true }
        return id.hasSuffix(".US") || id.hasSuffix(".ABC") || id.hasSuffix(".British") || id.contains("USExtended")
    }

    /// Короткое имя для строки меню: EN, RU, UK…
    var shortName: String {
        if let l = languages.first, !l.isEmpty { return String(l.prefix(2)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }

    init?(source: TISInputSource) {
        guard let id: String = TIS.property(source, kTISPropertyInputSourceID),
              let data: Data = TIS.property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.id = id
        self.source = source
        self.name = TIS.property(source, kTISPropertyLocalizedName) ?? id
        self.languages = TIS.property(source, kTISPropertyInputSourceLanguages) ?? []
        self.table = Array(repeating: Array(repeating: nil, count: 4), count: 128)

        let kbdType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for keyCode in 0..<128 {
                for mod in 0..<4 {
                    let state: UInt32 = ((mod & 1) != 0 ? 2 : 0) | ((mod & 2) != 0 ? 4 : 0)
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(base, UInt16(keyCode), UInt16(kUCKeyActionDown), state, kbdType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                                                chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: length)
                    guard KeyboardLayout.isPrintable(s) else { continue }
                    table[keyCode][mod] = s
                }
            }
        }
        // Обратная таблица: основная часть клавиатуры (коды 0–50) имеет приоритет над цифровым блоком.
        for keyCode in 0..<128 {
            for shift in [false, true] {
                guard let s = table[keyCode][shift ? 1 : 0], s.count == 1, let ch = s.first else { continue }
                if reverse[ch] == nil { reverse[ch] = Key(keyCode: UInt16(keyCode), shift: shift) }
            }
        }
        guard !reverse.isEmpty else { return nil }
    }

    static func isPrintable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { v in
            v.value >= 0x20 && v.value != 0x7F && !(0xF700...0xF8FF).contains(v.value)
        }
    }

    func text(keyCode: UInt16, shift: Bool, caps: Bool) -> String? {
        guard keyCode < 128 else { return nil }
        let mod = (shift ? 1 : 0) | (caps ? 2 : 0)
        return table[Int(keyCode)][mod] ?? table[Int(keyCode)][shift ? 1 : 0]
    }

    /// Сколько букв строки можно набрать в этой раскладке.
    func letterScore(_ text: String) -> Int {
        var score = 0
        for ch in text where ch.isLetter {
            if reverse[ch] != nil { score += 1; continue }
            let lower = String(ch).lowercased()
            if lower.count == 1, let l = lower.first, reverse[l] != nil { score += 1 }
        }
        return score
    }
}

/// Неизменяемый снимок включённых раскладок — его можно безопасно передавать в фоновый поток.
struct LayoutSet {
    let layouts: [KeyboardLayout]
    let currentID: String

    var current: KeyboardLayout? { layout(id: currentID) }

    func layout(id: String) -> KeyboardLayout? { layouts.first { $0.id == id } }

    /// Раскладка, в которую нужно перевести текст, набранный в `from`.
    func target(from: KeyboardLayout) -> KeyboardLayout? {
        let others = layouts.filter { $0.id != from.id }
        if others.count <= 1 { return others.first }
        if let cur = others.first(where: { $0.id == currentID }) { return cur }
        if from.isEnglish { return others.first { !$0.isEnglish } ?? others[0] }
        return others.first { $0.isEnglish } ?? others[0]
    }

    /// Определяет, в какой раскладке набран текст (по буквам).
    func detectSource(of text: String) -> KeyboardLayout? {
        var best: KeyboardLayout?
        var bestScore = 0
        for l in layouts {
            let s = l.letterScore(text)
            if s > bestScore || (s == bestScore && s > 0 && l.id == currentID) {
                best = l
                bestScore = s
            }
        }
        return best ?? current
    }

    /// Перекодирует строку так, как если бы те же клавиши нажали в раскладке `to`.
    static func convert(_ text: String, from: KeyboardLayout, to: KeyboardLayout) -> String {
        var out = ""
        for ch in text {
            if let key = from.reverse[ch], let t = to.text(keyCode: key.keyCode, shift: key.shift, caps: false) {
                out += t
                continue
            }
            // Текст, набранный с Caps Lock: «ПРИВЕТ» → «GHBDTN».
            let lower = String(ch).lowercased()
            if lower.count == 1, let l = lower.first, l != ch,
               let key = from.reverse[l], !key.shift,
               let t = to.text(keyCode: key.keyCode, shift: false, caps: false) {
                out += t.uppercased()
                continue
            }
            out.append(ch)
        }
        return out
    }
}

/// Работа с Text Input Sources (только из главного потока).
enum TIS {
    static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
    }

    static func currentLayoutID() -> String {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "" }
        return property(src, kTISPropertyInputSourceID) ?? ""
    }

    static func loadLayoutSet() -> LayoutSet {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        var result: [KeyboardLayout] = []
        if let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] {
            for src in list {
                guard let type: String = property(src, kTISPropertyInputSourceType),
                      type == (kTISTypeKeyboardLayout as String),
                      let layout = KeyboardLayout(source: src) else { continue }
                if !result.contains(where: { $0.id == layout.id }) { result.append(layout) }
            }
        }
        return LayoutSet(layouts: result, currentID: currentLayoutID())
    }

    static func select(_ layout: KeyboardLayout) {
        TISSelectInputSource(layout.source)
    }
}
