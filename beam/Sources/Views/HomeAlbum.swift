// Beam Home's Album (beam-design §2a): every game's captures, grouped by game, the game with the newest first, full screen in Home's look. Opened by the Album button in
// Home's top bar or the controller's capture button (Share, or the button the Mac ties to a screenshot, as the game apps find it: DmGamepad.m pad_capture_button), closed
// by B or the capture button again. Home's own presses (its controller and keys) come here while it is open (HomeAlbumState.press), so it reads no controller of its own.
// The folders are read when it opens and when Beam comes back to the front; nothing runs while it is closed
import AppKit
import GameController
import SwiftUI

@MainActor @Observable final class HomeAlbumState {
    private(set) var browser: AlbumBrowser?
    var isOpen: Bool { browser != nil }
    @ObservationIgnored weak var library: Library?
    @ObservationIgnored private var claimed: [ObjectIdentifier: (button: GCControllerButtonInput, state: GCControllerElement.SystemGestureState)] = [:]
    @ObservationIgnored private var titles: [UUID: String] = [:]

    func open() {
        guard browser == nil, let library else { return }
        let games = library.games.compactMap { g in g.identity.map { (id: g.id, title: g.title, titleID: $0.titleId) } }
        titles = Dictionary(games.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let b = AlbumBrowser { Self.captures(games) }
        b.columns = 5
        browser = b
        Task { await b.reload() }
        Task.detached(priority: .background) { AlbumThumbnails.prune() }
    }
    func close() { browser = nil }
    func toggle() { isOpen ? close() : open() }
    /// The Album button or the capture button: open or close with Home's sounds (Home's own presses already make theirs)
    func toggleWithSound() { HomeSounds.play(isOpen ? .b : .a); toggle() }
    func title(of item: AlbumItem) -> String? {
        browser?.groups.first { $0.items.contains(item) }?.title
    }

    /// Home's press, while the Album is open: true when the Album took it
    func press(_ p: PadEdges.Press) -> Bool {
        guard let b = browser else { return false }
        let a: AlbumPress
        switch p {
        case .left: a = .left
        case .right: a = .right
        case .up: a = .up
        case .down: a = .down
        case .a: a = .a
        case .b: a = .b
        case .y: a = .y
        case .x, .minus: return true   // Home's Renew All and Profile wait while the Album is open: taken, nothing done
        }
        if !b.press(a) { close() }
        return true
    }

    /// Every game's captures, grouped by game (off the main thread)
    nonisolated static func captures(_ games: [(id: UUID, title: String, titleID: String)]) -> [AlbumBrowser.Group] {
        let nx = Album.nx18Folder(chosen: nil)
        let all = games.map { g in (id: g.id, title: g.title, items: Album.items(titleID: g.titleID, nx18: nx, myFiles: nil).filter { $0.kind != .document }) }
        return AlbumGrouping.games(all).map { AlbumBrowser.Group(id: $0.id.uuidString, title: $0.title, items: $0.items) }
    }

    /// The capture button opens and closes the Album while Home shows. Its system gesture (a screenshot of the Mac) is off only then, and put back when Home goes
    func claimCaptureButtons() {
        for c in GCController.controllers() where claimed[ObjectIdentifier(c)] == nil {
            guard let b = Self.captureButton(c) else { continue }
            claimed[ObjectIdentifier(c)] = (b, b.preferredSystemGestureState)
            b.preferredSystemGestureState = .disabled
            b.pressedChangedHandler = { [weak self] _, _, down in
                guard down else { return }
                Task { @MainActor in self?.toggleWithSound() }
            }
        }
    }
    func releaseCaptureButtons() {
        for (_, c) in claimed { c.button.pressedChangedHandler = nil; c.button.preferredSystemGestureState = c.state }
        claimed = [:]
    }
    private static func captureButton(_ c: GCController) -> GCControllerButtonInput? {
        let pr = c.physicalInputProfile
        if let b = pr.buttons[GCInputButtonShare] { return b }
        let game: Set<String> = [GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger,
                                 GCInputRightTrigger, GCInputButtonMenu, GCInputButtonOptions, GCInputLeftThumbstickButton, GCInputRightThumbstickButton, GCInputButtonHome]
        return pr.buttons.values.first { $0.isBoundToSystemGesture && $0.aliases.isDisjoint(with: game) }
    }
}

/// The Album button in Home's top bar; it also gives the capture button to the Album while Home shows
struct HomeAlbumButton: View {
    @Environment(Library.self) private var library
    let state: HomeAlbumState
    var body: some View {
        Button { state.library = library; state.toggleWithSound() } label: {
            Label("Album", systemImage: "photo.on.rectangle").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .homeCapsule()
        }
        .buttonStyle(.plain)
        .help("Your screenshots and recordings from every game (the controller's capture button)")
        .onAppear { state.library = library; state.claimCaptureButtons() }
        .onDisappear { state.releaseCaptureButtons(); state.close() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in state.claimCaptureButtons() }
    }
}

/// The all-games Album over Home: a grid per game, focus moved by Home's presses; A opens the viewer, B goes back to the games
struct HomeAlbumView: View {
    let state: HomeAlbumState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if let b = state.browser {
            ZStack {
                NX18Palette.background.ignoresSafeArea()
                NX18Glow()
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Button { state.toggleWithSound() } label: {
                            Label("Home", systemImage: "chevron.left").font(.callout.weight(.medium)).foregroundStyle(NX18Palette.text)
                                .padding(.horizontal, 10).padding(.vertical, 5).homeCapsule()
                        }
                        .buttonStyle(.plain)
                        .help("Back to Beam Home (B)")
                        Text("Album").font(.title2.weight(.semibold)).foregroundStyle(NX18Palette.text)
                        Text(Self.count(b.items)).font(.callout).foregroundStyle(NX18Palette.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    NX18Rails(axis: .horizontal, thickness: 2.5, flowing: true)
                    if b.loaded && b.items.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(NX18Palette.brand).accessibilityHidden(true)
                            Text("No captures yet").font(.title.weight(.semibold)).foregroundStyle(NX18Palette.text)
                            Text("Screenshots and recordings from your games show here. On iPhone or iPad, set This game's captures to NX 18 folder on the game's NX 18 card.")
                                .font(.title3).foregroundStyle(NX18Palette.muted).multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 64)
                        Spacer()
                        hints(viewer: false).padding(.bottom, 18)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                AlbumGrid(browser: b, fixedColumns: b.columns, tileHeight: 150, showFocus: true, showPlace: false)
                                    .padding(.horizontal, 64).padding(.vertical, 30)
                            }
                            .safeAreaInset(edge: .bottom) { hints(viewer: false).padding(.bottom, 18) }   // over the thumbnails, which scroll under its glass
                            .onChange(of: b.focus) { _, i in
                                if b.items.indices.contains(i) { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(b.items[i].url, anchor: .center) } }
                            }
                        }
                    }
                }
                if b.viewing != nil {
                    AlbumViewer(browser: b, subtitle: { state.title(of: $0) }, hints: AnyView(hints(viewer: true)))
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await b.reload() } }
        }
    }

    /// The hints for the screen showing: the grid, or the viewer in its mode (looking, its action bar, the Trash question, a trim)
    private func hints(viewer: Bool) -> some View {
        var h: [BeamHint] = []
        if viewer, let b = state.browser {
            switch b.mode {
            case .trim: h = [BeamHint(.leftRight, "Move"), BeamHint(.upDown, "Start or end"), BeamHint(.pad(.a), "Save Trimmed Copy"), BeamHint(.pad(.b), "Cancel")]
            case .confirmDelete: h = [BeamHint(.pad(.a), "Move to Trash"), BeamHint(.pad(.b), "Cancel")]
            case .actions: h = [BeamHint(.leftRight, "Choose"), BeamHint(.pad(.a), "OK"), BeamHint(.pad(.b), "Back")]
            default:
                if b.items.count > 1 { h.append(BeamHint(.leftRight, "Previous or next")) }
                if b.current?.kind == .recording, b.current?.downloading == false { h.append(BeamHint(.pad(.a), "Play or pause")) }
                if b.current?.downloading == false { h.append(BeamHint(.pad(.y), "Options")) }
                h.append(BeamHint(.pad(.b), "Album"))
            }
        } else {
            if let b = state.browser, !b.items.isEmpty { h.append(BeamHint(.pad(.a), "Open")) }
            h.append(BeamHint(.pad(.b), "Home"))
        }
        return HStack { Spacer(); BeamHintsBar(hints: h) }.padding(.horizontal, 28)
    }
    static func count(_ items: [AlbumItem]) -> String {
        let shots = items.filter { $0.kind == .screenshot }.count, vids = items.filter { $0.kind == .recording }.count
        return [shots > 0 ? "\(shots) screenshot\(shots == 1 ? "" : "s")" : nil, vids > 0 ? "\(vids) recording\(vids == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
