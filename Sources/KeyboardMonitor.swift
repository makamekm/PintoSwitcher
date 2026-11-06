import AppKit
import Carbon

/// Глобальный перехват клавиатуры (только чтение, события не блокируются).
/// Ведёт буфер набранных символов и ловит одиночное нажатие Control.
final class KeyboardMonitor {
    /// Вызывается в главном потоке после одиночного нажатия Control.
    var onControlTap: (() -> Void)?

    private(set) var buffer: [KeyStroke] = []
    /// Растёт при каждом изменении буфера пользователем.
    private(set) var generation = 0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var ctrlDownAt: TimeInterval?
    private var ctrlInterrupted = false

    private static let maxBuffer = 256
    private static let maxTapDuration: TimeInterval = 0.6

    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        stop()
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: keyboardTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    func resetBuffer() {
        if !buffer.isEmpty { buffer.removeAll(keepingCapacity: true) }
        generation += 1
    }

    /// Заменяет часть буфера результатом конвертации (если пользователь ничего не успел набрать).
    func replace(range: Range<Int>, with strokes: [KeyStroke], expectedGeneration: Int) {
        guard generation == expectedGeneration, range.upperBound <= buffer.count else {
            resetBuffer()
            return
        }
        buffer.replaceSubrange(range, with: strokes)
        generation += 1
    }

    // MARK: - Обработка событий (главный поток)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        default:
            break
        }
        // Собственные синтетические события игнорируем.
        if event.getIntegerValueField(.eventSourceUserData) == KeySender.marker { return }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ctrlInterrupted = true
            resetBuffer()
        case .scrollWheel:
            if ctrlDownAt != nil { ctrlInterrupted = true } // Control+прокрутка (масштаб) — не нажатие
        case .keyDown:
            ctrlInterrupted = true
            handleKeyDown(event)
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Любое сочетание с Cmd/Ctrl/Option — это команда, а не набор текста.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            resetBuffer()
            return
        }

        switch keyCode {
        case 51: // Backspace
            if !buffer.isEmpty { buffer.removeLast(); generation += 1 }
            return
        case 36, 76, 48, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126:
            // Enter, Tab, Esc, Forward Delete, Home, End, PageUp/Down, стрелки
            resetBuffer()
            return
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let text = String(utf16CodeUnits: chars, count: min(length, chars.count))
        guard KeyboardLayout.isPrintable(text) else {
            resetBuffer()
            return
        }

        buffer.append(KeyStroke(keyCode: keyCode,
                                shift: flags.contains(.maskShift),
                                caps: flags.contains(.maskAlphaShift),
                                text: text,
                                layoutID: TIS.currentLayoutID()))
        if buffer.count > Self.maxBuffer { buffer.removeFirst(buffer.count - Self.maxBuffer) }
        generation += 1
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime

        guard keyCode == 59 || keyCode == 62 else { // не Control
            if keyCode != 57 && ctrlDownAt != nil { ctrlInterrupted = true } // Caps Lock не мешает
            return
        }

        if flags.contains(.maskControl) {
            if ctrlDownAt != nil { ctrlInterrupted = true; return } // нажат второй Control
            let others: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
            ctrlDownAt = now
            ctrlInterrupted = !flags.intersection(others).isEmpty
                || (Settings.controlKeyCode.map { $0 != keyCode } ?? false)
        } else {
            defer { ctrlDownAt = nil; ctrlInterrupted = false }
            guard let downAt = ctrlDownAt, !ctrlInterrupted, now - downAt < Self.maxTapDuration else { return }
            onControlTap?()
        }
    }
}

private func keyboardTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
