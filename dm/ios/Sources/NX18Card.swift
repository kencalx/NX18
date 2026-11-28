// The NX 18 card (NX18-X2.0 gate-ui.md §20, G13): a tap on the NX 18 mark, or A with focus on it, opens a small card under the mark. It shows NX 18's release and build and
// the game's version, and holds the one look setting, Appearance (G20, §20.5b): Match device (the default), Light or Dark. It closes with ✕, B, Escape or a tap outside, and
// focus goes back to the mark. Above Appearance (the owner's order, 2026-11-17), the Profile (F10, §20.2 items 4-7): the picture and name the games see, the Profile and NX 18 folder switch, the NX 18 folder and
// This game's saves. The flows behind the rows (the photo picker and crop, the name bar, the folder pick, the move) are the platform's: NX18ProfileFlow.swift on iOS.
// Below Appearance, with key art, Adjust art (ArtFocus.swift): an action that opens the Gate's framing mode on the art, no setting of its own.
// In iPhone landscape the header stays and the body scrolls under it, the pad's focused row scrolled into view (§20.1).
// Look: the solid inner fill of the look's Gate set, all text on it, and a 6 pt rim: glass over the key art where allowed, else solid with a hairline (§11, §20.4). Built on open, freed on close
import ImageIO
import SwiftUI

enum NX18CardItem: String, Sendable, CaseIterable { case close, appearance, picture, name, profile, folder, saves, captures, art }

// What the card's Profile rows show and do; the platform builds it (iOS: from NX18ProfileFlow). nil: the card shows no Profile section
struct NX18CardProfile {
    var busy: String? = nil, note: String? = nil, strip: String? = nil
    var shared = false                  // This game's saves: in the NX 18 folder
    var capturesShared = false          // This game's captures: in the NX 18 folder
    var choosePicture: (() -> Void)? = nil
    var editName: (() -> Void)? = nil
    var toggle: () -> Void = {}
    var chooseFolder: (() -> Void)? = nil
    var saves: (() -> Void)? = nil
    var captures: (() -> Void)? = nil
}

struct NX18Card: View {
    let gameVersion: String?
    let focused: NX18CardItem?            // the pad's focus inside the card (nil: no pad)
    let glyphs: NXPadGlyphs?
    let close: () -> Void
    var art = false                       // key art behind the card: its rim may be glass (§11); without it the card is solid
    var profileRows: NX18CardProfile? = nil
    var scrolls = false                   // iPhone landscape: the header stays, the body scrolls under it
    var adjustArt: (() -> Void)? = nil    // Adjust art: the Gate's framing mode for the key art (ArtFocus.swift); nil without key art, and the row is not shown
    @State private var look = NX18Appearance.current
    @ObservedObject private var profile = NX18Profile.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if scrolls {
                ScrollViewReader { sv in
                    // Room inside the scroll view's clip for the focus rings (drawn 3 pt outside their rows) and the picture, given back outside so the rows keep their place
                    ScrollView { cardBody.padding(.horizontal, 5).padding(.top, 5).padding(.bottom, 9) }
                        .padding(.horizontal, -5).padding(.top, -5)
                        .scrollIndicators(.hidden)
                        .onChange(of: focused) { _, f in if let f { withAnimation(.easeOut(duration: 0.15)) { sv.scrollTo(f, anchor: .center) } } }
                }
            } else { cardBody }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(GateColor.slab))   // the solid inner fill every text sits on
        .padding(6)   // the rim: glass over the art where allowed, else the same solid fill with a hairline (NX18Glass.swift)
        .nx18Surface(RoundedRectangle(cornerRadius: 22, style: .continuous), fill: GateColor.slab, hairline: GateColor.hairline, tint: Color.black.opacity(0.25), art: art)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onReceive(NotificationCenter.default.publisher(for: NX18Appearance.changed)) { _ in look = NX18Appearance.current }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
            HStack(alignment: .center, spacing: 10) {
                NX18Mark(height: 22, light: scheme == .light)   // the mark alone: "NX 18" beside it said the same twice (owner, 2026-11-18)
                    .accessibilityElement().accessibilityLabel("NX 18").accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(GateColor.text)   // system: symbol
                        .frame(width: 44, height: 44).background(Circle().fill(GateColor.tile)).contentShape(Circle())
                }
                .buttonStyle(NX18PressStyle())
                .keyboardShortcut(.cancelAction)   // Escape on a hardware keyboard
                .overlay { if focused == .close { Circle().strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
                .accessibilityLabel("Close")
            }
            .id(NX18CardItem.close)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(nx18Line ?? "NX 18").nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                if let v = gameVersion { Text("Game version \(v)").nxFont(.footnote).foregroundStyle(GateColor.muted) }
                if let s = nx18StampLine { Text(verbatim: s).nxFont(.caption).foregroundStyle(GateColor.muted) }
            }
            .accessibilityElement(children: .combine)
            if let p = profileRows { profileSection(p) }   // the Profile first (owner, 2026-11-17), then the one look setting
            appearanceRow.id(NX18CardItem.appearance)
            Text("Light or dark menus. Match device follows the device.").nxFont(.caption).foregroundStyle(GateColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let adjustArt { row(.art, "Key art", "Choose the part the Gate shows", action: adjustArt, button: "Adjust") }   // an action, not a setting: the framing is made on the art itself
            if let glyphs {
                if let s = profileRows?.strip { Text(s).nxFont(.caption).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 14) {
                    hint(glyphs.glyph(.a), aHint)
                    hint(glyphs.glyph(.b), "Back")
                }
                .accessibilityHidden(true)
            }
        }
    }
    private var aHint: String {
        switch focused {
        case .appearance?: return "Change"
        case .profile?, .saves?, .captures?: return "Change"
        case .folder?: return "Choose"
        case .art?: return "Adjust"
        case .picture?, .name?: return "Edit"
        default: return "Close"
        }
    }

    // ---- the Profile (§20.2 items 4-7) ----
    @ViewBuilder private func profileSection(_ p: NX18CardProfile) -> some View {
        Text("Profile").nxFont(.caption, weight: .semibold).foregroundStyle(GateColor.muted).textCase(.uppercase).accessibilityAddTraits(.isHeader)
        HStack(alignment: .center, spacing: 14) {
            Button { p.choosePicture?() } label: {
                VStack(spacing: 4) {
                    NX18ProfilePictureView(version: profile.pictureVersion, has: profile.hasPicture, url: profile.pictureURL).frame(width: 72, height: 72)
                    if p.choosePicture != nil { Text("Choose a picture").nxFont(.caption2).foregroundStyle(GateColor.line).lineLimit(1).minimumScaleFactor(0.8) }
                }
                .padding(4)
                .overlay { if focused == .picture { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).allowsHitTesting(false) } }
            }
            .buttonStyle(NX18PressStyle()).disabled(p.choosePicture == nil).id(NX18CardItem.picture)
            .accessibilityLabel("Profile picture").accessibilityHint(p.choosePicture == nil ? "" : "Choose a picture")
            Button { p.editName?() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: profile.name).nxFont(.title3, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).minimumScaleFactor(0.7)
                    if p.editName != nil { Text("Name").nxFont(.caption).foregroundStyle(GateColor.muted) }
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(focused == .name ? GateColor.lit : GateColor.tile))
                .overlay { if focused == .name { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
            }
            .buttonStyle(NX18PressStyle()).disabled(p.editName == nil).id(NX18CardItem.name)
            .accessibilityLabel("Name").accessibilityValue(profile.name)
        }
        Button(action: p.toggle) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profile and NX 18 folder").nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                    Text("Profile and NX 18 folder for this game. Others keep theirs.").nxFont(.caption).foregroundStyle(GateColor.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                OnOffCapsule(on: profile.enabled, enabled: true)
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused == .profile ? GateColor.lit : GateColor.tile))
            .overlay { if focused == .profile { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
        }
        .buttonStyle(NX18PressStyle()).id(NX18CardItem.profile)
        .accessibilityLabel("Profile and NX 18 folder").accessibilityValue(profile.enabled ? "On" : "Off")
        if profile.enabled {
            row(.folder, "NX 18 folder", folderValue, action: p.chooseFolder, button: "Choose")
            if case .chosen = profile.folderState, let saves = p.saves {
                row(.saves, "This game's saves", p.shared ? "NX 18 folder" : "Own folder", action: saves, button: nil)
            }
            if case .chosen = profile.folderState, let captures = p.captures {   // screenshots: in the NX 18 folder, where NX 18 Beam on the Mac sorts them into the game's page
                row(.captures, "This game's captures", p.capturesShared ? "NX 18 folder" : "Own folder", action: captures, button: nil)
            }
        }
        if let b = p.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).nxFont(.caption).foregroundStyle(GateColor.muted) } }
        else if let n = p.note { Text(n).nxFont(.caption).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true) }
    }
    private var folderValue: String {
        switch profile.folderState {
        case .chosen(let n): return "iCloud Drive › \(n)"
        case .stale: return "Choose your NX 18 folder again"
        case .unreachable: return "Cannot be reached now"
        case .none: return "Not chosen"
        }
    }
    private func row(_ item: NX18CardItem, _ title: String, _ value: String, action: (() -> Void)?, button: String?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                    Text(verbatim: value).nxFont(.caption).foregroundStyle(GateColor.line).lineLimit(2).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 6)
                if let button { Text(button).nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.line) }
                else { Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold)).foregroundStyle(GateColor.line) }   // system: symbol
            }
            .padding(.horizontal, 12).frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused == item ? GateColor.lit : GateColor.tile))
            .overlay { if focused == item { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
        }
        .buttonStyle(NX18PressStyle()).disabled(action == nil).id(item)
        .accessibilityLabel(title).accessibilityValue(value)
    }

    // "Appearance ‹ Match device ›": ‹ and › step it (44 × 46 pt), a tap on the value steps it on, a sideways swipe steps it. Each step applies at once (§20.5b)
    private var appearanceRow: some View {
        HStack(spacing: 0) {
            Text("Appearance").nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1).padding(.leading, 12)
            Spacer(minLength: 6)
            stepButton(-1, "chevron.left", "Previous")
            Button { step(1) } label: {
                Text(look.title).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.line).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(minWidth: 92, minHeight: 46)
            }
            .buttonStyle(NX18PressStyle())
            stepButton(1, "chevron.right", "Next")
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(focused == .appearance ? GateColor.lit : GateColor.tile))
        .overlay { if focused == .appearance { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false) } }
        .gesture(DragGesture(minimumDistance: 24).onEnded { g in if abs(g.translation.width) > abs(g.translation.height) { step(g.translation.width > 0 ? 1 : -1) } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Appearance")
        .accessibilityValue(look.title)
        .accessibilityAdjustableAction { d in step(d == .increment ? 1 : -1) }
    }
    private func stepButton(_ by: Int, _ symbol: String, _ label: String) -> some View {
        Button { step(by) } label: {
            Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(GateColor.line).frame(width: 44, height: 46).contentShape(Rectangle())   // system: symbol
        }
        .buttonStyle(NX18PressStyle())
        .accessibilityLabel(label)
    }
    private func step(_ by: Int) {
        let next = look.stepped(by)
        look = next
        NX18Appearance.current = next   // the Gate's host takes the style at once (DmHostingController.followAppearance)
    }
    private func hint(_ g: NXPadGlyph, _ text: String) -> some View {
        HStack(spacing: 5) { NXPadGlyphView(g, size: 15, relativeTo: .caption2).foregroundStyle(GateColor.line); Text(text).nxFont(.caption).foregroundStyle(GateColor.muted) }
    }
}

// The 72 pt circle: the player's picture, else the default (§20.2: an abstract NX 18 shape, two offset rings and a wave in cyan and coral; not a person or a character).
// Read when the card opens (version bumps on a change), freed when it closes
struct NX18ProfilePictureView: View {
    let version: Int
    let has: Bool
    let url: URL
    var body: some View {
        ZStack {
            if has, let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                Image(decorative: img, scale: 1).resizable().scaledToFill()
            } else {
                NX18DefaultPicture()
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(GateColor.hairline, lineWidth: 1))
        .id(version)
    }
}
