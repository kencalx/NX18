// Beam Home (beam-design §3.5): the library full screen, driven by a controller or the arrow keys, in NX 18's look. The D-pad or left stick moves through the games,
// A plays one built for this Mac, Y opens its settings, B (or Escape) leaves. The top bar says which NX 18 this is ("System X2.0")
import GameController
import SwiftUI

/// The controller's presses as Home reads them: each edge once, a held direction repeating after 0.4 s every 0.12 s
struct PadEdges {
    enum Press: Equatable { case left, right, up, down, a, b, y }
    private var held: Set<Press> = []
    private var repeatAt: [Press: TimeInterval] = [:]

    mutating func update(_ now: Set<Press>, time: TimeInterval) -> [Press] {
        var out: [Press] = []
        for p in now {
            if !held.contains(p) { out.append(p); repeatAt[p] = time + 0.4 }
            else if [.left, .right, .up, .down].contains(p), let t = repeatAt[p], time >= t { out.append(p); repeatAt[p] = time + 0.12 }
        }
        held = now
        repeatAt = repeatAt.filter { now.contains($0.key) }
        return out
    }

    @MainActor static func current() -> Set<Press> {
        guard let g = GCController.current?.extendedGamepad else { return [] }
        var s: Set<Press> = []
        let x = g.dpad.xAxis.value + g.leftThumbstick.xAxis.value, y = g.dpad.yAxis.value + g.leftThumbstick.yAxis.value
        if x < -0.5 { s.insert(.left) }; if x > 0.5 { s.insert(.right) }
        if y > 0.5 { s.insert(.up) }; if y < -0.5 { s.insert(.down) }
        // by position, as a Nintendo pad's labels sit: the right face button is A, the bottom B, the left Y (NX 18's button glyphs follow the same rule)
        if g.buttonB.isPressed { s.insert(.a) }
        if g.buttonA.isPressed { s.insert(.b) }
        if g.buttonX.isPressed { s.insert(.y) }
        return s
    }
}

struct HomeView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var focused = 0
    @State private var edges = PadEdges()
    @State private var settingsFor: (title: String, source: GameSettingsSource)?
    @State private var note: String?
    @State private var clock = Date()

    private let columns = 4

    var body: some View {
        ZStack {
            NX18Palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if library.games.isEmpty {
                    Spacer()
                    Text("Add a game in Beam's window to see it here.").font(.title2).foregroundStyle(NX18Palette.muted)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: columns), spacing: 34) {
                                ForEach(Array(library.games.enumerated()), id: \.element.id) { i, g in
                                    HomeTile(game: g, focused: i == focused, playable: library.macApp(g.id) != nil, playing: library.playing == g.id)
                                        .id(i)
                                        .onTapGesture { focused = i; press(.a) }
                                }
                            }
                            .padding(.horizontal, 64).padding(.vertical, 40)
                        }
                        .onChange(of: focused) { _, i in withAnimation(.snappy) { proxy.scrollTo(i, anchor: .center) } }
                    }
                }
                hints
            }
        }
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { press(.left); return .handled }
        .onKeyPress(.rightArrow) { press(.right); return .handled }
        .onKeyPress(.upArrow) { press(.up); return .handled }
        .onKeyPress(.downArrow) { press(.down); return .handled }
        .onKeyPress(.return) { press(.a); return .handled }
        .onKeyPress(.escape) { press(.b); return .handled }
        .task {   // the controller, read each frame on the main actor
            while !Task.isCancelled {
                for p in edges.update(PadEdges.current(), time: ProcessInfo.processInfo.systemUptime) where settingsFor == nil { press(p) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .task { while !Task.isCancelled { clock = .now; try? await Task.sleep(for: .seconds(15)) } }
        .sheet(isPresented: Binding(get: { settingsFor != nil }, set: { if !$0 { settingsFor = nil } })) {
            if let s = settingsFor { GameSettingsView(title: s.title, source: s.source) }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text("NX 18").font(.system(size: 22, weight: .heavy)).foregroundStyle(NX18Palette.cyan)
            Text("System X2.0").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.muted)
            Spacer()
            if let note { Text(note).font(.callout).foregroundStyle(NX18Palette.text).transition(.opacity) }
            Text(clock.formatted(date: .omitted, time: .shortened)).font(.title3.monospacedDigit()).foregroundStyle(NX18Palette.text)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    private var hints: some View {
        HStack(spacing: 26) {
            Spacer()
            hint("A", "Play"); hint("Y", "Settings"); hint("B", "Back")
        }
        .padding(.horizontal, 36).padding(.vertical, 16)
        .background(NX18Palette.charcoal)
    }
    private func hint(_ button: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(button).font(.system(size: 13, weight: .bold)).foregroundStyle(NX18Palette.charcoal)
                .frame(width: 24, height: 24).background(Circle().fill(NX18Palette.text))
            Text(label).foregroundStyle(NX18Palette.text)
        }
    }

    private func press(_ p: PadEdges.Press) {
        let n = library.games.count
        guard n > 0 || p == .b else { return }
        switch p {
        case .left: focused = max(focused - 1, 0)
        case .right: focused = min(focused + 1, n - 1)
        case .up: focused = max(focused - columns, 0)
        case .down: focused = min(focused + columns, n - 1)
        case .a:
            let g = library.games[focused]
            if library.macApp(g.id) != nil { library.play(g.id) } else { flash("\(g.title) is not built for this Mac yet. Build it in Beam's window.") }
        case .y:
            let g = library.games[focused]
            if let s = library.macApp(g.id).flatMap(GameSettingsSource.init(app:)) { settingsFor = (g.title, s) } else { flash("Settings come with a Mac build.") }
        case .b: dismissWindow(id: "home")
        }
    }
    private func flash(_ s: String) {
        withAnimation { note = s }
        Task { try? await Task.sleep(for: .seconds(3)); withAnimation { if note == s { note = nil } } }
    }
}

private struct HomeTile: View {
    let game: LibraryGame
    let focused: Bool
    let playable: Bool
    let playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 12) {
            GameIcon(game: game, size: 200)
                .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(focused ? NX18Palette.cyan : .clear, lineWidth: 5).padding(-8))
                .overlay(alignment: .bottomTrailing) {
                    if playing { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(NX18Palette.coral).padding(10) }
                }
                .opacity(playable ? 1 : 0.55)
            Text(game.title).font(.headline).foregroundStyle(focused ? NX18Palette.text : NX18Palette.muted).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 44, alignment: .top)
        }
        .scaleEffect(focused && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: focused)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}
