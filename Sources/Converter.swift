import AppKit
import Carbon

/// Логика исправления: последнее слово из буфера, выделение, слово перед курсором.
final class Converter {
    private let monitor: KeyboardMonitor
    private let layouts: () -> LayoutSet
    private let sender = KeySender()
    private let queue = DispatchQueue(label: "pintoswitcher.convert", qos: .userInteractive)
    private var busy = false

    /// Терминалы: выделение там относится к выводу, а не к вводу — работаем только по буферу.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
    ]
    /// Редакторы, которые по ⌘C без выделения копируют всю строку.
    private static let lineCopyPrefixes = ["com.jetbrains.", "com.microsoft.VSCode", "com.sublimetext.",
                                           "com.todesktop.", "dev.zed.", "com.google.android.studio"]

    init(monitor: KeyboardMonitor, layouts: @escaping () -> LayoutSet) {
        self.monitor = monitor
        self.layouts = layouts
    }

    private enum Outcome {
        case nothing
        case resetBuffer
        case replaceBuffer(Range<Int>, [KeyStroke])

        /// Без содержимого текста — только тип результата.
        var logName: String {
            switch self {
            case .nothing: return "nothing (toggle layout)"
            case .resetBuffer: return "converted selection/caret word"
            case .replaceBuffer: return "converted typed word"
            }
        }
    }

    private struct Context {
        let bundleID: String
        let isTerminal: Bool
        let buffer: [KeyStroke]
        let generation: Int
        let layouts: LayoutSet
    }

    /// Вызывается из главного потока по одиночному нажатию Control.
    func trigger() {
        guard Settings.enabled, !busy else { return }
        let set = layouts()
        guard set.layouts.count >= 2 else { NSSound.beep(); return }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // Пароли и исключённые приложения: текст не трогаем, только меняем раскладку.
        if IsSecureEventInputEnabled() || Settings.excluded.contains(bundleID) {
            toggleLayout()
            return
        }

        let ctx = Context(bundleID: bundleID,
                          isTerminal: Self.terminals.contains(bundleID),
                          buffer: monitor.buffer,
                          generation: monitor.generation,
                          layouts: set)
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            usleep(15_000) // даём системе обработать отпускание Control
            let outcome = self.perform(ctx)
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case .nothing: self.toggleLayout() // исправлять нечего — просто переключаем раскладку
                case .resetBuffer: self.monitor.resetBuffer()
                case let .replaceBuffer(range, strokes):
                    self.monitor.replace(range: range, with: strokes, expectedGeneration: ctx.generation)
                }
            }
        }
    }

    /// Переключает системную раскладку на «другую» (главный поток).
    private func toggleLayout() {
        let set = LayoutSet(layouts: layouts().layouts, currentID: TIS.currentLayoutID())
        guard let cur = set.current, let next = set.target(from: cur) else { return }
        TIS.select(next)
        monitor.resetBuffer("layout-toggle")
    }

    // MARK: - Фоновый поток

    private func perform(_ ctx: Context) -> Outcome {
        let outcome = performInner(ctx)
        log.debug("trigger in \(ctx.bundleID, privacy: .public): buffer=\(ctx.buffer.count) word=\(Self.lastWordRange(ctx.buffer)?.count ?? 0) -> \(outcome.logName, privacy: .public)")
        return outcome
    }

    private func performInner(_ ctx: Context) -> Outcome {
        let element = AX.focusedElement()
        if let element, AX.isSecure(element) { return .nothing }

        // 1. Только что набранное слово (буфер не пуст ⇒ после набора ничего не выделяли:
        //    мышь, стрелки и сочетания клавиш буфер сбрасывают).
        if let range = Self.lastWordRange(ctx.buffer) {
            return convertBuffer(range, ctx)
        }
        if ctx.isTerminal {
            return convertTerminalSelection(element, ctx) ? .resetBuffer : .nothing
        }

        // 2. Выделенный текст.
        let axSelection = element.flatMap(AX.selectedText)
        if let sel = axSelection, !sel.isEmpty {
            return convertSelection(sel, ctx) ? .resetBuffer : .nothing
        }
        if axSelection == nil, let copied = Clipboard.copySelection(using: sender), !copied.isEmpty {
            let copiesLine = Self.lineCopyPrefixes.contains { ctx.bundleID.hasPrefix($0) }
            if copiesLine && copied.hasSuffix("\n") { return .nothing }
            return convertSelection(copied, ctx) ? .resetBuffer : .nothing
        }

        // 3. Слово перед курсором (курсор перемещали, буфер пуст).
        if Settings.fixWordBeforeCaret, let element, let (value, caret) = AX.valueAndCaret(element) {
            return convertWordBeforeCaret(value: value, caret: caret, ctx) ? .resetBuffer : .nothing
        }
        return .nothing
    }

    private func convertBuffer(_ range: Range<Int>, _ ctx: Context) -> Outcome {
        let strokes = Array(ctx.buffer[range])
        guard let lastLetter = strokes.last(where: { !$0.isSpace }),
              let from = ctx.layouts.layout(id: lastLetter.layoutID) ?? ctx.layouts.current,
              let to = ctx.layouts.target(from: from) else { return .nothing }

        let converted: [KeyStroke] = strokes.map { s in
            if s.isSpace { return s }
            let t = to.text(keyCode: s.keyCode, shift: s.shift, caps: s.caps) ?? s.text
            return KeyStroke(keyCode: s.keyCode, shift: s.shift, caps: s.caps, text: t, layoutID: to.id)
        }
        let oldText = strokes.map(\.text).joined()
        switchLayout(to)
        sender.backspace(oldText.count)
        sender.type(strokes: converted)
        return .replaceBuffer(range, converted)
    }

    private func convertSelection(_ text: String, _ ctx: Context) -> Bool {
        guard let from = ctx.layouts.detectSource(of: text),
              let to = ctx.layouts.target(from: from) else { return false }
        let converted = LayoutSet.convert(text, from: from, to: to)
        guard converted != text else { return false }

        switchLayout(to)
        let multiline = converted.contains { $0.isNewline || $0 == "\t" }
        if multiline || converted.count > 400 {
            Clipboard.paste(converted, using: sender)
        } else {
            sender.type(converted, layout: to) // набор поверх выделения заменяет его
            if Settings.keepSelection { sender.shiftLeft(converted.count) }
        }
        return true
    }

    /// Терминал: набор поверх выделения его не заменяет, поэтому выделенный фрагмент строки ввода
    /// стирается Backspace’ами от курсора и набирается заново.
    private func convertTerminalSelection(_ element: AXUIElement?, _ ctx: Context) -> Bool {
        var selection: String?
        if let element, let sel = AX.selectedText(element) {
            guard !sel.isEmpty else { return false }
            // Выделение в выводе выше строки ввода заменить нельзя.
            if AX.selectionIsOnLastLine(element) == false { NSSound.beep(); return false }
            selection = sel
        } else {
            selection = Clipboard.copySelection(using: sender)
        }
        guard var text = selection else { return false }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard !text.isEmpty, !text.contains(where: \.isNewline), text.count <= 200,
              let from = ctx.layouts.detectSource(of: text),
              let to = ctx.layouts.target(from: from) else { return false }
        let converted = LayoutSet.convert(text, from: from, to: to)
        guard converted != text else { return false }

        switchLayout(to)
        sender.backspace(text.count)
        sender.type(converted, layout: to)
        return true
    }

    private func convertWordBeforeCaret(value: String, caret: Int, _ ctx: Context) -> Bool {
        let prefix = (value as NSString).substring(to: caret)
        guard let (word, spaces) = Self.lastWord(in: prefix), word.count <= 64,
              let from = ctx.layouts.detectSource(of: word),
              let to = ctx.layouts.target(from: from) else { return false }
        let converted = LayoutSet.convert(word, from: from, to: to)
        guard converted != word else { return false }

        switchLayout(to)
        sender.backspace(word.count + spaces.count)
        sender.type(converted + spaces, layout: to)
        return true
    }

    private func switchLayout(_ layout: KeyboardLayout) {
        guard Settings.switchLayout else { return }
        DispatchQueue.main.sync { TIS.select(layout) }
        usleep(10_000)
    }

    // MARK: - Чистые функции (покрыты самотестом)

    /// Диапазон последнего слова в буфере вместе с пробелами после него.
    static func lastWordRange(_ strokes: [KeyStroke]) -> Range<Int>? {
        var i = strokes.count
        while i > 0 && strokes[i - 1].isSpace { i -= 1 }
        let wordEnd = i
        while i > 0 && !strokes[i - 1].isSpace { i -= 1 }
        guard i < wordEnd else { return nil }
        return i..<strokes.count
    }

    /// Последнее слово строки и пробелы после него.
    static func lastWord(in text: String) -> (String, String)? {
        var chars = Array(text.suffix(256))
        var spaces = ""
        while let last = chars.last, last == " " || last == "\u{00A0}" {
            spaces.insert(last, at: spaces.startIndex)
            chars.removeLast()
        }
        var word = ""
        while let last = chars.last, !last.isWhitespace {
            word.insert(last, at: word.startIndex)
            chars.removeLast()
        }
        return word.isEmpty ? nil : (word, spaces)
    }
}
