import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = KeyboardMonitor()
    private var converter: Converter!
    private var layoutSet = LayoutSet(layouts: [], currentID: "")
    private var watchdog: Timer?
    private var lastApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()

        // Не запускаем вторую копию.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        reloadLayouts()
        converter = Converter(monitor: monitor) { [unowned self] in self.layoutSet }
        lastApp = NSWorkspace.shared.frontmostApplication
        monitor.onControlTap = { [unowned self] in self.converter.trigger() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()

        observeSystem()

        _ = AX.isTrusted(prompt: true)
        ensureMonitor()
        // Сторож: подключает перехват после выдачи разрешения и восстанавливает его, если система его отключила.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.ensureMonitor() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    // MARK: - Система

    private func observeSystem() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(inputSourceChanged),
                        name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        dnc.addObserver(self, selector: #selector(enabledSourcesChanged),
                        name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil)

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(appActivated(_:)),
                        name: NSWorkspace.didActivateApplicationNotification, object: nil)
        wnc.addObserver(self, selector: #selector(didWake),
                        name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func inputSourceChanged() {
        layoutSet = LayoutSet(layouts: layoutSet.layouts, currentID: TIS.currentLayoutID())
        if layoutSet.current == nil { reloadLayouts() }
        updateStatusTitle()
    }

    @objc private func enabledSourcesChanged() {
        reloadLayouts()
        updateStatusTitle()
    }

    @objc private func appActivated(_ note: Notification) {
        monitor.resetBuffer()
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastApp = app
        AX.enableManualAccessibility(pid: app.processIdentifier)
    }

    @objc private func didWake() {
        monitor.stop()
        ensureMonitor()
    }

    private func reloadLayouts() {
        layoutSet = TIS.loadLayoutSet()
    }

    private func ensureMonitor() {
        guard !monitor.isRunning else { return }
        if AX.isTrusted(prompt: false) { monitor.start() }
        updateStatusTitle()
    }

    // MARK: - Строка меню

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let name = layoutSet.current?.shortName ?? "⌨︎"
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

        // Цвета — только системные адаптивные, чтобы значок был виден и на светлой, и на тёмной строке меню.
        var symbol: NSImage?
        let titleColor: NSColor
        if !monitor.isRunning {
            symbol = Self.symbol("exclamationmark.triangle.fill", color: .systemOrange,
                                 description: "Нет доступа")
            titleColor = .labelColor
            button.toolTip = "PintoSwitcher: нет доступа к «Универсальному доступу» — откройте меню"
        } else if !Settings.enabled {
            symbol = Self.symbol("pause.circle", color: .secondaryLabelColor, description: "Выключено")
            titleColor = .secondaryLabelColor
            button.toolTip = "PintoSwitcher выключен"
        } else {
            titleColor = .labelColor
            button.toolTip = "PintoSwitcher: Control — исправить текст или сменить раскладку"
        }
        button.image = symbol
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        button.attributedTitle = NSAttributedString(string: (symbol == nil ? "" : " ") + name, attributes: [
            .font: font,
            .foregroundColor: titleColor,
        ])
    }

    private static func symbol(_ name: String, color: NSColor, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "PintoSwitcher", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if !AX.isTrusted(prompt: false) {
            menu.addItem(item("⚠️ Нет доступа — нажмите, чтобы разрешить", #selector(requestAccess)))
        } else if !monitor.isRunning {
            menu.addItem(item("⚠️ Перехват клавиатуры не запущен — повторить", #selector(requestAccess)))
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Включено", Settings.enabled, #selector(toggleEnabled)))
        menu.addItem(toggle("Переключать раскладку после исправления", Settings.switchLayout, #selector(toggleSwitchLayout)))
        menu.addItem(toggle("Оставлять выделение после исправления", Settings.keepSelection, #selector(toggleKeepSelection)))
        menu.addItem(toggle("Исправлять слово перед курсором", Settings.fixWordBeforeCaret, #selector(toggleWordBeforeCaret)))

        let keyMenu = NSMenu()
        for (value, title) in [("right", "Правый Control"), ("left", "Левый Control"), ("any", "Любой Control")] {
            let i = toggle(title, Settings.controlKey == value, #selector(selectControlKey(_:)))
            i.representedObject = value
            keyMenu.addItem(i)
        }
        let keyTitle = ["right": "правый", "left": "левый", "any": "любой"][Settings.controlKey] ?? "правый"
        let keyItem = NSMenuItem(title: "Клавиша: \(keyTitle) Control", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        if let app = lastApp, let id = app.bundleIdentifier {
            menu.addItem(.separator())
            let name = app.localizedName ?? id
            let ex = toggle("Не работать в «\(name)»", Settings.excluded.contains(id), #selector(toggleExcluded(_:)))
            ex.representedObject = id
            menu.addItem(ex)
        }
        let excluded = Settings.excluded
        if !excluded.isEmpty {
            let sub = NSMenu()
            for id in excluded.sorted() {
                let i = item(id, #selector(removeExcluded(_:)))
                i.representedObject = id
                i.toolTip = "Нажмите, чтобы убрать из исключений"
                sub.addItem(i)
            }
            let parent = NSMenuItem(title: "Исключения (\(excluded.count))", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Запускать при входе в систему", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))

        menu.addItem(.separator())
        let layouts = layoutSet.layouts.map(\.name).joined(separator: " · ")
        let info = NSMenuItem(title: "Раскладки: \(layouts.isEmpty ? "—" : layouts)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let hint = NSMenuItem(title: "Control ×1 — исправить слово/выделение или сменить раскладку", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    // MARK: - Действия

    @objc private func requestAccess() {
        _ = AX.isTrusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        monitor.stop()
        ensureMonitor()
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        monitor.resetBuffer()
        updateStatusTitle()
    }

    @objc private func toggleSwitchLayout() { Settings.switchLayout.toggle() }
    @objc private func toggleKeepSelection() { Settings.keepSelection.toggle() }
    @objc private func toggleWordBeforeCaret() { Settings.fixWordBeforeCaret.toggle() }
    @objc private func selectControlKey(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        Settings.controlKey = value
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var set = Settings.excluded
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        Settings.excluded = set
    }

    @objc private func removeExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var set = Settings.excluded
        set.remove(id)
        Settings.excluded = set
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
            NSLog("PintoSwitcher: login item error: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
