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
        #if os(iOS)
        .preferredColorScheme(model.showingMenu && !model.showingLibrary && !model.showingSessions && !model.importing ? .dark : .light)
        #else
        .preferredColorScheme(.light)
        #endif
        .focusable().focused($focused)
        .onAppear { focused = true }
        #if os(iOS)
        .onKeyPress(phases: [.down, .repeat, .up]) { key in
            guard !model.showingMenu, !model.showingLibrary, !model.showingSessions, !model.showingPlayback, !model.importing else { return .ignored }
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
        .onChange(of: model.importing) { _, _ in model.updatePauseState() }
        .sheet(isPresented: $model.showingLibrary) { LibraryView(model: model) }
        .sheet(isPresented: $model.showingSessions) { RecordingSessionsView(model: model) }
        .onChange(of: model.showingSessions) { _, open in
            model.updatePauseState()
            if open { model.refresh() } else { focused = true }
        }
        .onChange(of: model.showingLibrary) { _, open in model.libraryChanged(open); if !open { focused = true } }
        .alert("GameDex", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct ShoulderBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
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
                #if os(iOS)
                icon("play.rectangle.on.rectangle", label: "Recording Sessions") { model.showingSessions = true }
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
            }.anchorPreference(key: ShoulderBoundsKey.self, value: .bounds) { $0 }
            HStack(alignment: .center, spacing: 43) {
                DPad(model: model).frame(width: 137, height: 137)
                ZStack {
                    Capsule().fill(.black.opacity(0.045)).frame(width: 146, height: 74).rotationEffect(.degrees(-27))
                    hold("B", hint: "SPACE", bit: 1, width: 59, height: 59).offset(x: -35, y: 20)
                    hold("A", hint: "RETURN", bit: 0, width: 59, height: 59).offset(x: 35, y: -20)
                }.frame(width: 150, height: 142)
            }.padding(.top, 24)
            HStack(alignment: .top, spacing: 8) {
                smallButton("SELECT", hint: "Z", bit: 2)
                smallButton("START", hint: "X", bit: 3)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Button { model.openMenu() } label: { Text("MENU") }
                    .buttonStyle(MenuDotStyle())
                    .accessibilityLabel("Pause menu").help("Pause menu")
                    .padding(.leading, 8)
            }.padding(.top, mobile ? 10 : 20)
            Spacer().frame(height: 24)
            HStack {
                #if os(macOS)
                Text("W A S D").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(ink.opacity(0.35))
                #endif
                Spacer()
                HStack(spacing: 5) { ForEach(0..<5) { _ in Capsule().fill(.black.opacity(0.12)).frame(width: 3, height: 23).rotationEffect(.degrees(25)) } }
            }.padding(.horizontal, 40).padding(.bottom, mobile ? 12 : 26)
        }
        .foregroundStyle(ink)
        .background(LinearGradient(colors: [Color(white: 0.96), shell, Color(red: 0.83, green: 0.83, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.09)).frame(width: 1) }
        .blur(radius: model.showingMenu ? 12 : 0)
        .allowsHitTesting(!model.showingMenu)
        .accessibilityHidden(model.showingMenu)
        .overlayPreferenceValue(ShoulderBoundsKey.self) { shoulderBounds in
            GeometryReader { geometry in
                if model.showingMenu, let shoulderBounds {
                    PauseMenu(model: model, panelTop: geometry[shoulderBounds].minY)
                }
            }
        }
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
            if !shoulder && !mobile { Text(hint).font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(ink.opacity(0.43)) }
        }.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.hold("touch-\(bit)", 1 << bit) }.onEnded { _ in model.release("touch-\(bit)") })
            .accessibilityLabel(mobile ? title : "\(title), \(hint)").accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hold("accessibility", 1 << bit); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.release("accessibility") } }
    }
    private func smallButton(_ title: String, hint: String, bit: Int) -> some View {
        AuxiliaryButtonFace(title: title, hint: hint, pressed: model.pressed & (1 << bit) != 0)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.hold("touch-\(bit)", 1 << bit) }.onEnded { _ in model.release("touch-\(bit)") })
            .accessibilityLabel(mobile ? title : "\(title), \(hint)").accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hold("accessibility", 1 << bit); DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { model.release("accessibility") } }
    }
}

private struct PauseMenu: View {
    @ObservedObject var model: GameModel
    let panelTop: CGFloat
    private let settingsTitle = "Settings"
    var body: some View {
        GeometryReader { geometry in
            let top = min(max(0, panelTop), geometry.size.height)
            VStack(spacing: 0) {
                VStack(spacing: 18) {
                    Image(systemName: "pause.fill").font(.system(size: 64, weight: .bold)).foregroundStyle(violet)
                    Text(model.title).font(.system(size: 22, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 24)
                }.frame(maxWidth: .infinity).frame(height: top)
                #if os(iOS)
                .background(Color.black.ignoresSafeArea(edges: .top))
                #endif
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Text("Paused").font(.headline)
                            Spacer()
                            Button("Resume") { model.resumeGame() }.font(.headline).tint(violet)
                                .buttonStyle(.borderedProminent).keyboardShortcut(.escape, modifiers: [])
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            action("Save State", icon: "square.and.arrow.down", detail: "Quick save", disabled: !model.loaded) { model.saveState() }
                            action("Load State", icon: "square.and.arrow.up", detail: "Latest save", disabled: !model.loaded || !model.stateAvailable) { model.loadState() }
                            action("Fast Forward", icon: "forward.fill", detail: model.fastForward ? "2× · On" : "Off", disabled: !model.loaded, active: model.fastForward) { model.toggleFastForward() }
                            action(settingsTitle, icon: "gearshape", detail: "Preferences") { model.showingLibrary = true }
                        }
                        Text(model.menuNotice ?? " ")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2).frame(height: 34, alignment: .top)
                            .accessibilityHidden(model.menuNotice == nil)
                    }.padding(18)
                }
                .frame(height: geometry.size.height - top)
                .background(Color(red: 0.13, green: 0.10, blue: 0.19).opacity(0.96))
                .clipped()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color.black.opacity(0.72)).foregroundStyle(.white)
            .accessibilityAddTraits(.isModal)
    }
    private func action(_ title: String, icon: String, detail: String, disabled: Bool = false, active: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 27, weight: .medium))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.6))
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(violet.opacity(active ? 0.5 : 0.18), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(disabled ? 0.3 : 0.9)).disabled(disabled)
    }

}

private struct AuxiliaryButtonFace: View {
    let title: String
    var hint: String = ""
    var pressed = false
    var body: some View {
        VStack(spacing: 7) {
            Circle().fill(Color(white: 0.18)).frame(width: 24, height: 24)
                .overlay {
                    Circle().fill(LinearGradient(colors: [Color(white: pressed ? 0.65 : 0.94), Color(white: 0.63)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                        .padding(2.5)
                }
                .shadow(color: .black.opacity(pressed ? 0.1 : 0.25), radius: 1, y: pressed ? 0 : 2)
                .offset(y: pressed ? 1 : 0)
            Text(title).font(.system(size: 8, weight: .bold)).tracking(0.8)
            #if os(macOS)
            Text(hint.isEmpty ? " " : hint).font(.system(size: 8, design: .monospaced)).foregroundStyle(ink.opacity(0.4))
            #else
            Color.clear.frame(height: 10).accessibilityHidden(true)
            #endif
        }.frame(width: 56, height: 65).foregroundStyle(ink)
    }
}

private struct MenuDotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AuxiliaryButtonFace(title: "MENU", pressed: configuration.isPressed).contentShape(Rectangle())
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
            .accessibilityElement(children: .ignore)
            #if os(macOS)
            .accessibilityLabel("Directional pad. W A S D.")
            #else
            .accessibilityLabel("Directional pad")
            #endif
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
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                PageHeading(title: "Recording Sessions")
                Spacer()
                Button { model.showingLibrary = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)).frame(width: 36, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Settings").help("Settings")
            }
            SessionsView(model: model)
        }.padding(22).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(red: 0.97, green: 0.97, blue: 0.98)).foregroundStyle(ink)
    }
}

private struct PageHeading: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(ink) }
}

private struct SessionsView: View {
    @ObservedObject var model: GameModel
    @State private var pendingOnly = false
    @State private var selected: Take?
    @State private var deleting: Take?
    private var visibleTakes: [Take] { model.takes.filter { !pendingOnly || $0.status == "pending" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ForEach([false, true], id: \.self) { pending in
                    Button { pendingOnly = pending } label: {
                        Text(pending ? "Pending" : "All").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(pendingOnly == pending ? violet.opacity(0.15) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(pendingOnly == pending ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel("Refresh sessions").help("Refresh sessions")
                #if os(macOS)
                Button { NSWorkspace.shared.open(model.library) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).accessibilityLabel("Open sessions folder").help("Open sessions folder")
                #endif
            }
            Text("\(visibleTakes.count) sessions").font(.caption).foregroundStyle(.secondary)
            if visibleTakes.isEmpty {
                Text(pendingOnly ? "No pending sessions." : "No recording sessions yet. Use REC to start recording.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(visibleTakes) { take in
                SessionRow(take: take, canDelete: !model.recording, play: { selected = take }, delete: { deleting = take })
            }
            if visibleTakes.contains(where: { $0.status == "pending" }) {
                Text("Pending sessions are saved locally. Upload is not configured.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refresh() }
        .onChange(of: selected?.id) { _, id in model.playbackChanged(id != nil) }
        .sheet(item: $selected, onDismiss: { model.playbackChanged(false) }) { take in
            SessionPlaybackView(take: take)
        }
        .alert("Delete session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let take = deleting { model.deleteTake(take) }; deleting = nil }
        } message: { Text("This removes the session’s video, audio, and input logs from this device.") }
    }
}

private struct SessionRow: View {
    let take: Take
    let canDelete: Bool
    let play: () -> Void
    let delete: () -> Void
    private var statusColor: Color {
        switch take.status { case "pending": return .orange; case "uploaded": return .green; case "failed", "incomplete": return .red; default: return .secondary }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(take.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(take.displayDate).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                metric("Duration", value: take.duration)
                Spacer()
                metric("Frames", value: take.frames?.formatted() ?? "—")
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Status").font(.caption2).foregroundStyle(.secondary)
                    Text(take.status.capitalized).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                        .padding(.horizontal, 7).padding(.vertical, 4).background(statusColor.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 16) {
                Button(action: play) { Label("Play", systemImage: "play.fill") }.disabled(!take.complete).buttonStyle(.bordered)
                Spacer(minLength: 0)
                #if os(macOS)
                Button { NSWorkspace.shared.activateFileViewerSelecting([take.id]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).accessibilityLabel("Show session files").help("Show session files")
                #else
                ShareLink(item: take.video) { Image(systemName: "square.and.arrow.up") }.disabled(!take.complete)
                #endif
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).disabled(!canDelete).accessibilityLabel("Delete session").help("Delete session")
            }.font(.subheadline)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.08)))
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }
}

private struct SessionPlaybackView: View {
    let take: Take
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 16) {
            if let failure { Text(failure).foregroundStyle(.secondary) }
            else { VideoPlayer(player: player).aspectRatio(1.5, contentMode: .fit) }
            Button("Done") { dismiss() }
        }.padding().frame(minWidth: 300, minHeight: 260)
            .task(id: take.id) { await load() }
            .onDisappear { player?.pause(); player = nil }
    }
    @MainActor private func load() async {
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
            try Task.checkCancellation()
            player = AVPlayer(playerItem: AVPlayerItem(asset: composition)); player?.play()
        } catch is CancellationError { } catch { failure = error.localizedDescription }
    }
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

private struct RecordingSessionsView: View {
    @ObservedObject var model: GameModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeading(title: "Recording Sessions")
                    SessionsView(model: model)
                }.padding(22)
            }.background(shell.opacity(0.35))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct LibraryView: View {
    @ObservedObject var model: GameModel
    @Environment(\.dismiss) var dismiss
    private let title = "Settings"
    var body: some View {
        NavigationStack {
            List {
                Section { PageHeading(title: title).padding(.vertical, 4) }
                Section("Game") {
                    Button("Open a GBA game…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.importing = true } }
                    Text("Recording starts off. Closing the app finishes the active take.").font(.caption).foregroundStyle(.secondary)
                }
                if !model.recentROMPaths.isEmpty {
                    Section("Recent ROMs") {
                        ForEach(model.recentROMPaths, id: \.self) { path in
                            let url = URL(fileURLWithPath: path)
                            let available = FileManager.default.fileExists(atPath: path)
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.load(url) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.deletingPathExtension().lastPathComponent).font(.subheadline.weight(.medium))
                                    Text(available ? path : "File unavailable · \(path)")
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                }
                            }.disabled(!available)
                        }
                    }
                }
                #if os(macOS)
                Section("Display") { DesktopDisplayControls(model: model) }
                Section("Storage") {
                    Button("Show sessions folder") { NSWorkspace.shared.open(model.library) }
                    Text(model.library.path).font(.caption).textSelection(.enabled)
                }
                #endif
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 580, height: 630)
        #endif
        .onAppear { model.refresh() }
    }
}
func time(_ seconds: Double) -> String { let n = max(0, Int(seconds)); return String(format: "%02d:%02d", n / 60, n % 60) }
