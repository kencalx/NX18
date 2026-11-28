// The Album's viewer (beam-design §2a): one capture at full size, a recording played with AVKit, left and right to the next, and an action bar: Share (the Mac's share
// menu), Show in Finder, Trim (a recording), Move to Trash (asked first). A controller reaches the bar with Y; the mouse clicks it. The same view serves the game page
// (in a sheet) and Beam Home (full screen)
import AVKit
import AppKit
import SwiftUI

struct AlbumViewer: View {
    let browser: AlbumBrowser
    var subtitle: (AlbumItem) -> String? = { _ in nil }   // Home's all-games Album: the game's name
    var hints: AnyView? = nil   // Home's hints bar for the viewer's mode, kept above the Trash question's shade
    @State private var image: CGImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let item = browser.current {
                VStack(spacing: 0) {
                    header(item)
                    ZStack {
                        content(item)
                        HStack {
                            arrow("chevron.left", -1, enabled: (browser.viewing ?? 0) > 0)
                            Spacer()
                            arrow("chevron.right", 1, enabled: (browser.viewing ?? 0) < browser.items.count - 1)
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if browser.mode == .trim { AlbumTrimBar(browser: browser) } else { actionBar(item) }
                }
                if browser.mode == .confirmDelete { confirm(item) }
                if let w = browser.working {
                    ProgressView(w).padding(24).homeSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: false)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if let hints { hints.padding(.bottom, 14) } }
        .preferredColorScheme(.dark)
        .task(id: browser.current?.url) { await show(browser.current) }
        .task(id: browser.current.map { "\($0.url.path)|\($0.downloading)" }) { await waitForDownload() }
        .onChange(of: browser.playRequests) { _, _ in
            guard let p = player else { return }
            if p.timeControlStatus == .playing { p.pause() } else { p.play() }
        }
        .onChange(of: browser.trim) { _, new in   // a handle moved: show that frame
            guard browser.mode == .trim, let p = player else { return }
            let t = new.editingEnd ? new.end : new.start
            p.pause(); p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func header(_ item: AlbumItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.date.formatted(date: .complete, time: .shortened)).font(.headline).foregroundStyle(NX18Palette.text)
            if let s = subtitle(item) { Text(s).font(.callout).foregroundStyle(NX18Palette.muted).lineLimit(1) }
            Text(item.place.rawValue).font(.caption).foregroundStyle(NX18Palette.muted)
            Spacer()
            if let m = browser.message { Text(m).font(.callout).foregroundStyle(NX18Palette.text).lineLimit(2) }
            Text("\((browser.viewing ?? 0) + 1) of \(browser.items.count)").font(.callout.monospacedDigit()).foregroundStyle(NX18Palette.muted)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private func content(_ item: AlbumItem) -> some View {
        if item.downloading {
            VStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.down").font(.system(size: 44)).foregroundStyle(NX18Palette.cyan)
                Text("Downloading from iCloud…").foregroundStyle(NX18Palette.text)
                ProgressView().controlSize(.small)
            }
        } else if item.kind == .recording {
            if let player { VideoPlayer(player: player) } else { ProgressView() }
        } else if let image {
            Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
                .accessibilityLabel("Screenshot, \(item.date.formatted(date: .abbreviated, time: .shortened))")
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private func arrow(_ symbol: String, _ d: Int, enabled: Bool) -> some View {
        if enabled {   // glass over the picture; at the first or last capture none (never a glass view faded out)
            Button { browser.step(d) } label: {
                Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(NX18Palette.text).frame(width: 44, height: 44)
                    .homeSurface(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(d < 0 ? "Previous" : "Next")
        } else {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }

    private func actionBar(_ item: AlbumItem) -> some View {
        let acts = browser.actions(for: item)
        let selected: Int? = if case .actions(let i) = browser.mode { i } else { nil }
        return GlassEffectContainer(spacing: 14) { HStack(spacing: 14) {   // the actions as one glass group (Y on a controller, then left and right, rings the chosen one)
            Spacer()
            ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                let (title, symbol) = Self.label(a)
                Button { browser.perform(a) } label: {
                    Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(a == .delete ? NX18Palette.coral : NX18Palette.text)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .homeCapsule()
                        .overlay(Capsule().strokeBorder(NX18Palette.brand, lineWidth: 3).opacity(selected == i ? 1 : 0))
                }
                .buttonStyle(.plain)
                .disabled(item.downloading)
                .accessibilityAddTraits(selected == i ? .isSelected : [])
                .background { if a == .share { ShareAnchor(browser: browser) } }
            }
            Spacer()
        } }
        .padding(.vertical, 12)
    }
    static func label(_ a: AlbumBrowser.Action) -> (String, String) {
        switch a {
        case .share: ("Share", "square.and.arrow.up")
        case .finder: ("Show in Finder", "folder")
        case .trim: ("Trim", "timeline.selection")
        case .delete: ("Move to Trash", "trash")
        }
    }

    private func confirm(_ item: AlbumItem) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { browser.mode = .look }
            VStack(spacing: 14) {
                Text("Move this \(item.kind == .recording ? "recording" : "screenshot") to the Trash?").font(.title3.weight(.semibold)).foregroundStyle(NX18Palette.text)
                Text(item.place == .iCloud ? "It leaves iCloud Drive, so your other devices lose it too. You can put it back from the Trash." : "You can put it back from the Trash.")
                    .font(.callout).foregroundStyle(NX18Palette.muted).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Cancel (B)") { browser.mode = .look }.keyboardShortcut(.cancelAction)
                    Button("Move to Trash (A)", role: .destructive) { browser.trash() }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(28).frame(maxWidth: 440)
            .background(NX18Palette.charcoal, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// The open item: its picture decoded off the main thread at screen size, or a player for a recording
    private func show(_ item: AlbumItem?) async {
        player?.pause(); player = nil; image = nil
        guard let item, !item.downloading else { return }
        if item.kind == .recording { player = AVPlayer(url: item.url); return }
        let url = item.url
        image = await Task.detached(priority: .userInitiated) { AlbumThumbnails.downsampled(url, pixels: 3840) }.value
    }
    /// While the open item is still in iCloud: look once a second until it is down (only then, only while it is open), then read the Album again
    private func waitForDownload() async {
        guard let item = browser.current, item.downloading else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if FileManager.default.fileExists(atPath: item.url.path) { await browser.reload(); return }
        }
    }
}

/// The trim: start and end handles on a track of the recording's length (drag them; a controller's left and right move the chosen one by half a second, up and down
/// choose), the times, and Save Trimmed Copy. The original is never changed
struct AlbumTrimBar: View {
    let browser: AlbumBrowser
    var body: some View {
        let t = browser.trim
        VStack(spacing: 10) {
            GeometryReader { g in
                let w = max(g.size.width, 1), x0 = w * t.start / max(t.duration, 0.01), x1 = w * t.end / max(t.duration, 0.01)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 8)
                    Capsule().fill(NX18Palette.brand).frame(width: max(x1 - x0, 4), height: 8).offset(x: x0)
                    handle(x0, chosen: !t.editingEnd, width: w, end: false)
                    handle(x1, chosen: t.editingEnd, width: w, end: true)
                }
                .frame(height: 30)
            }
            .frame(height: 30)
            HStack {
                Text("Start \(Self.time(t.start))").foregroundStyle(t.editingEnd ? NX18Palette.muted : NX18Palette.text)
                Spacer()
                Text("\(Self.time(t.end - t.start)) kept").foregroundStyle(NX18Palette.muted)
                Spacer()
                Text("End \(Self.time(t.end))").foregroundStyle(t.editingEnd ? NX18Palette.text : NX18Palette.muted)
            }
            .font(.callout.monospacedDigit())
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel (B)") { browser.mode = .look }
                Button("Save Trimmed Copy (A)") { Task { await browser.saveTrim() } }.buttonStyle(.borderedProminent).tint(NX18Palette.coral)
                Spacer()
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(NX18Palette.charcoal)
    }

    private func handle(_ x: CGFloat, chosen: Bool, width: CGFloat, end: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(chosen ? NX18Palette.coral : NX18Palette.text)
            .frame(width: 12, height: 30).offset(x: min(max(x - 6, 0), width - 12))
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let s = min(max(Double(v.location.x / width) * browser.trim.duration, 0), browser.trim.duration), gap = AlbumTrim.minimumLength
                browser.trim.editingEnd = end
                if end { browser.trim.end = max(s, browser.trim.start + gap) } else { browser.trim.start = min(s, browser.trim.end - gap) }
            })
            .accessibilityLabel(end ? "End" : "Start")
            .accessibilityValue(Self.time(end ? browser.trim.end : browser.trim.start))
            .accessibilityAdjustableAction { d in browser.trim.editingEnd = end; browser.nudge(d == .increment ? 0.5 : -0.5) }
    }
    static func time(_ s: Double) -> String {
        let v = max(s, 0), m = Int(v) / 60, sec = v - Double(m * 60)
        return String(format: "%d:%04.1f", m, sec)
    }
}

/// Where the share menu opens from: the Share button's own view
private struct ShareAnchor: NSViewRepresentable {
    let browser: AlbumBrowser
    func makeNSView(context: Context) -> NSView { let v = NSView(); Task { @MainActor in browser.shareAnchor = v }; return v }
    func updateNSView(_ v: NSView, context: Context) { if browser.shareAnchor !== v { browser.shareAnchor = v } }
}
