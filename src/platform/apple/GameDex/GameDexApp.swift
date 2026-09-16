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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let testIndex = args.firstIndex(of: "--self-test")
        let testDirectory = testIndex.map { URL(fileURLWithPath: args[$0 + 1], isDirectory: true) }
        model = GameModel(libraryOverride: testDirectory?.appendingPathComponent("recordings"))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 780), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "GameDex Pocket"; window.delegate = self
        window.contentView = NSHostingView(rootView: GameDexView(model: model))
        window.center(); window.isReleasedWhenClosed = false
        model.resize = { [weak self] expanded in
            guard let window = self?.window else { return }
            var frame = window.frame
            frame.size.width = expanded ? 680 : 360
            // Keep the left edge, vertical position and handheld dimensions fixed.
            window.setFrame(frame, display: true, animate: false)
        }
        let menu = NSMenu(), appMenu = NSMenu(), item = NSMenuItem()
        item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "Quit GameDex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window.isKeyWindow, !self.model.showingLibrary, !self.model.importing,
                  !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return event }
            let source = "keyboard-\(event.keyCode)"
            // Key codes keep release paired correctly when Shift changes before Tab is released.
            if event.type == .keyUp { self.model.release(source); return event }
            guard let mask = GameModel.keyboard(event.charactersIgnoringModifiers ?? "", shift: event.modifierFlags.contains(.shift)) else { return event }
            if !event.isARepeat { self.model.hold(source, mask) }; return nil
        }
        if let rom = args.firstIndex(of: "--rom"), rom + 1 < args.count { model.load(URL(fileURLWithPath: args[rom + 1])) }
        else { model.restore() }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let testDirectory { runTest(testDirectory) }
    }
    func windowDidResignKey(_ notification: Notification) { model.focus(false) }
    func windowDidBecomeKey(_ notification: Notification) { model.focus(true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.emulator.close(); if let monitor { NSEvent.removeMonitor(monitor) } }
    func application(_ sender: NSApplication, openFiles filenames: [String]) { if let file = filenames.first { model.load(URL(fileURLWithPath: file)) }; sender.reply(toOpenOrPrint: .success) }
    func runTest(_ directory: URL) {
        assert(GameModel.keyboard("w") == 64 && GameModel.keyboard("a") == 32 && GameModel.keyboard("s") == 128 && GameModel.keyboard("d") == 16)
        assert(GameModel.keyboard("\r") == 1 && GameModel.keyboard(" ") == 2 && GameModel.keyboard("\t") == 8 && GameModel.keyboard("\t", shift: true) == 4)
        func later(_ seconds: Double, _ body: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body) }
        later(1) { self.model.emulator.toggleRecording() }
        let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [("w", 13, []), ("a", 0, []), ("s", 1, []), ("d", 2, []), ("\r", 36, []), (" ", 49, []), ("\t", 48, []), ("\t", 48, [.shift]), ("q", 12, []), ("e", 14, [])]
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
        later(7) { self.model.emulator.close(); print("PASS: Apple shell input mapping, anchored expansion, screenshots, recording and shutdown"); NSApp.terminate(nil) }
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
            Handheld(model: model).frame(width: 390, height: 845).scaleEffect(360.0 / 390, anchor: .topLeading).frame(width: 360, height: 780, alignment: .topLeading)
            if model.expanded { Details(model: model).content.frame(width: 320, height: 780, alignment: .top).clipped() }
        }.frame(width: model.expanded ? 680 : 360, height: 780).preferredColorScheme(.light)
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
