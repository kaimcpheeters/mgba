// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import AVFoundation

final class Emulator {
    private let queue = DispatchQueue(label: "GameDex.emulation", qos: .userInteractive)
    private var core: OpaquePointer?, timer: DispatchSourceTimer?, recorder: Recorder?
    private var keys: UInt32 = 0, paused = false, ticks = 0
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
            timer.schedule(deadline: .now(), repeating: Double(280896) / Double(16777216), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.step() }; timer.resume(); self.timer = timer
            return title
        }
    }
    func setKeys(_ mask: UInt32) { queue.async { self.keys = mask } }
    func setPaused(_ value: Bool) { queue.async { self.paused = value; if value { self.keys = 0; self.player.pause() } else if self.audio.isRunning { self.player.play() } } }
    private func bytes(_ core: OpaquePointer) -> Data { Data(bytes: gd_pixels(core), count: 240 * 160 * 4) }
    private func step() {
        guard let core, !paused else { return }
        autoreleasepool {
            gd_frame(core, keys)
            let pixels = bytes(core)
            var samples = [Int16](repeating: 0, count: 8192)
            let count = gd_audio(core, &samples, 4096); samples.removeLast(samples.count - count * 2)
            let rate = Double(gd_audio_rate(core))
            play(samples, rate: rate)
            if let recorder {
                do {
                    if gd_poll_overflow(core) != 0 { throw Recorder.Failure(message: "Input poll buffer overflow") }
                    var n = 0; let polls = gd_polls(core, &n)
                    try recorder.step(pixels: pixels, absoluteCycle: gd_cycle(core), samples: samples, sampleRate: rate,
                                      inputPolls: UnsafeBufferPointer(start: polls, count: n))
                } catch { stopRecording(error: error.localizedDescription) }
            }
            if let provider = CGDataProvider(data: pixels as CFData), let image = CGImage(width: 240, height: 160,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 960, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                let seconds = recorder?.seconds ?? 0
                DispatchQueue.main.async { [weak self] in self?.onFrame?(image, seconds) }
            }
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
    var video: URL { id.appendingPathComponent("video.mp4") }
}
final class GameModel: ObservableObject {
    @Published var image: CGImage?
    @Published var title = "Your next adventure"
    @Published var loaded = false
    @Published var recording = false
    @Published var paused = false
    @Published var expanded = false
    @Published var showingLibrary = false
    @Published var importing = false
    @Published var seconds = 0.0
    @Published var pressed: UInt32 = 0
    @Published var message: String?
    @Published var takes: [Take] = []
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
            title = name.contains("POKEMON EMER") ? "Pokémon Emerald" : name
            loaded = true; paused = false; sources.removeAll(); pressed = 0; message = nil
            UserDefaults.standard.set(target.path, forKey: "lastROM")
        } catch { message = error.localizedDescription }
    }
    func restore() { if let path = UserDefaults.standard.string(forKey: "lastROM"), FileManager.default.fileExists(atPath: path) { load(URL(fileURLWithPath: path)) } }
    func hold(_ source: String, _ mask: UInt32) {
        guard loaded, !paused, !showingLibrary, !importing else { return }
        sources[source] = mask; pressed = sources.values.reduce(0, |); emulator.setKeys(pressed)
    }
    func release(_ source: String) { sources.removeValue(forKey: source); pressed = sources.values.reduce(0, |); emulator.setKeys(pressed) }
    func clear() { sources.removeAll(); pressed = 0; emulator.setKeys(0) }
    func pause() { paused.toggle(); clear(); emulator.setPaused(paused || showingLibrary) }
    func focus(_ active: Bool) {
        if !active { focusPaused = !paused; clear(); emulator.setPaused(true) }
        else if focusPaused { emulator.setPaused(paused || showingLibrary); focusPaused = false }
    }
    func libraryChanged(_ open: Bool) { clear(); emulator.setPaused(paused || open); if open { refresh() } }
    func expand() { expanded.toggle(); resize?(expanded) }
    func refresh() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        takes = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("metadata.json")), data.count < 4_000_000,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let ext = json["mgba_capture"] as? [String: Any]
            return Take(id: dir, title: json["game_name"] as? String ?? dir.lastPathComponent,
                        date: json["start_time"] as? String ?? "", seconds: json["duration_seconds"] as? Double ?? 0,
                        complete: ext?["complete"] as? Bool ?? false)
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
