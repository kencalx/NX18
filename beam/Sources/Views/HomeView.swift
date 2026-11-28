// Beam Home (beam-design §3.5): the library full screen, driven by a controller or the arrow keys, in NX 18's look. The D-pad or left stick moves through the games,
// A plays one built for this Mac, Y opens its settings, − opens the Profile, X renews what is about to expire, B (or Escape) leaves. The top bar says which NX 18 this is
// ("System X2.0"). The controller arrives as events (HomePad.swift), read only while Home shows and Beam is in front
import AppKit
import GameController
import SwiftUI

struct HomeView: View {
    @Environment(Library.self) private var library
    @FocusState private var keyFocus: Bool   // the keyboard's focus, taken when Home opens (arrows, Return, Escape)
    @State private var focused = 0
    @State private var pad = HomePad()
    @State private var active = NSApp.isActive   // Beam in front: the controller and the clock run only then
    @State private var showingProfile = false
    @State private var note: String?
    @State private var clock = Date()
    @State private var profile = BeamProfile(name: "Player", picture: nil)
    @State private var album = HomeAlbumState()   // the all-games Album (HomeAlbum.swift): over Home, fed Home's presses while open
    @State private var booted = false   // the grid's fade in when Home opens, once, as a console's home screen comes up
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    VStack(spacing: 12) {   // the console's empty home: what to do, in plain words
                        Image(systemName: "plus.rectangle.on.folder").font(.system(size: 48, weight: .light)).foregroundStyle(NX18Palette.brand).accessibilityHidden(true)
                        Text("No games yet").font(.title.weight(.semibold)).foregroundStyle(NX18Palette.text)
                        Text("Go back to the library (B) and add a game from your legally owned and acquired game files.").font(.title3).foregroundStyle(NX18Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 64)
                    .opacity(booted ? 1 : 0)
                    Spacer()
                    hintsBar.padding(.bottom, 18)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: columns), spacing: 34) {
                                ForEach(Array(library.games.enumerated()), id: \.element.id) { i, g in
                                    HomeTile(game: g, focused: i == focused, playable: library.macApp(g.id) != nil, playing: library.playing == g.id, job: library.jobs[g.id],
                                             expiry: library.expiryBadge(g.id, now: clock), updated: library.rebuilds[g.id] != nil)
                                        .id(i)
                                        .contextMenu { GameContextMenu(gameID: g.id) }
                                        .onTapGesture(count: 2) { focused = i; press(.a) }   // a double click plays, as A does
                                        .onTapGesture { focused = i; keyFocus = true }
                                        .accessibilityAction { focused = i; press(.a) }   // VoiceOver's activate: what A does
                                        .accessibilityAction(named: "Settings") { focused = i; press(.y) }
                                }
                            }
                            .padding(.horizontal, 64).padding(.vertical, 40)
                        }
                        // the boot: the grid fades up from a touch smaller; under Reduce Motion only the fade. A one-time animation, nothing runs after it
                        .opacity(booted ? 1 : 0)
                        .scaleEffect(booted || reduceMotion ? 1 : 0.97)
                        .safeAreaInset(edge: .bottom) { hintsBar.padding(.bottom, 18) }   // floats over the tiles, which scroll under its glass
                        .onChange(of: focused) { _, i in withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(i, anchor: .center) } }
                    }
                }
            }
        }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.45)) { booted = true } }
        .overlay { HomeAlbumView(state: album) }
        .preferredColorScheme(.dark)
        .focusable()
        .focused($keyFocus)
        .focusEffectDisabled()
        .onAppear { keyFocus = true; active = NSApp.isActive; pad.onPress = { handle($0) }; updatePad() }
        .onDisappear { pad.stop() }
        .onChange(of: active) { updatePad() }
        .onExitCommand { press(.b) }
        .onKeyPress(.leftArrow) { press(.left); return .handled }
        .onKeyPress(.rightArrow) { press(.right); return .handled }
        .onKeyPress(.upArrow) { press(.up); return .handled }
        .onKeyPress(.downArrow) { press(.down); return .handled }
        .onKeyPress(.return) { press(.a); return .handled }
        .onKeyPress(.escape) { press(.b); return .handled }
        .onKeyPress(.space) { press(.a); return .handled }
        .onKeyPress(characters: Self.letterKeys, phases: .down) { k in   // with no controller, the hints' letters on the keyboard: A, B, X, Y and −
            guard let p = Self.letterPress(k.characters) else { return .ignored }
            press(p); return .handled
        }
        .task(id: active) {   // the clock, while Beam is in front: on each minute's turn, and at once on coming back
            guard active else { return }
            while !Task.isCancelled {
                clock = .now
                let next = Calendar.current.nextDate(after: clock, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? clock.addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(next.timeIntervalSince(.now) + 0.05), tolerance: .seconds(1))
            }
        }
        .task { await readProfile() }   // when Home opens, and again whenever Beam comes back to the front (the player may have changed it on the phone or in a game)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true; Task { await readProfile() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .onChange(of: library.renewNote) { _, n in if let n { flash(n, seconds: 8); library.renewNote = nil } }
        .sheet(isPresented: $showingProfile, onDismiss: { keyFocus = true; Task { await readProfile() } }) { ProfileSheet() }
        .onReceive(NotificationCenter.default.publisher(for: NX18Profile.changed)) { _ in Task { await readProfile() } }   // an edit in Beam's Welcome or Settings
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { n in   // a console's toast: which controller came and went
            flash("\((n.object as? GCController)?.vendorName ?? "A controller") connected")
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { n in
            flash("\((n.object as? GCController)?.vendorName ?? "The controller") disconnected")
        }
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 14) { HStack(spacing: 14) {   // the bar's capsules are one glass group over the art (beam-design §4.5)
            Button { press(.b) } label: {   // back to the library: small and quiet, for a mouse as B is for a controller
                Label("Library", systemImage: "chevron.left").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .homeCapsule()
            }
            .buttonStyle(.plain)
            .help("Back to the library (B)")
            HomeAlbumButton(state: album)
            Image("BeamTitle").resizable().scaledToFit().frame(height: 34)   // Beam's title (the NX 18 mark, BEAM between the beam's dashes); Home is always dark
                .accessibilityLabel("NX 18 Beam")
                .padding(.leading, 6)
            Text("System X2.0").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.muted)
            Spacer()
            if let note { Text(note).font(.callout).foregroundStyle(NX18Palette.text).lineLimit(2).transition(.opacity) }
            if library.renewDue(now: clock) {   // an install runs out within 2 days: renew them all, as X does
                Button { press(.x) } label: {
                    Label(library.renewingAll ? "Renewing…" : "Renew All", systemImage: "arrow.clockwise").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .homeCapsule(tint: NX18Palette.coral)
                }
                .buttonStyle(.plain)
                .disabled(library.renewingAll)
                .help("Renew every game that expires within 2 days on a connected iPhone or iPad (X)")
            }
            profileChip
            Text(clock.formatted(date: .omitted, time: .shortened)).font(.body.weight(.medium).monospacedDigit()).foregroundStyle(NX18Palette.text)
        } }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(alignment: .leading) { NX18MarkShade().offset(x: 60) }   // no bar of its own: it floats over the art; the phone's soft shade keeps the mark readable on a bright one
    }

    private var profileChip: some View {   // the player's NX 18 Profile, as the games see it: picture, then name, left of the clock; a click (or −) opens it
        Button { press(.minus) } label: { profileChipLabel }
            .buttonStyle(.plain)
            .help("Your Profile (−)")
            .accessibilityLabel("Profile: \(profile.name)")
            .accessibilityHint("Opens the Profile")
    }
    private var profileChipLabel: some View {
        HStack(spacing: 8) {
            ZStack {
                if let img = profile.picture { Image(decorative: img, scale: 1).resizable().scaledToFill() } else { NX18DefaultPicture() }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(GateColor.hairline, lineWidth: 1))
            Text(profile.name).font(.callout.weight(.semibold)).foregroundStyle(NX18Palette.text).lineLimit(1)
        }
        .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
        .homeCapsule()
    }

    private func readProfile() async {
        let p = await Task.detached(priority: .utility) { BeamProfile.load(nx18: Album.nx18Folder(chosen: nil)) }.value   // off the main thread: it may list iCloud Drive
        if p != profile { profile = p }
    }

    /// The hints for what shows: A plays a game built for this Mac or opens another's page, Y only where there are settings, X only while something is due
    private var hintsBar: some View {
        let g = library.games.indices.contains(focused) ? library.games[focused] : nil
        var h: [BeamHint] = []
        if let g {
            h.append(BeamHint(.pad(.a), library.macApp(g.id) != nil ? "Play" : "Open"))
            if library.macApp(g.id) != nil { h.append(BeamHint(.pad(.y), "Settings")) }
        }
        if library.renewDue(now: clock) && !library.renewingAll { h.append(BeamHint(.pad(.x), "Renew All")) }
        h.append(BeamHint(.minus, "Profile"))
        h.append(BeamHint(.pad(.b), "Library"))
        return HStack { Spacer(); BeamHintsBar(hints: h) }.padding(.horizontal, 28)
    }

    static let letterKeys = CharacterSet(charactersIn: "abxyABXY-−")
    nonisolated static func letterPress(_ s: String) -> PadEdges.Press? { PadEdges.letter(s) }

    private func updatePad() { if active { pad.start() } else { pad.stop() } }

    /// A press from the controller: to the Profile sheet when it is up, to Home unless a game's settings sheet is
    private func handle(_ p: PadEdges.Press) {
        switch HomePad.route(p, settingsOpen: library.settingsRequest != nil, profileOpen: showingProfile) {
        case .home(let p): press(p)
        case .closeProfile: HomeSounds.play(.b); showingProfile = false
        case .ignore: break
        }
    }

    private func press(_ p: PadEdges.Press) {
        HomeSounds.play(p)
        if album.press(p) { return }
        let n = library.games.count
        guard n > 0 || [.b, .minus, .x].contains(p) else { return }
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
        case .x:
            if library.renewDue() { library.renewAll() }
        case .minus: showingProfile = true
        case .b: leave()
        }
    }
    private func leave() { library.showingHome = false }   // back to the library, in the same window
    private func flash(_ s: String, seconds: Int = 3) {
        withAnimation { note = s }
        Task { try? await Task.sleep(for: .seconds(seconds)); withAnimation { if note == s { note = nil } } }
    }
}

private struct HomeTile: View {
    let game: LibraryGame
    let focused: Bool
    let playable: Bool
    let playing: Bool
    var job: BuildJob? = nil
    var expiry: ExpiryBadge? = nil
    var updated = false   // NX 18 changed since its build (Rebuilds.swift)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 12) {
            GameIcon(game: game, size: 200)
                // the focus: the ring fades in as the tile lifts toward the player (a shadow under it), one short animation per move
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 18 : 0, y: focused ? 10 : 0)
                .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(NX18Palette.brand, lineWidth: 5).padding(-8).opacity(focused ? 1 : 0))
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
                    } else if let expiry {   // an install on a device runs out within 2 days, or has
                        Label(expiry.text, systemImage: expiry.expired ? "exclamationmark.circle.fill" : "clock")
                            .font(.caption.weight(.semibold)).foregroundStyle(expiry.expired ? NX18Palette.coral : NX18Palette.text)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.6), in: Capsule()).padding(10)
                    }
                }
                .overlay(alignment: .topLeading) {   // NX 18 changed since its build: a quiet note, as a console marks an update
                    if updated && !(job?.isActive ?? false) {
                        Text("Update available: rebuild").font(.caption.weight(.semibold)).foregroundStyle(NX18Palette.text)
                            .padding(.horizontal, 9).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule()).padding(10)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) {   // ready to play on this Mac: a small badge, never a dimmed tile (most games are for the iPhone)
                    if playable && !playing {
                        Image(systemName: "macbook").font(.system(size: 15, weight: .semibold)).foregroundStyle(NX18Palette.text)
                            .padding(8).background(.black.opacity(0.55), in: Circle()).padding(10)
                            .accessibilityHidden(true)
                    }
                }
            // over the art: the lighter grey with a soft dark shade under the letters, so a bright picture behind cannot wash the name out (the muted grey alone fell to
            // about 2:1 over a white one); the plain text colour under Increase Contrast
            Text(game.title).font(.headline).foregroundStyle(focused || contrast == .increased ? NX18Palette.text : NX18Palette.onArt).lineLimit(2).multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3)
                .frame(height: 44, alignment: .top)
        }
        .scaleEffect(focused && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityValue([playing ? "Playing" : playable ? "Ready to play on this Mac" : "Not built for this Mac", expiry?.text, updated ? "update available: rebuild" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }
}

/// Beam Home's backdrop, after the phone's Gate (dm/ios/Sources/Launcher.swift): the selected game's key art (Beam's last build's, else the banner NX Play cached),
/// else its icon, blurred and dimmed, faded into the background by gradients from the top and the bottom. Cross-fades as the selection moves; still under Reduce Motion
struct HomeBackdrop: View {
    let game: LibraryGame?
    var subtle = false   // behind a page of text (the game's page): far fainter, faded out by a third of the way down
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

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
                let mid = contrast == .increased ? 0.6 : 0.2   // Increase Contrast: the art stays, darker behind the names
                LinearGradient(stops: [.init(color: bg.opacity(0.85), location: 0), .init(color: bg.opacity(mid), location: 0.3),
                                       .init(color: bg.opacity(mid + 0.15), location: 0.65), .init(color: bg, location: 1)], startPoint: .top, endPoint: .bottom)
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
