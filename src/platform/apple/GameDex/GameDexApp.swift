// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit

@main
struct GameDexApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!, model: GameModel!, monitor: Any?
    var transitioning = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let testIndex = args.firstIndex(of: "--self-test")
        let testDirectory = testIndex.map { URL(fileURLWithPath: args[$0 + 1], isDirectory: true) }
        model = GameModel(libraryOverride: testDirectory?.appendingPathComponent("recordings"))
        updateDisplaySizing(NSScreen.main)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: model.desktopShellWidth, height: model.desktopShellHeight), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GameDex Pocket"; window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: GameDexView(model: model))
        window.center(); window.isReleasedWhenClosed = false
        model.resize = { [weak self] _ in self?.applyWindowGeometry() }
        model.changeDesktopLayout = { [weak self] in self?.applyWindowGeometry() }
        model.toggleDesktopFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        applyWindowGeometry()
        let menu = NSMenu(), appMenu = NSMenu(), item = NSMenuItem()
        item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "Quit GameDex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let viewItem = NSMenuItem(), viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu; menu.addItem(viewItem)
        viewMenu.addItem(withTitle: "Original Screen Size (1×)", action: #selector(originalSize), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Double Screen Size (2×)", action: #selector(doubleSize), keyEquivalent: "2")
        let fullScreen = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        NSApp.mainMenu = menu
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window.isKeyWindow, !self.model.showingMenu, !self.model.showingLibrary, !self.model.showingSessions, !self.model.showingPlayback, !self.model.importing,
                  !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return event }
            if event.type == .keyDown && event.keyCode == 53 && self.model.desktopFullScreen {
                self.window.toggleFullScreen(nil); return nil
            }
            let source = "keyboard-\(event.keyCode)"
            // Physical key codes pair press/release even if modifiers change while held.
            if event.type == .keyUp { self.model.release(source); return event }
            guard let mask = GameModel.keyboard(event.charactersIgnoringModifiers ?? "", shift: event.modifierFlags.contains(.shift)) else { return event }
            if !event.isARepeat { self.model.hold(source, mask) }; return nil
        }
        if let rom = args.firstIndex(of: "--rom"), rom + 1 < args.count { model.load(URL(fileURLWithPath: args[rom + 1])) }
        else { model.restore() }
        if args.contains("--pause-test"), testDirectory != nil { runPauseTest(); return }
        if args.contains("--menu-actions-test"), testDirectory != nil { runMenuActionsTest(); return }
        // Render a layout preview without taking focus or exercising window modes.
        if let index = args.firstIndex(of: "--layout-preview"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            if args.contains("--preview-2x") { model.setDesktopScale(2) }
            if args.contains("--preview-expanded") { model.expand() }
            if args.contains("--menu") { model.openMenu() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.snapshot(url); NSApp.terminate(nil)
            }
            return
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let testDirectory { runTest(testDirectory) }
    }
    func updateDisplaySizing(_ screen: NSScreen?) {
        guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let millimeters = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        let width = 61.2 * screen.frame.width / millimeters.width
        if millimeters.width > 100 && millimeters.width < 3000 && width.isFinite && width > 50 && width < 1500 {
            model.desktopBaseGameWidth = width
            model.displaySizingNote = "Based on \(screen.localizedName)’s reported dimensions"
        } else {
            model.desktopBaseGameWidth = 308
            model.displaySizingNote = "Display dimensions unavailable; using an approximate size"
        }
    }
    func applyWindowGeometry() {
        guard let window, !transitioning, !model.desktopFullScreen else { return }
        let visible = (window.screen ?? NSScreen.main)!.visibleFrame
        let desired = window.frameRect(forContentRect: NSRect(x: 0, y: 0,
            width: model.desktopShellWidth + (model.expanded ? 320 : 0), height: model.desktopShellHeight))
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: min(desired.width, visible.width), height: min(desired.height, visible.height))
        frame.origin.y = min(max(top - frame.height, visible.minY), visible.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true)
    }
    @objc func originalSize() { model.setDesktopScale(1) }
    @objc func doubleSize() { model.setDesktopScale(2) }
    @objc func toggleFullScreen() { window.toggleFullScreen(nil) }
    func windowDidChangeScreen(_ notification: Notification) { updateDisplaySizing(window.screen); applyWindowGeometry() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDisplaySizing(window.screen); applyWindowGeometry() }
    func windowWillEnterFullScreen(_ notification: Notification) { transitioning = true; model.desktopFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { transitioning = false }
    func windowWillExitFullScreen(_ notification: Notification) { transitioning = true }
    func windowDidExitFullScreen(_ notification: Notification) { transitioning = false; model.desktopFullScreen = false; applyWindowGeometry() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { transitioning = false; model.desktopFullScreen = false; applyWindowGeometry() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transitioning = false; model.desktopFullScreen = true }
    func windowDidResignKey(_ notification: Notification) { model.focus(false) }
    func windowDidBecomeKey(_ notification: Notification) { model.focus(true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.emulator.close(); if let monitor { NSEvent.removeMonitor(monitor) } }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { if let file = filenames.first { model.load(URL(fileURLWithPath: file)) }; sender.reply(toOpenOrPrint: .success) }
    func runMenuActionsTest() {
        model.focus(true); model.emulator.toggleRecording()
        var normalTime = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            normalTime = self.model.seconds
            self.model.openMenu(); self.model.saveState()
            assert(self.model.stateAvailable && self.model.menuNotice == "State saved")
            self.model.loadState()
            assert(self.model.menuNotice == "State loaded" && self.model.isPaused)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            assert(!self.model.recording, "Loading state must finalize the previous take")
            self.model.toggleFastForward(); self.model.resumeGame(); self.model.emulator.toggleRecording()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            assert(self.model.seconds > normalTime * 1.4, "Fast forward did not speed up emulation")
            self.model.openMenu(); self.model.toggleFastForward()
            assert(!self.model.fastForward && self.model.isPaused)
            self.model.emulator.close()
            print("PASS: quick save/load, recording finalization before rewind, 2× fast forward and normal-speed toggle")
            NSApp.terminate(nil)
        }
    }
    func runPauseTest() {
        model.focus(true)
        model.emulator.toggleRecording()
        var stoppedTime = 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.model.hold("test", 1)
            self.model.openMenu()
            assert(self.model.isPaused && self.model.pressed == 0)
            self.model.hold("test", 2)
            assert(self.model.pressed == 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { stoppedTime = self.model.seconds }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            assert(stoppedTime > 0 && self.model.seconds == stoppedTime, "Menu did not freeze emulation")
            self.model.focus(false); self.model.focus(true)
            assert(self.model.isPaused, "Focus changes dismissed the pause menu")
            self.model.resumeGame()
            assert(!self.model.isPaused)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            assert(self.model.seconds > stoppedTime + 0.1, "Resume did not restart emulation")
            self.model.emulator.close()
            print("PASS: Menu freezes game time, clears and blocks inputs, survives focus changes, and Resume restarts emulation")
            NSApp.terminate(nil)
        }
    }
    func runTest(_ directory: URL) {
        assert(GameModel.keyboard("w") == 64 && GameModel.keyboard("a") == 32 && GameModel.keyboard("s") == 128 && GameModel.keyboard("d") == 16)
        assert(GameModel.keyboard("\r") == 1 && GameModel.keyboard(" ") == 2 && GameModel.keyboard("x") == 8 && GameModel.keyboard("z") == 4 && GameModel.keyboard("\t") == nil)
        func later(_ seconds: Double, _ body: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body) }
        later(1) { self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); self.model.focus(true); self.model.emulator.toggleRecording() }
        let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [("w", 13, []), ("a", 0, []), ("s", 1, []), ("d", 2, []), ("\r", 36, []), (" ", 49, []), ("x", 7, []), ("z", 6, []), ("q", 12, []), ("e", 14, [])]
        for (index, key) in keys.enumerated() {
            later(1.2 + Double(index) * 0.2) { self.postKey(key, down: true) }
            later(1.3 + Double(index) * 0.2) { self.postKey(key, down: false) }
        }
        later(3.5) { self.snapshot(directory.appendingPathComponent("recording.png")) }
        later(4) { self.model.emulator.toggleRecording(); self.model.pause() }
        later(4.5) {
            self.snapshot(directory.appendingPathComponent("collapsed.png"))
            let before = self.window.frame; self.model.expand()
            assert(self.window.frame.minX == before.minX && self.window.frame.height == before.height)
        }
        later(5) { self.snapshot(directory.appendingPathComponent("expanded.png")); self.model.expand(); self.model.pause(); self.model.emulator.toggleRecording() }
        later(7) {
            self.model.emulator.close()
            let width = self.model.desktopGameWidth
            self.model.setDesktopScale(2)
            assert(abs(self.model.desktopGameWidth - 2 * width) < 0.001)
            self.snapshot(directory.appendingPathComponent("double.png"))
            self.model.setDesktopScale(1)
            print("PASS: Apple shell input mapping, anchored expansion, 2× sizing, screenshots, recording and shutdown")
            NSApp.terminate(nil)
        }
    }

    func postKey(_ key: (String, UInt16, NSEvent.ModifierFlags), down: Bool) {
        if let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: key.2,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: key.0, charactersIgnoringModifiers: key.0, isARepeat: false, keyCode: key.1) {
            NSApp.postEvent(event, atStart: false)
        }
    }
    func snapshot(_ url: URL) {
        let view = HStack(spacing: 0) {
            Handheld(model: model).frame(width: model.desktopShellWidth, height: model.desktopShellHeight)
            if model.expanded { Details(model: model).content.frame(width: 320, height: model.desktopShellHeight, alignment: .top).clipped() }
        }.frame(width: model.desktopShellWidth + (model.expanded ? 320 : 0), height: model.desktopShellHeight).preferredColorScheme(.light)
        if url.lastPathComponent == "collapsed.png" {
            let dimensions = ["width": Int(model.desktopShellWidth * 2), "height": Int(model.desktopShellHeight * 2)]
            try? JSONSerialization.data(withJSONObject: dimensions).write(to: url.deletingLastPathComponent().appendingPathComponent("layout.json"))
        }
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        if let image = renderer.cgImage {
            let bitmap = NSBitmapImageRep(cgImage: image)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#else
@main
struct GameDexApp: App {
    @StateObject private var model = GameModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            GameDexView(model: model)
                .onAppear {
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    try? AVAudioSession.sharedInstance().setActive(true)
                    let args = CommandLine.arguments
                    if let index = args.firstIndex(of: "--rom"), index + 1 < args.count { model.load(URL(fileURLWithPath: args[index + 1])) }
                    else { model.restore() }
                    if args.contains("--menu") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openMenu() }
                    }
                    if args.contains("--recordings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingSessions = true }
                    }
                    if args.contains("--settings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingLibrary = true }
                    }
                    if args.contains("--capture-test") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.emulator.toggleRecording(); model.hold("test", 1) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.release("test"); model.hold("test", 16) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.release("test") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { model.emulator.toggleRecording(); model.pause() }
                    }
                }
                .onChange(of: phase) { _, phase in
                    model.focus(phase == .active)
                    if phase == .background && model.recording { model.emulator.toggleRecording() }
                }
        }
    }
}
#endif
