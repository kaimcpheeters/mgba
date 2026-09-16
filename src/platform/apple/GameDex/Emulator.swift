// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import AVFoundation

final class Emulator {
    private let queue = DispatchQueue(label: "GameDex.emulation", qos: .userInteractive)
    private var core: OpaquePointer?, timer: DispatchSourceTimer?, recorder: Recorder?
    private var keys: UInt32 = 0, paused = false, ticks = 0
    private var fastForward = false
    private var player = AVAudioPlayerNode(), audio = AVAudioEngine(), audioRate = 0.0, queuedAudio = 0
    var onFrame: ((CGImage, Double) -> Void)?
    var onStatus: ((Bool, String?) -> Void)?
    let library: URL
    init(library: URL) { self.library = library }
    func load(_ url: URL, save: URL) throws -> String {
        try queue.sync {
            closeCore()
            guard let loaded = gd_create(url.path, save.path) else { throw Recorder.Failure(message: "Could not load this GBA ROM") }
            core = loaded; gd_frame(loaded, 0)
            let title = String(cString: gd_title(loaded))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Double(280896) / Double(16777216) / (fastForward ? 2 : 1), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.step() }; timer.resume(); self.timer = timer
            return title
        }
    }
    func setKeys(_ mask: UInt32) { queue.async { self.keys = mask } }
    func setPaused(_ value: Bool) { queue.async { self.paused = value; if value { self.keys = 0; self.player.pause() } else if self.audio.isRunning { self.player.play() } } }
    func setFastForward(_ enabled: Bool) {
        queue.async {
            self.fastForward = enabled
            self.timer?.schedule(deadline: .now(), repeating: Double(280896) / Double(16777216) / (enabled ? 2 : 1), leeway: .milliseconds(1))
            self.player.stop(); self.queuedAudio = 0
            if !enabled && !self.paused && self.audio.isRunning { self.player.play() }
        }
    }
    func saveState(_ url: URL) throws {
        try queue.sync {
            guard let core else { throw Recorder.Failure(message: "Open a game first") }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".state")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard gd_save_state(core, temporary.path) != 0 else { throw Recorder.Failure(message: "Could not save state") }
            try Data(contentsOf: temporary).write(to: url, options: .atomic)
        }
    }
    func loadState(_ url: URL) throws {
        try queue.sync {
            guard let core, FileManager.default.fileExists(atPath: url.path) else { throw Recorder.Failure(message: "No saved state for this game") }
            // A rewind must never share the previous recording's monotonic timeline.
            stopRecording()
            guard gd_load_state(core, url.path) != 0 else { throw Recorder.Failure(message: "Could not load this state") }
            keys = 0; player.stop(); queuedAudio = 0
            var discarded = [Int16](repeating: 0, count: 8192)
            while gd_audio(core, &discarded, 4096) > 0 {}
            publishFrame(core)
        }
    }
    private func bytes(_ core: OpaquePointer) -> Data { Data(bytes: gd_pixels(core), count: 240 * 160 * 4) }
    private func step() {
        guard let core, !paused else { return }
        autoreleasepool {
            gd_frame(core, keys)
            let pixels = bytes(core)
            var samples = [Int16](repeating: 0, count: 8192)
            let count = gd_audio(core, &samples, 4096); samples.removeLast(samples.count - count * 2)
            let rate = Double(gd_audio_rate(core))
            if !fastForward { play(samples, rate: rate) }
            if let recorder {
                do {
                    if gd_poll_overflow(core) != 0 { throw Recorder.Failure(message: "Input poll buffer overflow") }
                    var n = 0; let polls = gd_polls(core, &n)
                    try recorder.step(pixels: pixels, absoluteCycle: gd_cycle(core), samples: samples, sampleRate: rate,
                                      inputPolls: UnsafeBufferPointer(start: polls, count: n))
                } catch { stopRecording(error: error.localizedDescription) }
            }
            publishFrame(core)
        }
    }
    private func publishFrame(_ core: OpaquePointer) {
        let pixels = bytes(core)
        if let provider = CGDataProvider(data: pixels as CFData), let image = CGImage(width: 240, height: 160,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 960, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            let seconds = recorder?.seconds ?? 0
            DispatchQueue.main.async { [weak self] in self?.onFrame?(image, seconds) }
        }
    }
    private func play(_ samples: [Int16], rate: Double) {
        guard !samples.isEmpty else { return }
        if rate != audioRate {
            player.stop(); audio.stop(); audio = AVAudioEngine(); player = AVAudioPlayerNode(); queuedAudio = 0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
            audio.attach(player); audio.connect(player, to: audio.mainMixerNode, format: format)
            do { try audio.start(); player.play(); audioRate = rate } catch { return }
        }
        if !audio.isRunning {
            do { try audio.start(); player.play() } catch { return }
        }
        guard queuedAudio < 8, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<samples.count / 2 { channels[0][i] = Float(samples[i * 2]) / 32768; channels[1][i] = Float(samples[i * 2 + 1]) / 32768 }
        queuedAudio += 1
        player.scheduleBuffer(buffer) { [weak self] in guard let self else { return }; self.queue.async { self.queuedAudio = max(0, self.queuedAudio - 1) } }
    }
    func toggleRecording() {
        queue.async {
            if self.recorder != nil { self.stopRecording(); return }
            guard let core = self.core else { return }
            do {
                self.recorder = try Recorder(library: self.library, title: String(cString: gd_title(core)),
                    pixels: self.bytes(core), cycle: gd_cycle(core), keys: gd_sampled_keys(core))
                DispatchQueue.main.async { self.onStatus?(true, nil) }
            } catch { DispatchQueue.main.async { self.onStatus?(false, error.localizedDescription) } }
        }
    }
    private func stopRecording(error: String? = nil) {
        guard let recorder else { return }; self.recorder = nil
        var failure = error
        do { try recorder.finish(error: error) } catch { failure = error.localizedDescription }
        let message = failure
        DispatchQueue.main.async { self.onStatus?(false, message) }
    }
    private func closeCore() {
        timer?.cancel(); timer = nil; stopRecording(); player.stop(); audio.stop(); audioRate = 0
        if let core { gd_destroy(core); self.core = nil }
    }
    func close() { queue.sync { closeCore() } }
    deinit { closeCore() }
}

struct Take: Identifiable {
    let id: URL, title: String, date: String, seconds: Double, complete: Bool
    let frames: Int?
    let status: String
    var video: URL { id.appendingPathComponent("video.mp4") }
    var displayDate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: date) ?? ISO8601DateFormatter().date(from: date)
        return parsed?.formatted(date: .abbreviated, time: .shortened) ?? date
    }
    var duration: String {
        seconds < 60 ? String(format: "%.1fs", seconds) : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}
final class GameModel: ObservableObject {
    @Published var image: CGImage?
    @Published var title = "Your next adventure"
    @Published var loaded = false
    @Published var recording = false
    @Published var paused = false
    @Published var expanded = false
    @Published var showingMenu = false
    @Published var fastForward = false
    @Published var stateAvailable = false
    @Published var menuNotice: String?
    private var stateURL: URL?
    @Published var showingLibrary = false
    @Published var showingSessions = false
    @Published var showingPlayback = false
    @Published var importing = false
    @Published var seconds = 0.0
    @Published var pressed: UInt32 = 0
    @Published var message: String?
    @Published var takes: [Take] = []
    @Published var recentROMPaths: [String] = []
    private var recentROMs: RecentROMs
    @Published var desktopBaseGameWidth: CGFloat = 308
    @Published var desktopScale = 1
    @Published var desktopFullScreen = false
    @Published var displaySizingNote = "Based on display-reported dimensions"
    var desktopGameWidth: CGFloat { desktopBaseGameWidth * CGFloat(desktopScale) }
    var desktopShellWidth: CGFloat { max(354, desktopGameWidth + 32 * CGFloat(desktopScale) + 12) }
    var desktopShellHeight: CGFloat { max(680, max(354, desktopBaseGameWidth + 44) * 19.5 / 9) + (desktopGameWidth - desktopBaseGameWidth) / 1.5 + 82 * CGFloat(desktopScale - 1) }
    var changeDesktopLayout: (() -> Void)?
    var toggleDesktopFullScreen: (() -> Void)?
    func setDesktopScale(_ scale: Int) { desktopScale = scale == 2 ? 2 : 1; changeDesktopLayout?() }
    let library: URL, games: URL
    var resize: ((Bool) -> Void)?
    private var sources: [String: UInt32] = [:]
    private var focusPaused = false
    private(set) var emulator: Emulator!
    init(libraryOverride: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GameDex", isDirectory: true)
        library = libraryOverride ?? documents.appendingPathComponent("GameDex Recordings", isDirectory: true)
        games = (libraryOverride?.deletingLastPathComponent() ?? support).appendingPathComponent("Games", isDirectory: true)
        recentROMs = RecentROMs(games: games, legacyPath: libraryOverride == nil ? UserDefaults.standard.string(forKey: "lastROM") : nil)
        recentROMPaths = recentROMs.paths
        do { try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true) }
        catch { message = error.localizedDescription }
        emulator = Emulator(library: library)
        emulator.onFrame = { [weak self] image, seconds in self?.image = image; self?.seconds = seconds }
        emulator.onStatus = { [weak self] recording, error in self?.recording = recording; self?.message = error; self?.refresh() }
        refresh()
    }
    func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let target = games.appendingPathComponent(url.lastPathComponent)
            if url.standardizedFileURL != target.standardizedFileURL {
                if FileManager.default.fileExists(atPath: target.path) {
                    // Preserve saves and an already-imported ROM instead of replacing it silently.
                } else { try FileManager.default.copyItem(at: url, to: target) }
            }
            let save = target.deletingPathExtension().appendingPathExtension("sav")
            let sourceSave = url.deletingPathExtension().appendingPathExtension("sav")
            if !FileManager.default.fileExists(atPath: save.path), FileManager.default.fileExists(atPath: sourceSave.path) {
                try FileManager.default.copyItem(at: sourceSave, to: save)
            }
            let name = try emulator.load(target, save: save)
            stateURL = target.appendingPathExtension("state")
            stateAvailable = FileManager.default.fileExists(atPath: stateURL!.path)
            menuNotice = nil
            title = name.contains("POKEMON EMER") ? "Pokémon Emerald" : name
            loaded = true; paused = false; sources.removeAll(); pressed = 0; message = nil
            updatePauseState()
            try recentROMs.remember(target)
            recentROMPaths = recentROMs.paths
        } catch { message = error.localizedDescription }
    }
    func restore() {
        if let path = recentROMPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            load(URL(fileURLWithPath: path))
        }
    }

    func hold(_ source: String, _ mask: UInt32) {
        guard loaded, !isPaused else { return }
        sources[source] = mask; pressed = sources.values.reduce(0, |); emulator.setKeys(pressed)
    }
    func release(_ source: String) { sources.removeValue(forKey: source); pressed = sources.values.reduce(0, |); emulator.setKeys(pressed) }
    func clear() { sources.removeAll(); pressed = 0; emulator.setKeys(0) }
    var isPaused: Bool { paused || showingMenu || showingLibrary || showingSessions || showingPlayback || importing || focusPaused }
    func updatePauseState() { clear(); emulator.setPaused(isPaused) }
    func pause() { paused.toggle(); updatePauseState() }
    func openMenu() { menuNotice = nil; showingMenu = true; updatePauseState() }
    func saveState() {
        guard let stateURL else { return }
        do { try emulator.saveState(stateURL); stateAvailable = true; menuNotice = "State saved" }
        catch { message = error.localizedDescription }
    }
    func loadState() {
        guard let stateURL else { return }
        do { clear(); try emulator.loadState(stateURL); menuNotice = "State loaded" }
        catch { message = error.localizedDescription }
    }
    func toggleFastForward() {
        fastForward.toggle(); emulator.setFastForward(fastForward)
        menuNotice = fastForward ? "2× speed · playback audio muted" : "Normal speed"
    }
    func resumeGame() { showingMenu = false; paused = false; updatePauseState() }
    func focus(_ active: Bool) { focusPaused = !active; updatePauseState() }
    func libraryChanged(_ open: Bool) { updatePauseState(); if open { refresh() } }
    func playbackChanged(_ open: Bool) { showingPlayback = open; updatePauseState() }
    func deleteTake(_ take: Take) {
        guard !recording, take.id.deletingLastPathComponent().standardizedFileURL == library.standardizedFileURL else { return }
        do { try FileManager.default.removeItem(at: take.id); refresh() }
        catch { message = error.localizedDescription }
    }
    func expand() { expanded.toggle(); resize?(expanded) }
    func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        takes = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("metadata.json")), data.count < 4_000_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let ext = json["mgba_capture"] as? [String: Any]
            return Take(id: dir, title: json["game_name"] as? String ?? dir.lastPathComponent,
                        date: json["start_time"] as? String ?? "", seconds: json["duration_seconds"] as? Double ?? 0,
                        complete: ext?["complete"] as? Bool ?? false,
                        frames: (json["video"] as? [String: Any])?["total_frames"] as? Int,
                        status: (ext?["complete"] as? Bool == true) ? (json["upload_status"] as? String ?? "saved") : (ext?["error"] as? String == nil ? "incomplete" : "failed"))
        }.sorted { $0.date > $1.date }
    }
    static func keyboard(_ key: String, shift: Bool = false) -> UInt32? {
        switch key.lowercased() {
        case "w": return 1 << 6
        case "a": return 1 << 5
        case "s": return 1 << 7
        case "d": return 1 << 4
        case "\r", "\n": return 1
        case " ": return 2
        case "z": return 4
        case "x": return 8
        case "q": return 1 << 9
        case "e": return 1 << 8
        default: return nil
        }
    }
}
