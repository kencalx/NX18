// The NX 18 card's Profile rows and the welcome's flows, the iPhone and iPad side (NX18-X2.0 gate-ui.md §20.2-§20.6, §21.3-§21.5): the photo picker and its circle crop,
// the name bar over the keyboard, the Profile and NX 18 folder switch, the folder pick with its careful read, and This game's saves with its move (save_sync_move,
// dm/host/save_sync.h). One flow object per Gate; the card and the welcome call it, and the sheets and questions hang off whichever is on screen
// (.nx18ProfileFlow). Every question is a plain dialog: no hold-to-confirm (the console survey: every console asks with a dialog).
#if os(iOS)
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class NX18ProfileFlow: ObservableObject {
    let profile = NX18Profile.shared
    @Published var photoPicking = false
    @Published var crop: CGImage?
    @Published var nameEditing = false
    @Published var folderPicking = false
    @Published var question: Question?
    @Published var busy: String?          // "Looking for your profile…", "Moving your save…"
    @Published var note: String?          // the row's last result: "Moved and checked.", "Could not move. Try again when online."
    @Published var strip: String?         // a pad's line: what needs touch
    @Published var cloudShared = dm_nx18_cloud_shared()
    var folderPicked: ((Bool) -> Void)?   // the welcome's continuation after a pick (Create step 2, Connect)
    var connecting = false                // Connect to my NX 18 folder: a folder with no Profile asks (Create one here / Choose another) instead of taking this device's

    enum Question: Identifiable {
        case moveSaves(toShared: Bool)
        case replace(toShared: Bool, mine: Int64, theirs: Int64)
        case useFound(name: String)
        case emptyFolder
        case unreachable
        case profileOff
        var id: String {
            switch self {
            case .moveSaves(let s): return "move\(s)"
            case .replace(let s, _, _): return "replace\(s)"
            case .useFound: return "found"
            case .emptyFolder: return "empty"
            case .unreachable: return "unreachable"
            case .profileOff: return "off"
            }
        }
    }

    // ---- the picture and the name: touch or a keyboard; with a pad the strip says so (§10) ----
    func choosePicture(pad: Bool) { if pad { strip = "Choosing a picture needs touch." } else { photoPicking = true } }
    func editName(pad: Bool) { if pad { strip = "Typing a name needs touch or a keyboard." } else { nameEditing = true } }

    func picked(photo url: URL?) {
        photoPicking = false
        guard let url, let img = NX18ProfilePicture.thumbnail(of: url) else { return }
        crop = img
    }
    func usePicture(_ cropped: CGImage) {
        crop = nil
        guard let jpeg = NX18ProfilePicture.jpeg(from: cropped) else { note = "That picture could not be used."; return }
        profile.setPicture(jpeg: jpeg)
    }

    // ---- the switch (§20.6) ----
    func toggleProfile() {
        if profile.enabled {
            // Off: this game's saves go back to its own folder. With none, the NX 18 folder itself becomes its own folder (the same <NX 18>/<title ID> file: nothing moves)
            if cloudShared, dm_cloud_saves_path(nil) == nil, NX18Profile.folderURL() == nil { question = .profileOff; return }
            turnOff()
        } else {
            profile.enabled = true
            if NX18Profile.folderURL() == nil { folderPicking = true }   // with none chosen: the Create flow's folder step
        }
    }
    func turnOff() {
        if cloudShared {
            if dm_cloud_saves_path(nil) != nil { moveSaves(toShared: false, how: SS_MOVE_ASK_FIRST) }
            else if let f = NX18Profile.folderURL() { _ = dm_store_cloud_saves(f); setShared(false) }
        }
        profile.enabled = false
    }

    // ---- the NX 18 folder (§20.2 item 6, §21.3) ----
    func chooseFolder(pad: Bool) {
        if pad { strip = "The folder picker needs touch, a keyboard or a mouse. B closes it." }
        folderPicking = true
    }
    func picked(folder url: URL?) {
        folderPicking = false
        guard let url else { folderPicked?(false); folderPicked = nil; return }
        guard dm_store_nx18_folder(url), let folder = NX18Profile.folderURL() else { note = "That folder could not be remembered."; folderPicked?(false); folderPicked = nil; return }
        profile.refreshFolderState()
        busy = "Looking for your profile…"
        Task.detached(priority: .userInitiated) {
            let found = NX18ProfileSync.careful(folder: folder)
            await MainActor.run { self.afterRead(found, folder: folder) }
        }
    }
    private func afterRead(_ found: NX18ProfileSync.Found?, folder: URL) {
        busy = nil
        switch found {
        case nil: question = .unreachable   // a timeout is never read as "no profile"
        case .profile(let n)?:
            // Connect takes the folder's Profile; Create (or a new folder on the card) with a Profile of its own here asks first: the welcome never writes over one (§21.3)
            if connecting || !profile.isSet { useFoundProfile() } else { question = .useFound(name: n) }
        case .none?:
            if connecting { question = .emptyFolder } else { createHere() }
        }
    }
    // A folder read in full and found empty: this device's Profile is written there (it has none to write over)
    func createHere() {
        connecting = false
        guard let folder = NX18Profile.folderURL() else { return }
        profile.enabled = true
        NX18ProfileSync.push(local: profile.local, folder: folder)
        enterSharedSaves()
        folderPicked?(true); folderPicked = nil
    }
    func useFoundProfile() {
        guard let folder = NX18Profile.folderURL() else { return }
        connecting = false; profile.enabled = true
        NX18ProfileSync.lastSeen = nil
        try? FileManager.default.removeItem(at: profile.local.appendingPathComponent("profile.stamp"))   // the folder's Profile wins over this device's
        NX18ProfileSync.pull(local: profile.local, folder: folder)
        profile.reload(); profile.lookAtFolder()
        enterSharedSaves()
        folderPicked?(true); folderPicked = nil
    }
    func chooseAnother() { dm_clear_nx18_folder(); profile.refreshFolderState(); folderPicking = true }

    // Connect / Create with a folder: this game's cloud saves go in <NX 18>/<title ID> (GW25); an existing own folder is asked about once (§21.3 Existing users)
    private func enterSharedSaves() {
        if dm_cloud_saves_path(nil) != nil { question = .moveSaves(toShared: true) } else { setShared(true) }
    }
    private func setShared(_ on: Bool) { dm_set_nx18_cloud_shared(on); cloudShared = on }

    // ---- This game's saves: ‹ NX 18 folder | Own folder › (§20.2 item 7, §21.4) ----
    func savesTapped() {
        if !cloudShared { question = .moveSaves(toShared: true); return }
        if dm_cloud_saves_path(nil) == nil { note = "Choose this game's own folder first, on the Cloud saves page."; return }
        question = .moveSaves(toShared: false)
    }
    func moveSaves(toShared: Bool, how: ss_move) {
        guard let nx = NX18Profile.folderURL()?.path, let own = dm_cloud_saves_path(nil) else { setShared(toShared); return }
        guard let save = getenv("DM_SAVE").map({ String(cString: $0) }) else { setShared(toShared); return }
        let (from, to) = toShared ? (own, nx) : (nx, own)
        busy = "Moving your save…"; note = nil
        Task.detached(priority: .userInitiated) {
            var out = [CChar](repeating: 0, count: 160)
            let r = save_sync_move(save, from, to, dm_save_title(), how, 0, &out, out.count)
            let line = String(decoding: out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)   // up to the NUL (init(cString:) on an array is deprecated)
            await MainActor.run { self.afterMove(r, line: line, toShared: toShared) }
        }
    }
    private func afterMove(_ r: Int32, line: String, toShared: Bool) {
        busy = nil
        switch r {
        case Int32(SS_MOVE_DONE), Int32(SS_MOVE_SAME):
            setShared(toShared); note = r == Int32(SS_MOVE_DONE) ? "Moved and checked." : nil
        case Int32(SS_MOVE_ASK):
            var f: [String: Int64] = [:]
            for p in line.split(separator: " ") { let kv = p.split(separator: "=", maxSplits: 1); if kv.count == 2 { f[String(kv[0])] = Int64(kv[1]) } }
            question = .replace(toShared: toShared, mine: f["from_saved"] ?? 0, theirs: f["to_saved"] ?? 0)
        default:
            note = "Could not move. Try again when online."
        }
    }

    static func day(_ secs: Int64) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(secs)))
    }
}

// The sheets and questions, on whichever view shows the flow (the card's layer, the welcome)
struct NX18ProfileFlowModifier: ViewModifier {
    @ObservedObject var flow: NX18ProfileFlow

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.photoPicking) { NX18PhotoPicker { flow.picked(photo: $0) }.ignoresSafeArea() }
            .fullScreenCover(item: Binding(get: { flow.crop.map { NX18CropItem(image: $0) } }, set: { if $0 == nil { flow.crop = nil } })) { item in
                NX18CropView(image: item.image, use: { flow.usePicture($0) }, cancel: { flow.crop = nil })
            }
            .fullScreenCover(isPresented: $flow.nameEditing) {
                NX18NameBar(start: flow.profile.name == "Player" ? "" : flow.profile.name) { name in
                    flow.nameEditing = false
                    if let name, !flow.profile.setName(name) { flow.note = NX18ProfileName.refusal }
                }
                .presentationBackground(.clear)
            }
            .sheet(isPresented: $flow.folderPicking, onDismiss: { if flow.folderPicking { flow.picked(folder: nil) } }) {
                NX18FolderPicker { flow.picked(folder: $0) }.ignoresSafeArea()
            }
            .alert(title, isPresented: Binding(get: { flow.question != nil }, set: { if !$0 { flow.question = nil } }), presenting: flow.question) { q in
                buttons(q)
            } message: { q in Text(message(q)) }
    }

    private var title: String {
        switch flow.question {
        case .moveSaves(let s)?: return s ? "Move this game's cloud saves to the NX 18 folder?" : "Move this game's cloud saves to its own folder?"
        case .replace?: return "Replace the save there?"
        case .useFound?: return "This folder already has a profile"
        case .emptyFolder?: return "This folder has no NX 18 profile."
        case .unreachable?: return "Your NX 18 folder cannot be reached now."
        case .profileOff?: return "Turn off the Profile and NX 18 folder for this game?"
        case nil: return ""
        }
    }
    private func message(_ q: NX18ProfileFlow.Question) -> String {
        switch q {
        case .moveSaves: return "The save is copied and checked before the folder changes. The old copy stays."
        case .replace(_, let mine, let theirs):
            return "The NX 18 folder already has another save of this game, from \(NX18ProfileFlow.day(theirs)). Replace it with this one, from \(NX18ProfileFlow.day(mine))? The other is kept as a backup."
        case .useFound(let n): return "This folder already has a profile: \(n)."
        case .emptyFolder: return "Create one here, or choose another folder."
        case .unreachable: return "Not now keeps the folder and tries again next time."
        case .profileOff: return "This game's cloud saves stay in the NX 18 folder, now as its own folder. Nothing is deleted."
        }
    }
    @ViewBuilder private func buttons(_ q: NX18ProfileFlow.Question) -> some View {
        switch q {
        case .moveSaves(let s):
            Button("Move") { flow.moveSaves(toShared: s, how: SS_MOVE_ASK_FIRST) }
            Button(s ? "Keep them where they are" : "Cancel", role: .cancel) {}
        case .replace(let s, _, _):
            Button("Replace", role: .destructive) { flow.moveSaves(toShared: s, how: SS_MOVE_REPLACE) }
            Button("Use the one there") { flow.moveSaves(toShared: s, how: SS_MOVE_USE_THERE) }
            Button("Cancel", role: .cancel) {}
        case .useFound:
            Button("Use this profile") { flow.useFoundProfile() }
            Button("Choose another") { flow.chooseAnother() }
        case .emptyFolder:
            Button("Create one here") { flow.createHere() }
            Button("Choose another") { flow.chooseAnother() }
        case .unreachable:
            Button("Try again") { flow.picked(folder: NX18Profile.folderURL()) }
            Button("Not now", role: .cancel) { flow.folderPicked?(false); flow.folderPicked = nil }
        case .profileOff:
            Button("Turn Off", role: .destructive) { flow.turnOff() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
extension View {
    func nx18ProfileFlow(_ flow: NX18ProfileFlow) -> some View { modifier(NX18ProfileFlowModifier(flow: flow)) }
}

struct NX18CropItem: Identifiable { let image: CGImage; var id: ObjectIdentifier { ObjectIdentifier(image) } }

// Apple's photo picker: no photo library permission and no Info.plist usage key. The file representation, never the whole photo decoded (§20.3)
struct NX18PhotoPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration(); c.filter = .images; c.selectionLimit = 1
        let p = PHPickerViewController(configuration: c); p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let done: (URL?) -> Void
        init(_ d: @escaping (URL?) -> Void) { done = d }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first?.itemProvider, item.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { DispatchQueue.main.async { self.done(nil) }; return }
            item.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // the file goes when this returns: a copy of our own for the crop's thumbnail read
                var copy: URL?
                if let url {
                    let to = FileManager.default.temporaryDirectory.appendingPathComponent("nx18-photo-\(UUID().uuidString).\(url.pathExtension)")
                    if (try? FileManager.default.copyItem(at: url, to: to)) != nil { copy = to }
                }
                DispatchQueue.main.async { self.done(copy) }
            }
        }
    }
}

struct NX18FolderPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        p.delegate = context.coordinator; p.allowsMultipleSelection = false; return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ d: @escaping (URL?) -> Void) { done = d }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
    }
}

// The square crop under a circle mask (§20.3): pinch to zoom, drag to move; with a pad the stick moves, L and R zoom, A uses it, B cancels. 44 pt buttons
struct NX18CropView: View {
    let image: CGImage
    let use: (CGImage) -> Void
    let cancel: () -> Void
    @State private var scale: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    @StateObject private var pad = LauncherGamepad()

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height) - 120
            VStack(spacing: 16) {
                Text("Choose a picture").nxFont(.headline, weight: .semibold).foregroundStyle(.white)
                ZStack {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: side, height: side)
                        .scaleEffect(scale * pinch).offset(x: offset.width + drag.width, y: offset.height + drag.height)
                        .frame(width: side, height: side).clipped()
                    Rectangle().fill(.black.opacity(0.55)).frame(width: side, height: side)
                        .mask(Rectangle().overlay(Circle().padding(2).blendMode(.destinationOut)).compositingGroup())
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: side - 4, height: side - 4)
                }
                .gesture(MagnificationGesture().onChanged { pinch = $0 }.onEnded { scale = clampScale(scale * $0); pinch = 1 })
                .simultaneousGesture(DragGesture().onChanged { drag = $0.translation }.onEnded { offset.width += $0.translation.width; offset.height += $0.translation.height; drag = .zero })
                HStack(spacing: 16) {
                    Button("Cancel", action: cancel).frame(minWidth: 120, minHeight: 44).background(Capsule().fill(.white.opacity(0.15))).foregroundStyle(.white)
                    Button("Use picture") { if let c = cropped(side: side) { use(c) } }.frame(minWidth: 120, minHeight: 44)
                        .background(Capsule().fill(GateColor.chosen)).foregroundStyle(GateColor.ink)
                }
                .nxFont(.body, weight: .semibold)
            }
            .frame(width: g.size.width, height: g.size.height)
            .task { await pad.run { e in
                switch e {
                case .a: if let c = cropped(side: side) { use(c) }
                case .b: cancel()
                case .l: scale = clampScale(scale / 1.1)
                case .r: scale = clampScale(scale * 1.1)
                case .left: offset.width += 12
                case .right: offset.width -= 12
                case .up: offset.height += 12
                case .down: offset.height -= 12
                default: break
                }
            } }
        }
        .background(Color.black.ignoresSafeArea())
        .nxTextRoot()
    }
    private func clampScale(_ s: CGFloat) -> CGFloat { max(1, min(6, s)) }
    // The visible square in the image's pixels: scaledToFill puts the short side across the square; scale and offset move inside it
    private func cropped(side: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height), fill = max(side / w, side / h) * scale
        let visible = side / fill
        let cx = w / 2 - offset.width / fill, cy = h / 2 - offset.height / fill
        var r = CGRect(x: cx - visible / 2, y: cy - visible / 2, width: visible, height: visible)
        r.origin.x = max(0, min(w - visible, r.origin.x)); r.origin.y = max(0, min(h - visible, r.origin.y))
        return image.cropping(to: r.integral)
    }
}

// The name, edited in a small bar on top of the keyboard (§20.3): the field, a count ("4/10") and Done; the card stays where it is, so the field is never under the keyboard
struct NX18NameBar: View {
    @State var text: String
    let done: (String?) -> Void
    @FocusState private var focused: Bool
    init(start: String, done: @escaping (String?) -> Void) { _text = State(initialValue: start); self.done = done }

    var body: some View {
        VStack {
            Color.black.opacity(0.25).contentShape(Rectangle()).onTapGesture { done(nil) }
            HStack(spacing: 10) {
                TextField("Player", text: $text).focused($focused).submitLabel(.done).onSubmit { done(text) }
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                    .onChange(of: text) { _, v in if v.count > NX18ProfileName.maxCharacters { text = String(v.prefix(NX18ProfileName.maxCharacters)) } }
                    .nxFont(.body).foregroundStyle(GateColor.text)
                    .accessibilityLabel("Name")
                Text("\(text.count)/\(NX18ProfileName.maxCharacters)").nxFont(.footnote).foregroundStyle(GateColor.muted).monospacedDigit()
                Button("Done") { done(text) }.nxFont(.body, weight: .semibold).frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(GateColor.slab)
        }
        .onAppear { focused = true }
        .nxTextRoot()
    }
}
#endif
