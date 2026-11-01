import AppKit
import ClipboardCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences = Preferences.shared
    private var store: ClipStore!
    private var writer: PasteboardWriter!
    private var monitor: ClipboardMonitor!
    private var enricher: ClipEnricher!
    private var coordinator: PasteCoordinator!
    private var stack: StackController!
    private var panel: PanelController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!
    private var maintenanceTimer: Timer?
    private var statusFlash: DispatchWorkItem?
    private let toast = ToastController()
    #if DEBUG
    private var testControl: TestControl?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if AppEnvironment.isDemo {
            DemoRunner.start()
            return
        }
        #endif
        if ProcessInfo.processInfo.environment["CLIPBOARD_DATA_DIR"] == nil, let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        do {
            store = try ClipStore()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Clipboard can't open its history"
            alert.informativeText = "\(error)\n\nCheck that your Library folder is writable, then open Clipboard again."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        installMainMenu()
        FocusTracker.shared.start()
        writer = PasteboardWriter(store: store)
        enricher = ClipEnricher(store: store, preferences: preferences)
        coordinator = PasteCoordinator(store: store, writer: writer, preferences: preferences, toast: toast)
        stack = StackController(writer: writer, toast: toast)
        coordinator.stack = stack
        settings = SettingsWindowController(store: store)
        monitor = ClipboardMonitor(store: store, writer: writer, preferences: preferences)
        monitor.onCapture = { [weak self] result in
            guard let self else { return }
            self.enricher.process(result)
            self.flashStatusIcon()
            if self.stack.isActive { self.stack.add(result.clip) }
        }

        let model = PanelModel(store: store)
        panel = PanelController(model: model)
        model.actions = PanelActions(
            paste: { [weak self] clip, invert in
                guard let self else { return }
                let target = model.targetApp
                withAnimation(.easeIn(duration: 0.13)) { model.flyingClipID = clip.id }
                // ⌘V has to wait until the shelf is gone and the target app has the keyboard back.
                self.panel.hide { self.coordinator.paste(clip, invertFormatting: invert, into: target) }
            },
            copy: { [weak self] clip in
                self?.coordinator.copy(clip)
                self?.panel.hide()
            },
            close: { [weak self] in self?.panel.hide() },
            openSettings: { [weak self] in self?.openSettings() },
            toggleStack: { [weak self] in self?.stack.toggle() },
            addToStack: { [weak self] clip in self?.stack.add(clip) },
            requestDirectPaste: { [weak self] in
                self?.panel.hide()
                Paster.requestTrust()
            },
            resumeCapture: { [weak self] in
                self?.preferences.isPaused = false
            })
        stack.onChange = { isActive, count in
            model.isStackActive = isActive
            model.stackCount = count
        }

        preferences.onShortcutsChanged = { [weak self] in self?.registerHotKeys() }
        preferences.onRetentionChanged = { [weak self] in self?.applyRetention() }
        preferences.onPausedChanged = { [weak self] in
            guard let self else { return }
            self.refreshStatusIcon()
            model.isCapturePaused = self.preferences.isPaused
        }
        registerHotKeys()
        installStatusItem()
        monitor.start()
        runMaintenance()

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer

        if !preferences.hasShownWelcome {
            preferences.hasShownWelcome = true
            settings.show()
        } else {
            // Starting from Finder or Spotlight activates the app, but there's no window to type into.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if FocusTracker.shared.isPasteFrontmost { FocusTracker.shared.returnFocus() }
            }
        }
        #if DEBUG
        testControl = TestControl(panel: panel, stack: stack, settings: settings)
        testControl?.start()
        #endif
    }

    /// Opening the app while it's already running behaves like the shortcut, which gives Spotlight a way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.toggle()
        return false
    }

    private func registerHotKeys() {
        let skipCombos = AppEnvironment.isHeadless || preferences.isRecordingShortcut
        let openRegistered = HotKeyCenter.shared.register(id: HotKeyID.open, combo: skipCombos ? nil : preferences.openShortcut) { [weak self] in
            self?.panel.toggle()
        }
        let stackRegistered = HotKeyCenter.shared.register(id: HotKeyID.stack, combo: skipCombos ? nil : preferences.stackShortcut) { [weak self] in
            self?.stack.toggle()
        }
        if !openRegistered || !stackRegistered {
            toast.show("Another app is using that shortcut. Choose a different one in Settings.", symbol: "exclamationmark.triangle.fill")
        }
    }

    private func runMaintenance() {
        let store = store!
        let cutoff = retentionCutoff
        Task.detached(priority: .background) {
            _ = try? store.sweepOrphans()
            if let cutoff { _ = try? store.prune(before: cutoff) }
            try? store.trimPasteEvents(before: Date().addingTimeInterval(-180 * 86400))
        }
    }

    private func applyRetention() {
        guard let cutoff = retentionCutoff else { return }
        let store = store!
        Task.detached(priority: .utility) {
            _ = try? store.prune(before: cutoff)
            await MainActor.run { NotificationCenter.default.post(name: .clipsChanged, object: nil) }
        }
    }

    private var retentionCutoff: Date? {
        guard preferences.retentionDays > 0 else { return nil }
        return Date().addingTimeInterval(-Double(preferences.retentionDays) * 86400)
    }

    private func openSettings() {
        panel.hide(animated: false)
        settings.show()
    }

    // MARK: Menus

    private func installMainMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Clipboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)

        // Text fields only get ⌘C, ⌘V and friends through a main menu, even one the user never sees.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        NSApp.mainMenu = menu
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshStatusIcon() {
        statusFlash?.cancel()
        statusItem?.button?.image = preferences.isPaused
            ? NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Clipboard, paused")
            : StatusGlyph.make()
    }

    /// A brief check in the menu bar confirms a copy was saved, without taking the user's eyes off their work.
    private func flashStatusIcon() {
        statusFlash?.cancel()
        statusItem?.button?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Saved")
        let work = DispatchWorkItem { [weak self] in self?.refreshStatusIcon() }
        statusFlash = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = preferences.openShortcut.map { " (\($0.display))" } ?? ""
        addItem(to: menu, "Open Clipboard\(shortcut)", #selector(openPanel))
        addItem(to: menu, stack.isActive ? "End Paste Stack" : "Start Paste Stack", #selector(toggleStack))
        menu.addItem(.separator())
        addItem(to: menu, preferences.isPaused ? "Resume Saving Clips" : "Pause Saving Clips", #selector(togglePause))
        addItem(to: menu, "Settings…", #selector(showSettings))
        menu.addItem(.separator())
        addItem(to: menu, "Quit Clipboard", #selector(quit))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPanel() { panel.show() }
    @objc private func toggleStack() { stack.toggle() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func togglePause() {
        preferences.isPaused.toggle()
    }
}
