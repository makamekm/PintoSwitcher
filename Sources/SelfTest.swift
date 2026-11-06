import Foundation

/// Проверка логики конвертации без перехвата клавиатуры: `PintoSwitcher --selftest`.
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(name): \(got)")
        } else {
            failures += 1
            print("  ✗ \(name): получено «\(got)», ожидалось «\(expected)»")
        }
    }

    static func run() -> Bool {
        let set = TIS.loadLayoutSet()
        print("Раскладки:")
        for l in set.layouts {
            print("  • \(l.name) [\(l.id)] языки=\(l.languages.prefix(3)) en=\(l.isEnglish) символов=\(l.reverse.count)")
        }
        print("Текущая: \(set.currentID)")

        guard let en = set.layouts.first(where: { $0.isEnglish }),
              let ru = set.layouts.first(where: { $0.languages.first == "ru" }) else {
            print("Нужны английская и русская раскладки — проверка конвертации пропущена.")
            return true
        }

        print("Конвертация:")
        check("en→ru", LayoutSet.convert("ghbdtn", from: en, to: ru), "привет")
        check("en→ru Shift", LayoutSet.convert("Ghbdtn vbh", from: en, to: ru), "Привет мир")
        check("ru→en", LayoutSet.convert("руддщ", from: ru, to: en), "hello")
        check("Caps Lock", LayoutSet.convert("ПРИВЕТ", from: ru, to: en), "GHBDTN")
        check("туда-обратно", LayoutSet.convert(LayoutSet.convert("Съешь же ещё этих", from: ru, to: en), from: en, to: ru),
              "Съешь же ещё этих")

        print("Определение раскладки:")
        check("ghbdtn", set.detectSource(of: "ghbdtn")?.id ?? "-", en.id)
        check("руддщ", set.detectSource(of: "руддщ")?.id ?? "-", ru.id)
        check("цель из en", set.target(from: en)?.id ?? "-", ru.id)
        check("цель из ru", set.target(from: ru)?.id ?? "-", en.id)

        print("Буфер набора:")
        func strokes(_ s: String) -> [KeyStroke] {
            s.map { ch in
                let key = en.reverse[ch]
                return KeyStroke(keyCode: key?.keyCode ?? 0, shift: key?.shift ?? false, caps: false,
                                 text: String(ch), layoutID: en.id)
            }
        }
        let buf = strokes("hello ghbdtn  ")
        if let r = Converter.lastWordRange(buf) {
            check("последнее слово", buf[r].map(\.text).joined(), "ghbdtn  ")
            let conv = buf[r].map { s in s.isSpace ? s.text : (ru.text(keyCode: s.keyCode, shift: s.shift, caps: false) ?? s.text) }
            check("из нажатий", conv.joined(), "привет  ")
        } else { failures += 1; print("  ✗ слово не найдено") }
        check("пустой буфер", Converter.lastWordRange(strokes("   ")) == nil ? "nil" : "range", "nil")

        if let (w, sp) = Converter.lastWord(in: "текст\nruddq ") {
            check("слово перед курсором", w + "|" + sp, "ruddq| ")
        } else { failures += 1; print("  ✗ слово перед курсором не найдено") }

        print(failures == 0 ? "Все проверки пройдены." : "Ошибок: \(failures)")
        return failures == 0
    }
}
