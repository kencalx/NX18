// Beam Home (beam-design §3.5): the library full screen, driven by a controller or the arrow keys, in NX 18's look. The D-pad or left stick moves through the games,
// A plays one built for this Mac, Y opens its settings, B (or Escape) leaves. The top bar says which NX 18 this is ("System X2.0")
import AppKit
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
    @FocusState private var keyFocus: Bool   // the keyboard's focus, taken when Home opens (arrows, Return, Escape)
    @State private var focused = 0
    @State private var edges = PadEdges()
    @State private var note: String?
    @State private var clock = Date()
    @State private var profile = BeamProfile(name: "Player", picture: nil)

    private let columns = 4

    var body: some View {
        ZStack {
            NX18Palette.background.ignoresSafeArea()
            HomeBackdrop(game: library.games.indices.contains(focused) ? library.games[focused] : nil)   // the selected game's art, blurred, as the phone's Gate draws it
            VStack(spacing: 0) {
                topBar
                NX18Rails(axis: .horizontal, thickness: 2.5, flowing: true)   // the phone's animated cyan-to-coral line
                if library.games.isEmpty {
                    Spacer()
                    Text("Add a game in Beam's window to see it here.").font(.title2).foregroundStyle(NX18Palette.muted)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: columns), spacing: 34) {
                                ForEach(Array(library.games.enumerated()), id: \.element.id) { i, g in
                                    HomeTile(game: g, focused: i == focused, playable: library.macApp(g.id) != nil, playing: library.playing == g.id, job: library.jobs[g.id])
                                        .id(i)
                                        .contextMenu { GameContextMenu(gameID: g.id) }
                                        .onTapGesture(count: 2) { focused = i; press(.a) }   // a double click plays, as A does
                                        .onTapGesture { focused = i; keyFocus = true }
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
        .focused($keyFocus)
        .focusEffectDisabled()
        .onAppear { keyFocus = true }
        .onExitCommand { press(.b) }
        .onKeyPress(.leftArrow) { press(.left); return .handled }
        .onKeyPress(.rightArrow) { press(.right); return .handled }
        .onKeyPress(.upArrow) { press(.up); return .handled }
        .onKeyPress(.downArrow) { press(.down); return .handled }
        .onKeyPress(.return) { press(.a); return .handled }
        .onKeyPress(.escape) { press(.b); return .handled }
        .task {   // the controller, read each frame on the main actor
            while !Task.isCancelled {
                for p in edges.update(PadEdges.current(), time: ProcessInfo.processInfo.systemUptime)  where library.settingsRequest == nil { press(p) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        .task { while !Task.isCancelled { clock = .now; try? await Task.sleep(for: .seconds(15)) } }
        .task { await readProfile() }   // when Home opens, and again whenever Beam comes back to the front (the player may have changed it on the phone or in a game)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await readProfile() } }
        .onReceive(NotificationCenter.default.publisher(for: NX18Profile.changed)) { _ in Task { await readProfile() } }   // an edit in Beam's Welcome or Settings
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { n in   // a console's toast: which controller came and went
            flash("\((n.object as? GCController)?.vendorName ?? "A controller") connected")
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { n in
            flash("\((n.object as? GCController)?.vendorName ?? "The controller") disconnected")
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { press(.b) } label: {   // back to the library: small and quiet, for a mouse as B is for a controller
                Label("Library", systemImage: "chevron.left").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.07)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Back to the library (B)")
            Image("BeamTitle").resizable().scaledToFit().frame(height: 34)   // Beam's title (the NX 18 mark, BEAM between the beam's dashes); Home is always dark
                .accessibilityLabel("NX 18 Beam")
                .padding(.leading, 6)
            Text("System X2.0").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.muted)
            Spacer()
            if let note { Text(note).font(.callout).foregroundStyle(NX18Palette.text).transition(.opacity) }
            profileChip
            Text(clock.formatted(date: .omitted, time: .shortened)).font(.body.weight(.medium).monospacedDigit()).foregroundStyle(NX18Palette.text)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(alignment: .leading) { NX18MarkShade().offset(x: 60) }   // no bar of its own: it floats over the art; the phone's soft shade keeps the mark readable on a bright one
    }

    private var profileChip: some View {   // the player's NX 18 Profile, as the games see it: picture, then name, left of the clock
        HStack(spacing: 8) {
            ZStack {
                if let img = profile.picture { Image(decorative: img, scale: 1).resizable().scaledToFill() } else { NX18DefaultPicture() }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(GateColor.hairline, lineWidth: 1))
            Text(profile.name).font(.callout.weight(.semibold)).foregroundStyle(NX18Palette.text).lineLimit(1)
        }
        .padding(.trailing, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Profile: \(profile.name)")
    }

    private func readProfile() async {
        let p = await Task.detached(priority: .utility) { BeamProfile.load(nx18: Album.nx18Folder(chosen: nil)) }.value   // off the main thread: it may list iCloud Drive
        if p != profile { profile = p }
    }

    private var hints: some View {
        HStack(spacing: 26) {
            Spacer()
            hint("A", "Play or open"); hint("Y", "Settings"); hint("B", "Library")
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
        HomeSounds.play(p)
        let n = library.games.count
        guard n > 0 || p == .b else { return }
        switch p {
        case .left: focused = max(focused - 1, 0)
        case .right: focused = min(focused + 1, n - 1)
        case .up: focused = max(focused - columns, 0)
        case .down: focused = min(focused + columns, n - 1)
        case .a:
            let g = library.games[focused]
            if library.macApp(g.id) != nil { library.play(g.id) }
            else { library.openPage(g.id) }   // not built for this Mac: its page in Beam's window, where Build and Install are
        case .y:
            let g = library.games[focused]
            if !library.requestSettings(g.id) { flash("Game settings come with a Mac build: right-click the game, or open its page.") }
        case .b: leave()
        }
    }
    private func leave() { library.showingHome = false }   // back to the library, in the same window
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
    var job: BuildJob? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 12) {
            GameIcon(game: game, size: 200)
                .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(focused ? AnyShapeStyle(NX18Palette.brand) : AnyShapeStyle(.clear), lineWidth: 5).padding(-8))
                .overlay(alignment: .bottomTrailing) {
                    if playing { Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(NX18Palette.coral).padding(10) }
                }
                .overlay(alignment: .bottom) {   // a build or install under way: its share, on the tile
                    if let job, job.isActive {
                        VStack(spacing: 4) {
                            Text(job.device != nil ? "Installing" : "Building").font(.caption.weight(.semibold)).foregroundStyle(NX18Palette.text)
                            NX18Bar(value: job.overall, height: 5)
                        }
                        .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {   // ready to play on this Mac: a small badge, never a dimmed tile (most games are for the iPhone)
                    if playable && !playing {
                        Image(systemName: "macbook").font(.system(size: 15, weight: .semibold)).foregroundStyle(NX18Palette.text)
                            .padding(8).background(.black.opacity(0.55), in: Circle()).padding(10)
                            .accessibilityHidden(true)
                    }
                }
            Text(game.title).font(.headline).foregroundStyle(focused ? NX18Palette.text : NX18Palette.muted).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 44, alignment: .top)
        }
        .scaleEffect(focused && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityValue(playing ? "Playing" : playable ? "Ready to play on this Mac" : "Not built for this Mac")
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }
}

/// Beam Home's optional menu sounds (Settings, off by default): a soft tick on a move, a click on a choice, the Mac's own system sounds
enum HomeSounds {
    static var on: Bool { UserDefaults.standard.bool(forKey: "homeSounds") }
    @MainActor static func play(_ p: PadEdges.Press) {
        guard on else { return }
        let name = switch p { case .left, .right, .up, .down: "Tink"; case .a, .y: "Pop"; case .b: "Bottle" }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Beam Home's backdrop, after the phone's Gate (dm/ios/Sources/Launcher.swift): the selected game's key art (Beam's last build's, else the banner NX Play cached),
/// else its icon, blurred and dimmed, faded into the background by gradients from the top and the bottom. Cross-fades as the selection moves; still under Reduce Motion
struct HomeBackdrop: View {
    let game: LibraryGame?
    var subtle = false   // behind a page of text (the game's page): far fainter, faded out by a third of the way down
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static func art(for g: LibraryGame) -> NSImage? {
        for case let p? in [g.art?.path, g.builtArt] { if let i = NSImage(contentsOfFile: p) { return i } }
        return g.identity.flatMap { NXPlayPicture.image(.banner, titleID: $0.titleId) }
    }

    var body: some View {
        let bg = NX18Palette.background
        ZStack {
            if !reduceTransparency, let g = game, let img = Self.art(for: g) ?? GameIcon.image(for: g) {
                Color.clear.overlay {   // the art fills the space it is given, never sizes it: a large picture made Home wider and taller than the window (no scrolling, columns off screen)
                    Image(nsImage: img).resizable().scaledToFill()
                        .blur(radius: subtle ? 80 : 60, opaque: true).opacity(subtle ? 0.22 : 0.55).scaleEffect(1.15)
                }
                .clipped()
                .id(g.id)
                .transition(.opacity)
            }
            if subtle {
                LinearGradient(stops: [.init(color: bg.opacity(0.35), location: 0), .init(color: bg.opacity(0.75), location: 0.35), .init(color: bg, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(stops: [.init(color: bg.opacity(0.85), location: 0), .init(color: bg.opacity(0.2), location: 0.3),
                                       .init(color: bg.opacity(0.35), location: 0.65), .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: game?.id)
    }
}

/// A faint wash of NX 18's colours for pages with no game art (settings): a cyan and a coral glow, blurred, at the top corners. Nothing under Reduce Transparency
struct NX18Glow: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { g in
            if !reduceTransparency {
                ZStack {
                    Circle().fill(NX18Palette.cyan.opacity(0.10)).frame(width: g.size.width * 0.7).position(x: g.size.width * 0.1, y: -g.size.width * 0.12)
                    Circle().fill(NX18Palette.coral.opacity(0.08)).frame(width: g.size.width * 0.6).position(x: g.size.width * 0.95, y: -g.size.width * 0.1)
                }
                .blur(radius: 90)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
