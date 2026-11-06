import AppKit
import ApplicationServices
import Carbon

/// Синтез нажатий клавиш. Все события помечаются, чтобы собственный перехватчик их игнорировал.
final class KeySender {
    static let marker: Int64 = 0x50_49_4E_54_4F // "PINTO"

    private let source = CGEventSource(stateID: .hidSystemState)
    private let delay: useconds_t = 2_000

    func press(_ keyCode: CGKeyCode, flags: CGEventFlags = [], unicode: String? = nil) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = flags
            if let unicode {
                let utf16 = Array(unicode.utf16)
                e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            }
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
            usleep(delay)
        }
    }

    func backspace(_ count: Int) {
        for _ in 0..<max(0, count) { press(51) }
    }

    func shiftLeft(_ count: Int) {
        for _ in 0..<max(0, count) { press(123, flags: [.maskShift, .maskSecondaryFn, .maskNumericPad]) }
    }

    func commandKey(_ keyCode: CGKeyCode) { press(keyCode, flags: .maskCommand) }

    /// Набирает строку посимвольно. Если известна раскладка — использует реальные коды клавиш.
    func type(_ text: String, layout: KeyboardLayout?) {
        for ch in text {
            if ch == " " { press(49, unicode: " "); continue }
            if let key = layout?.reverse[ch] {
                press(key.keyCode, flags: key.shift ? .maskShift : [], unicode: String(ch))
            } else {
                press(0, unicode: String(ch))
            }
        }
    }

    func type(strokes: [KeyStroke]) {
        for s in strokes {
            var flags: CGEventFlags = []
            if s.shift { flags.insert(.maskShift) }
            if s.caps { flags.insert(.maskAlphaShift) }
            press(s.keyCode, flags: flags, unicode: s.text)
        }
    }
}

/// Доступ к выделенному тексту и полям ввода через Accessibility API.
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    /// nil — приложение не сообщает выделение; "" — выделения нет.
    static func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? String) ?? ""
    }

    /// Текст поля и позиция курсора (только когда ничего не выделено).
    static func valueAndCaret(_ element: AXUIElement) -> (String, Int)? {
        let editableRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String,
                                          kAXComboBoxRole as String, "AXSearchField"]
        guard let role = string(element, kAXRoleAttribute), editableRoles.contains(role),
              let value = string(element, kAXValueAttribute), (value as NSString).length < 500_000 else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0,
              range.location >= 0, range.location <= (value as NSString).length else { return nil }
        return (value, range.location)
    }

    /// true — после выделения до конца текста только пустые строки (т. е. выделена строка ввода терминала).
    /// nil — приложение не сообщает нужные атрибуты.
    static func selectionIsOnLastLine(_ element: AXUIElement) -> Bool? {
        var rangeRef: CFTypeRef?
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let total = countRef as? Int else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        let end = range.location + range.length
        let restLength = total - end
        if restLength <= 0 { return true }
        if restLength > 8_000 { return false }

        var rest = CFRange(location: end, length: restLength)
        guard let restValue = AXValueCreate(.cfRange, &rest) else { return nil }
        var restRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         restValue, &restRef) == .success,
              let restText = restRef as? String else { return nil }
        return restText.components(separatedBy: .newlines).dropFirst()
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Просит Electron/Chromium-приложения включить дерево доступности (нужно для чтения выделения).
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// Временное использование буфера обмена с восстановлением содержимого.
enum Clipboard {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot() -> Snapshot {
        let pb = NSPasteboard.general
        return (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    static func restore(_ snapshot: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }

    /// Копирует выделение через ⌘C. nil — ничего не скопировалось.
    static func copySelection(using sender: KeySender) -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot()
        let before = pb.changeCount
        sender.commandKey(8) // C
        var changed = false
        for _ in 0..<25 {
            usleep(12_000)
            if pb.changeCount != before { changed = true; break }
        }
        guard changed else { return nil }
        usleep(15_000)
        let text = pb.string(forType: .string)
        restore(saved)
        return text
    }

    /// Вставляет текст через ⌘V и возвращает прежнее содержимое буфера.
    static func paste(_ text: String, using sender: KeySender) {
        let pb = NSPasteboard.general
        let saved = snapshot()
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transient)
        pb.setData(Data(), forType: concealed)
        let ours = pb.changeCount
        sender.commandKey(9) // V
        usleep(300_000)
        if pb.changeCount == ours { restore(saved) }
    }
}
