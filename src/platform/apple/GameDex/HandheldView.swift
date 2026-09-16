// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AVKit
import UniformTypeIdentifiers

private let ink = Color(red: 0.14, green: 0.14, blue: 0.18)
private let violet = Color(red: 0.40, green: 0.33, blue: 0.69)
private let shell = Color(red: 0.89, green: 0.89, blue: 0.92)

// The original GBA lens bows across the top and has a deeper, curved chin.
private struct AdvanceBezel: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.10, 0.035))
        path.addCurve(to: point(0.90, 0.035), control1: point(0.32, -0.005), control2: point(0.68, -0.005))
        path.addCurve(to: point(0.975, 0.115), control1: point(0.955, 0.04), control2: point(0.972, 0.06))
        path.addLine(to: point(1, 0.82))
        path.addCurve(to: point(0.89, 0.94), control1: point(1, 0.90), control2: point(0.96, 0.925))
        path.addCurve(to: point(0.11, 0.94), control1: point(0.64, 1.02), control2: point(0.36, 1.02))
        path.addCurve(to: point(0, 0.82), control1: point(0.04, 0.925), control2: point(0, 0.90))
        path.addLine(to: point(0.025, 0.115))
        path.addCurve(to: point(0.10, 0.035), control1: point(0.028, 0.06), control2: point(0.045, 0.04))
        path.closeSubpath()
        return path
    }
}

struct GameDexView: View {
    @ObservedObject var model: GameModel
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let width = geometry.size.width < 500 ? geometry.size.width : min(390, geometry.size.height * 9 / 19.5)
            Handheld(model: model)
                .frame(width: 390, height: geometry.size.height * 390 / width)
                .scaleEffect(width / 390, anchor: .topLeading)
                .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            #else
            let contentWidth = model.desktopShellWidth + (model.expanded ? 320 : 0)
            ScrollView([.horizontal, .vertical]) {
                HStack(spacing: 0) {
                    Handheld(model: model).frame(width: model.desktopShellWidth, height: model.desktopShellHeight)
                    if model.expanded {
                        Details(model: model).frame(width: 320, height: model.desktopShellHeight)
                    }
                }
                .frame(width: max(contentWidth, geometry.size.width), height: max(model.desktopShellHeight, geometry.size.height),
                       alignment: model.desktopFullScreen ? .center : .topLeading)
            }
            .scrollDisabled(contentWidth <= geometry.size.width + 0.5 && model.desktopShellHeight <= geometry.size.height + 0.5)
            #endif
        }
        .background(model.desktopFullScreen ? Color(white: 0.035) : shell)
        .preferredColorScheme(.light)
        .focusable().focused($focused)
        .onAppear { focused = true }
        #if os(iOS)
        .onKeyPress(phases: [.down, .repeat, .up]) { key in
            guard let mask = GameModel.keyboard(key.characters, shift: key.modifiers.contains(.shift)) else { return .ignored }
            let source = "keyboard-\(key.key.character)"
            if key.phase == .up { model.release(source) } else { model.hold(source, mask) }
            return .handled
        }
        #endif
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.data, .zip]) { result in
            if case .success(let url) = result { model.load(url) }
            else if case .failure(let error) = result { model.message = error.localizedDescription }
            focused = true
        }
        .onChange(of: model.importing) { _, open in model.clear(); model.emulator.setPaused(open || model.paused || model.showingLibrary) }
        .sheet(isPresented: $model.showingLibrary) { LibraryView(model: model) }
        .onChange(of: model.showingLibrary) { _, open in model.libraryChanged(open); if !open { focused = true } }
        .alert("GameDex", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

struct Handheld: View {
    @ObservedObject var model: GameModel
    #if os(iOS)
    private let mobile = true
    #else
    private let mobile = false
    #endif
    private var bezelScale: CGFloat { mobile ? 1 : CGFloat(model.desktopScale) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button { model.emulator.toggleRecording() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(model.recording ? .red : Color.gray.opacity(0.6)).frame(width: 6, height: 6)
                            .shadow(color: .red.opacity(model.recording ? 0.6 : 0), radius: 5)
                        Text(model.recording ? "REC  \(time(model.seconds))" : "REC OFF").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                    }.foregroundStyle(model.recording ? Color.red : ink.opacity(0.55))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(model.recording ? Color.red.opacity(0.07) : Color.black.opacity(0.035), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.05)))
                }.buttonStyle(.plain).disabled(!model.loaded)
                    .accessibilityLabel(model.recording ? "Stop recording" : "Start recording")
                Spacer(minLength: 0)
                icon(model.paused ? "play.fill" : "pause.fill", label: model.paused ? "Resume" : "Pause") { model.pause() }
                    .disabled(!model.loaded)
                #if os(iOS)
                icon("gearshape", label: "Settings and recordings") { model.showingLibrary = true }
                #else
                icon(model.expanded ? "sidebar.right" : "sidebar.left", label: model.expanded ? "Collapse details" : "Expand details") { model.expand() }
                #endif
            }.padding(.horizontal, 18).padding(.top, mobile ? 8 : 18)
            VStack(spacing: 0) {
                if !mobile { Color.clear.frame(height: 30 * bezelScale) }
                ZStack {
                    Color(red: 0.055, green: 0.065, blue: 0.055)
                    if let image = model.image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(1.5, contentMode: .fit)
                    } else {
                        VStack(spacing: 13) {
                            Image(systemName: "gamecontroller").font(.system(size: 32, weight: .light))
                            Text("A little room for adventure.").font(.system(size: 13, weight: .medium))
                            Button("Open a GBA game") { model.importing = true }.buttonStyle(.bordered).tint(.white)
                        }.foregroundStyle(.white.opacity(0.75))
                    }
                    if model.paused {
                        Color.black.opacity(0.35)
                        Label("PAUSED", systemImage: "pause.fill").font(.system(size: 12, weight: .bold)).tracking(2)
                            .padding(14).background(.ultraThinMaterial, in: Capsule())
                    }
                }.frame(width: mobile ? 390 : model.desktopGameWidth, height: mobile ? 260 : model.desktopGameWidth / 1.5).clipped()
                .padding(.horizontal, mobile ? 0 : 16 * bezelScale)
                if !mobile { Color.clear.frame(height: 52 * bezelScale) }
            }
            .background {
                if !mobile {
                    AdvanceBezel().fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.075)], startPoint: .top, endPoint: .bottom))
                        .overlay(AdvanceBezel().stroke(.black.opacity(0.75), lineWidth: 1))
                        .overlay(AdvanceBezel().stroke(.white.opacity(0.12), lineWidth: 0.5).padding(1))
                }
            }
            .padding(.horizontal, mobile ? 0 : 6).padding(.top, mobile ? 12 : 18)
            Spacer(minLength: 28)
            HStack(spacing: 0) {
                hold("L", hint: "Q", bit: 9, width: 114, height: 44, shoulder: true)
                Spacer(minLength: 0)
                hold("R", hint: "E", bit: 8, width: 114, height: 44, shoulder: true)
            }
            HStack(alignment: .center, spacing: 43) {
                DPad(model: model).frame(width: 137, height: 137)
                ZStack {
                    Capsule().fill(.black.opacity(0.045)).frame(width: 146, height: 74).rotationEffect(.degrees(-27))
                    hold("B", hint: "SPACE", bit: 1, width: 59, height: 59).offset(x: -35, y: 20)
                    hold("A", hint: "RETURN", bit: 0, width: 59, height: 59).offset(x: 35, y: -20)
                }.frame(width: 150, height: 142)
            }.padding(.top, 24)
            HStack(alignment: .top, spacing: 20) {
                smallButton("SELECT", hint: "Z", bit: 2)
                smallButton("START", hint: "X", bit: 3)
            }.padding(.top, mobile ? 10 : 20)
            Spacer().frame(height: 24)
            HStack {
                Text("W A S D").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(ink.opacity(0.35))
                Spacer()
                HStack(spacing: 5) { ForEach(0..<5) { _ in Capsule().fill(.black.opacity(0.12)).frame(width: 3, height: 23).rotationEffect(.degrees(25)) } }
            }.padding(.horizontal, 40).padding(.bottom, mobile ? 12 : 26)
        }
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(white: 0.96), shell, Color(red: 0.83, green: 0.83, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.09)).frame(width: 1) }
    }
    private func icon(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image).font(.system(size: 15, weight: .medium)).frame(width: 36, height: 44) }
            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.6)).accessibilityLabel(label).help(label)
    }
    private func hold(_ title: String, hint: String, bit: Int, width: CGFloat, height: CGFloat, shoulder: Bool = false) -> some View {
        let down = model.pressed & (1 << bit) != 0
        let shape = shoulder
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: title == "R" ? 28 : 0,
                                             bottomTrailingRadius: title == "L" ? 28 : 0, topTrailingRadius: 0))
            : AnyShape(RoundedRectangle(cornerRadius: 32))
        return VStack(spacing: 7) {
            ZStack {
                shape.fill(LinearGradient(colors: shoulder ? [Color(white: 0.53), Color(white: 0.40)] : [Color(red: 0.55, green: 0.46, blue: 0.77), violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(down ? 0.12 : 0.28), radius: down ? 1 : 2, y: down ? 1 : 4)
                    .overlay(shape.stroke(.white.opacity(0.23)))
                Text(title).font(.system(size: shoulder ? 13 : 25, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
            }.frame(width: width, height: height).offset(y: down ? 2 : 0)
            if !shoulder { Text(hint).font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(ink.opacity(0.43)) }
        }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.hold("touch-\(bit)", 1 << bit) }.onEnded { _ in model.release("touch-\(bit)") })
            .accessibilityLabel("\(title), \(hint)").accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hold("accessibility", 1 << bit); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.release("accessibility") } }
    }
    private func smallButton(_ title: String, hint: String, bit: Int) -> some View {
        VStack(spacing: 8) {
            Capsule().fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.28)], startPoint: .top, endPoint: .bottom))
                .frame(width: 49, height: 15).shadow(color: .black.opacity(0.22), radius: 1, y: model.pressed & (1 << bit) != 0 ? 0 : 2)
            Text(title).font(.system(size: 8, weight: .bold)).tracking(1.5)
            Text(hint).font(.system(size: 8, design: .monospaced)).foregroundStyle(ink.opacity(0.4))
        }.frame(width: 69, height: 55).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.hold("touch-\(bit)", 1 << bit) }.onEnded { _ in model.release("touch-\(bit)") })
            .accessibilityLabel("\(title), \(hint)").accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hold("accessibility", 1 << bit); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.release("accessibility") } }
    }
}

private struct DPad: View {
    @ObservedObject var model: GameModel
    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.04)).frame(width: 137, height: 137)
            Group {
                RoundedRectangle(cornerRadius: 6).frame(width: 45, height: 123)
                RoundedRectangle(cornerRadius: 6).frame(width: 123, height: 45)
            }.foregroundStyle(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 3)
            Circle().fill(.black.opacity(0.13)).frame(width: 24, height: 24)
            arrow("triangle.fill", bit: 6).offset(y: -44)
            arrow("triangle.fill", bit: 7).rotationEffect(.degrees(180)).offset(y: 44)
            arrow("triangle.fill", bit: 5).rotationEffect(.degrees(-90)).offset(x: -44)
            arrow("triangle.fill", bit: 4).rotationEffect(.degrees(90)).offset(x: 44)
        }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - 68.5, dy = value.location.y - 68.5
                var mask: UInt32 = 0
                if dx < -19 { mask |= 1 << 5 }; if dx > 19 { mask |= 1 << 4 }
                if dy < -19 { mask |= 1 << 6 }; if dy > 19 { mask |= 1 << 7 }
                model.hold("dpad", mask)
            }.onEnded { _ in model.release("dpad") })
            .accessibilityElement(children: .ignore).accessibilityLabel("Directional pad. W A S D.")
            .accessibilityAction(named: "Up") { pulse(6) }.accessibilityAction(named: "Down") { pulse(7) }
            .accessibilityAction(named: "Left") { pulse(5) }.accessibilityAction(named: "Right") { pulse(4) }
    }
    private func arrow(_ name: String, bit: Int) -> some View {
        Image(systemName: name).font(.system(size: 9)).foregroundStyle(model.pressed & (1 << bit) != 0 ? .white : .white.opacity(0.2))
    }
    private func pulse(_ bit: Int) { model.hold("accessibility", 1 << bit); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.release("accessibility") } }
}

struct Details: View {
    @ObservedObject var model: GameModel
    var body: some View {
        ScrollView { content }.background(Color(red: 0.97, green: 0.97, blue: 0.98)).foregroundStyle(ink)
    }
    var content: some View {
            VStack(alignment: .leading, spacing: 26) {
                HStack { Text("Studio").font(.system(size: 27, weight: .bold, design: .rounded)); Spacer(); Button { model.expand() } label: { Image(systemName: "sidebar.right") }.buttonStyle(.plain).accessibilityLabel("Collapse details") }
                Button { model.importing = true } label: { Label("Open game…", systemImage: "folder") }.buttonStyle(.bordered)
                #if os(macOS)
                DesktopDisplayControls(model: model)
                Divider()
                #endif
                VStack(alignment: .leading, spacing: 12) {
                    caption("CURRENT SESSION")
                    Text(model.title).font(.headline)
                    HStack { Circle().fill(model.recording ? .red : .gray).frame(width: 7, height: 7); Text(model.recording ? "Recording • \(time(model.seconds))" : "Recording is off").font(.subheadline) }
                    Button(model.recording ? "Stop & save recording" : "Start recording") { model.emulator.toggleRecording() }.buttonStyle(.borderedProminent).tint(violet).disabled(!model.loaded)
                    Text("Video, game audio, and every sampled input stay together.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    caption("KEYBOARD")
                    mapping("D-pad", "W A S D")
                    mapping("A", "Return ↵")
                    mapping("B", "Space")
                    mapping("Start", "X")
                    mapping("Select", "Z")
                    mapping("L / R", "Q / E")
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack { caption("RECORDINGS"); Spacer(); Text("\(model.takes.count)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.takes.prefix(3)) { take in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(take.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text("\(time(take.seconds)) · \(take.complete ? "Saved" : "Incomplete")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.takes.isEmpty { Text("Your first take belongs here.").font(.subheadline).foregroundStyle(.secondary) }
                    Button { model.showingLibrary = true } label: { Label("Settings & recordings", systemImage: "folder") }.buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                Text("GAMEDEX / GBA").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(.tertiary)
            }.padding(26).frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(red: 0.97, green: 0.97, blue: 0.98)).foregroundStyle(ink)
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.secondary) }
    private func mapping(_ name: String, _ key: String) -> some View { HStack { Text(name).font(.system(size: 13)); Spacer(); Text(key).font(.system(size: 11, weight: .medium, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 5)) } }
}

#if os(macOS)
private struct DesktopDisplayControls: View {
    @ObservedObject var model: GameModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GAME SCREEN").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([1, 2], id: \.self) { scale in
                    Button { model.setDesktopScale(scale) } label: {
                        Text(scale == 1 ? "1× · Original" : "2× · Double")
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(model.desktopScale == scale ? violet.opacity(0.18) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.desktopScale == scale ? .isSelected : [])
                }
            }
            Text(model.desktopScale == 1 ? "61.2 × 40.8 mm · ≈2.9″" : "122.4 × 81.6 mm · ≈5.8″").font(.caption)
            Text(model.displaySizingNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { model.toggleDesktopFullScreen?() } label: {
                Label(model.desktopFullScreen ? "Exit full screen" : "Full screen", systemImage: model.desktopFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.buttonStyle(.bordered)
            Text("Full screen keeps this size and dims the space around it. Esc to exit.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif

private struct LibraryView: View {
    @ObservedObject var model: GameModel
    @Environment(\.dismiss) var dismiss
    @State private var selected: Take?
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            List {
                Section("Game") {
                    Button("Open a GBA game…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.importing = true } }
                    Text("Recording starts off. Closing the app finishes the active take.").font(.caption).foregroundStyle(.secondary)
                }
                #if os(macOS)
                Section("Display") { DesktopDisplayControls(model: model) }
                #endif
                Section("Recordings") {
                    if model.takes.isEmpty { Text("No recordings yet. Tap the REC light to start.").foregroundStyle(.secondary) }
                    ForEach(model.takes) { take in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(take.title).font(.headline)
                                Text("\(time(take.seconds)) · \(take.date.prefix(10)) · \(take.complete ? "Saved" : "Incomplete")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { selected = take; play(take) } label: { Image(systemName: "play.circle.fill").font(.title2) }.disabled(!take.complete).buttonStyle(.plain).accessibilityLabel("Play recording")
                            #if os(macOS)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([take.id]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).accessibilityLabel("Show recording files")
                            #else
                            ShareLink(item: take.video) { Image(systemName: "square.and.arrow.up") }.disabled(!take.complete)
                            #endif
                        }.padding(.vertical, 6)
                    }
                }
                #if os(macOS)
                Section("Storage") { Button("Show recordings folder") { NSWorkspace.shared.open(model.library) }; Text(model.library.path).font(.caption).textSelection(.enabled) }
                #endif
                Section("Controls") { Text("W A S D · D-pad\nReturn · A     Space · B\nX · Start     Z · Select\nQ · L     E · R").font(.system(.body, design: .monospaced)) }
            }
            .navigationTitle("Settings & recordings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected, onDismiss: { player?.pause(); player = nil }) { take in
                VStack { VideoPlayer(player: player).aspectRatio(1.5, contentMode: .fit); Button("Done") { selected = nil } }.padding().frame(minWidth: 300, minHeight: 260)
            }
        }
        #if os(macOS)
        .frame(width: 580, height: 630)
        #endif
        .onAppear { model.refresh() }
    }
    private func play(_ take: Take) {
        Task { @MainActor in
            do {
                let composition = AVMutableComposition()
                let video = AVURLAsset(url: take.video), audio = AVURLAsset(url: take.id.appendingPathComponent("audio.wav"))
                let duration = try await video.load(.duration)
                if let track = try await video.loadTracks(withMediaType: .video).first {
                    try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
                if let track = try await audio.loadTracks(withMediaType: .audio).first {
                    try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
                player = AVPlayer(playerItem: AVPlayerItem(asset: composition)); player?.play()
            } catch { model.message = error.localizedDescription }
        }
    }
}
func time(_ seconds: Double) -> String { let n = max(0, Int(seconds)); return String(format: "%02d:%02d", n / 60, n % 60) }
