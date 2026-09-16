// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation

/// Native Apple encoder; the GameDex JSON/media contract is shared with the SDL exporter.
final class Recorder {
    static let frequency: UInt64 = 16_777_216
    static let virtualKeys = ["x", "z", "Key.backspace", "Key.enter", "Key.right", "Key.left", "Key.up", "Key.down", "s", "a"]
    let directory: URL
    let origin: UInt64
    private let title: String, id = UUID().uuidString, started = Date()
    private let writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let actions: FileHandle, events: FileHandle, polls: FileHandle, mapping: FileHandle, audio: FileHandle
    private var image: Data, imageCycle: UInt64 = 0, cycle: UInt64 = 0, nativeFrame = 0, frames = 0
    private var observed: UInt16, held: UInt16, used: UInt16 = 0, eventCount = 0
    private var pending: [(UInt64, UInt16)] = []
    private var audioPending: [Int16] = [], audioPosition = 0.0, audioFrames = 0
    private var finished = false
    var seconds: Double { Double(frames) / 60 }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func file(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure(message: "Cannot create \(url.lastPathComponent)") }
        return try FileHandle(forWritingTo: url)
    }
    init(library: URL, title: String, pixels: Data, cycle: UInt64, keys: UInt16) throws {
        self.title = title; self.origin = cycle; self.image = pixels; self.held = keys; self.observed = keys
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        directory = library.appendingPathComponent("mgba-\(stamp)-\(id.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        actions = try Self.file(directory.appendingPathComponent("actions.jsonl"))
        events = try Self.file(directory.appendingPathComponent("events.jsonl"))
        polls = try Self.file(directory.appendingPathComponent("mgba-inputs.jsonl"))
        mapping = try Self.file(directory.appendingPathComponent("mgba-frames.jsonl"))
        audio = try Self.file(directory.appendingPathComponent("audio.wav"))
        try audio.write(contentsOf: Data(repeating: 0, count: 44))
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("video.mp4"), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 160,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoExpectedSourceFrameRateKey: 60,
                                             AVVideoMaxKeyFrameIntervalKey: 60, AVVideoAllowFrameReorderingKey: false]])
        input.expectsMediaDataInRealTime = false; input.mediaTimeScale = 60_000
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 160,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        try metadata(complete: false, error: "Recording in progress")
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Cannot start video encoder") }
        writer.startSession(atSourceTime: .zero)
        try transition(keys, at: 0, initial: true)
    }
    private func line(_ object: [String: Any], to file: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); data.append(10)
        try file.write(contentsOf: data)
    }
    private func transition(_ keys: UInt16, at cycle: UInt64, initial: Bool = false) throws {
        let changed = initial ? keys : keys ^ observed
        for bit in 0..<10 where changed & (1 << bit) != 0 {
            let press = keys & (1 << bit) != 0
            try line(["timestamp_ms": Double(cycle) * 1000 / Double(Self.frequency),
                      "type": press ? "key_press" : "key_release", "data": ["key": Self.virtualKeys[bit]]], to: events)
            used |= 1 << bit; eventCount += 1
        }
        observed = keys
    }
    func step(pixels: Data, absoluteCycle: UInt64, samples: [Int16], sampleRate: Double, inputPolls: UnsafeBufferPointer<GDPoll>) throws {
        guard absoluteCycle >= origin + cycle else { throw Failure(message: "Emulation timeline changed") }
        cycle = absoluteCycle - origin
        var pollText = ""
        for poll in inputPolls {
            let t = poll.cycle - origin
            pollText += "{\"cycle\":\(t),\"native_frame\":\(nativeFrame + 1),\"buttons\":\(poll.buttons)}\n"
            if poll.buttons != observed { try transition(poll.buttons, at: t); pending.append((t, poll.buttons)) }
        }
        try polls.write(contentsOf: Data(pollText.utf8))
        try emit(until: cycle)
        image = pixels; imageCycle = cycle; nativeFrame += 1
        try sound(samples, rate: sampleRate)
    }
    private func emit(until cycle: UInt64) throws {
        while UInt64(frames) * Self.frequency < cycle * 60 {
            while let first = pending.first, first.0 * 60 <= UInt64(frames) * Self.frequency {
                held = first.1; pending.removeFirst()
            }
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            guard input.isReadyForMoreMediaData, writer.status == .writing else { throw writer.error ?? Failure(message: "Video encoder stalled") }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw Failure(message: "Cannot allocate video frame")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let out = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            image.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0..<160 { for x in 0..<240 {
                    let i = (y * 240 + x) * 4, o = y * row + x * 4
                    out[o] = src[i + 2]; out[o + 1] = src[i + 1]; out[o + 2] = src[i]; out[o + 3] = 255
                } }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frames), timescale: 60)) else {
                throw writer.error ?? Failure(message: "Could not encode frame")
            }
            let keys = (0..<10).filter { held & (1 << $0) != 0 }.map { Self.virtualKeys[$0] }
            try line(["frame_id": frames, "timestamp_ms": Double(frames) * 1000 / 60,
                      "inputs": ["keys": keys, "mouse": ["x": 0, "y": 0, "buttons": ["left": false, "right": false, "middle": false]]]], to: actions)
            try line(["frame_id": frames, "native_frame": nativeFrame, "source_cycle": imageCycle], to: mapping)
            frames += 1
        }
    }
    private func sound(_ samples: [Int16], rate: Double) throws {
        audioPending += samples
        let count = audioPending.count / 2
        var output: [Int16] = []
        while Int(audioPosition) + 1 < count {
            let i = Int(audioPosition), fraction = audioPosition - Double(i)
            for channel in 0..<2 {
                let a = Double(audioPending[i * 2 + channel]), b = Double(audioPending[(i + 1) * 2 + channel])
                output.append(Int16(clamping: Int((a + (b - a) * fraction).rounded())))
            }
            audioPosition += rate / 44100
        }
        let consumed = min(Int(audioPosition), max(0, count - 1))
        audioPending.removeFirst(consumed * 2); audioPosition -= Double(consumed)
        try output.withUnsafeBytes { try audio.write(contentsOf: Data($0)) }; audioFrames += output.count / 2
    }
    func finish(error: String? = nil) throws {
        guard !finished else { return }; finished = true
        var failure = error
        if frames == 0 { failure = "No game frames recorded" }
        if failure == nil {
            writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 60)); input.markAsFinished()
            let wait = DispatchSemaphore(value: 0); writer.finishWriting { wait.signal() }
            if wait.wait(timeout: .now() + 15) == .timedOut { writer.cancelWriting(); failure = "Video finalization timed out" }
            else if writer.status != .completed { failure = writer.error?.localizedDescription ?? "Video finalization failed" }
        } else { writer.cancelWriting() }
        do {
            let count = frames * 735, bytes = count * 4
            guard bytes <= Int(UInt32.max) - 36 else { throw Failure(message: "Recording exceeds WAV size limit") }
            if audioFrames < count { try audio.write(contentsOf: Data(repeating: 0, count: (count - audioFrames) * 4)) }
            try audio.truncate(atOffset: UInt64(44 + bytes)); try audio.seek(toOffset: 0)
            var header = Data("RIFF".utf8)
            func u32(_ n: Int) { var n = UInt32(n).littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
            func u16(_ n: Int) { var n = UInt16(n).littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
            u32(bytes + 36); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
            u32(44100); u32(176400); u16(4); u16(16); header.append(Data("data".utf8)); u32(bytes)
            try audio.write(contentsOf: header)
            for file in [actions, events, polls, mapping, audio] { try file.synchronize(); try file.close() }
        } catch { failure = error.localizedDescription }
        try metadata(complete: failure == nil, error: failure)
        if let failure { throw Failure(message: failure) }
    }
    private func metadata(complete: Bool, error: String?) throws {
        let iso = ISO8601DateFormatter()
        let document: [String: Any] = [
            "session_id": id, "game_name": title, "start_time": iso.string(from: started),
            "end_time": complete ? iso.string(from: Date()) as Any : NSNull(), "duration_seconds": seconds,
            "upload_status": complete ? "pending" : "failed",
            "video": ["width": 240, "height": 160, "fps": 60, "codec": "h264", "encoder": "avfoundation", "crf": 0, "total_frames": frames],
            "audio": ["enabled": true, "saved": complete, "sample_rate": 44100, "channels": 2, "format": "s16le"],
            "stats": ["total_key_events": eventCount, "total_mouse_events": 0, "total_controller_events": 0,
                      "unique_keys_used": (0..<10).filter { used & (1 << $0) != 0 }.map { Self.virtualKeys[$0] }, "controllers_used": [], "dropped_frames": 0],
            "system": ["os": ProcessInfo.processInfo.operatingSystemVersionString, "rust_version": "not applicable (Swift/mGBA)"],
            "mgba_capture": ["version": 1, "complete": complete, "error": error as Any? ?? NSNull(), "clock_hz": Self.frequency,
                             "native_frame_cycles": 280896, "origin_cycle": origin, "native_frames": nativeFrame + 1,
                             "emulated_cycles": cycle, "button_keys": Self.virtualKeys, "input_semantics": "sampled GBA buttons mapped to virtual keys",
                             "rate_control": "AVFoundation average bitrate 2000000; crf unused"]]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }
}
