"""Manual & documents while the game runs (dm/ios/Sources/GameDocumentsViewer.swift, shared by the iPhone and iPad app and the Mac's game app), checked in the sources: the in-game
menu's row and door (GameMenu.swift), the viewer inside the panel (GameMenuPanel.swift; dm/mac/GameMenuMac.swift draws it unscaled), the controller's moves, the input it holds
like the menu, the Mac host building it, the UIMenu's way in (DmGamepad.m), the Gate's My files (Launcher.swift, GuideViewer.swift; dm/mac/Launcher.swift's Manual pill), and no
names or paths in its logs. Two pieces are compiled from the sources and run: the first page's door lines (GameMenuLayout.doorLines) and the controller's moves
(GameDocumentControl.handle). The list, its order and the row's words run in test_game_documents.py. What none of them runs: the viewer itself, which needs a window."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / 'dm/ios/Sources'


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def block(src, header):
    """The text from header through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[i:k + 1]
    raise AssertionError(header)


class DocumentsInGameWiring(unittest.TestCase):
    def setUp(self):
        self.viewer = read('dm/ios/Sources/GameDocumentsViewer.swift'); self.menu = read('dm/ios/Sources/GameMenu.swift')
        self.panel = read('dm/ios/Sources/GameMenuPanel.swift'); self.mac = read('dm/mac/GameMenuMac.swift')

    def test_row_and_door(self):
        self.assertIn('if let docs = gameDocumentsRow() { sections.append(GameMenuSection(id: "section:docs", heading: "More", items: [docs])) }', self.menu, 'the UIMenu and the flat list')
        home = block(self.menu, '@MainActor func gameMenuHome() -> GameMenuHome {')
        cheats, docs, more = home.index('$0.id == "cheats"'), home.index('$0.id == "docs"'), home.index('door.more')
        self.assertLess(cheats, docs); self.assertLess(docs, more, 'a door on the first page, between Cheats and More')
        self.assertNotIn('"docs"', re.search(r'gameMenuMoreIDs: Set<String> = \[(.*?)\]', self.menu).group(1), 'not repeated under More')
        row = block(self.viewer, '@MainActor func gameDocumentsRow() -> GameMenuItem? {')
        self.assertIn('guard GameDocuments.offered(docs) else { return nil }', row, 'only with a manual, a guide or a document')
        self.assertIn('title: "Manual & documents"', row)
        self.assertIn('kind: .submenu(', row, 'a page of the documents')
        self.assertIn('store.refresh()', row, 'listed as the menu opens')
        self.assertIn('GameDocuments.load(', block(self.viewer, 'func refresh() {'), 'off the main thread')
        self.assertIn('ContinuousClock.now - last < .seconds(3)', self.viewer, 'at most every few seconds, no polling')
        self.assertIn('right += GameMenuLayout.doorLines(model.home.doors.map(\\.id))', self.panel, 'the controller steps over the door lines as drawn')
        self.assertIn('ForEach(Array(GameMenuLayout.doorLines(model.home.doors).enumerated())', self.panel)

    def test_viewer_is_part_of_the_panel(self):
        handle = block(self.panel, 'func handle(_ e: LauncherPadEvent) {')
        first = handle.index('if document != nil'); presets = handle.index('case .l: stepPreset(-1)')
        self.assertLess(first, presets, 'the viewer takes the controller before the preset buttons')
        for line in ('if documentControl.handle(e) { return }', 'case .b: closeDocument()', 'case .plus: close()', 'case .zl: stepDocument(-1)', 'case .zr: stepDocument(1)'):
            self.assertIn(line, handle)
        self.assertIn('if document != nil { closeDocument(); return }', block(self.panel, 'func back() {'), 'Escape, VoiceOver\'s escape and the dim go back to the list')
        close = block(self.panel, 'func closeDocument() {')
        self.assertIn('if open.direct { close(); return }', close, 'from the UIMenu B closes the panel too')
        self.assertIn('focus = "doc:" + open.doc.id', close, 'back on its row')
        self.assertNotIn('dm_gamepad_panel_closed', self.viewer, 'the viewer never gives the game its input back: the panel does, as it closes')
        self.assertIn('if !model.leaving && model.document == nil {', self.panel, 'the panel steps aside under the viewer')
        self.assertIn('GameDocumentViewer(model: model, control: model.documentControl, open: open)', self.panel, 'the iPhone\'s viewer in the panel\'s view')
        self.assertIn('let url = await GameDocuments.fetch(d)', block(self.panel, 'func openDocument('), 'an iCloud placeholder is brought down only when opened')
        root = block(self.mac, 'struct GameMenuMacRoot: View {')
        self.assertIn('GameDocumentViewer(model: model, control: model.documentControl, open: open, chrome: s)', root)
        self.assertLess(root.index('.scaleEffect(s, anchor: .topLeading)'), root.index('GameDocumentViewer('), 'the Mac\'s viewer is outside the scaled panel')

    def test_viewers_by_kind(self):
        content = block(self.viewer, 'struct GameDocumentContent: View {')
        for kind, view in (('.manual, .pdf', 'GameDocPDF'), ('.picture', 'GameDocPicture'), ('.text', 'GameDocText'), ('.web', 'GameDocWeb'), ('.guide', 'GameDocGuide')):
            self.assertIn(f'case {kind}: {view}(', content)
        self.assertIn('v.displayMode = .singlePageContinuous', self.viewer, 'PDFKit pages a PDF as it shows')
        self.assertIn('kCGImageSourceThumbnailMaxPixelSize: side', self.viewer, 'a picture is decoded no larger than needed')
        self.assertIn('Task.detached(priority: .userInitiated) { Self.decode(u) }', self.viewer, 'off the main thread')
        self.assertIn('LazyVStack', block(self.viewer, 'struct GameDocText: View {'), 'a long text draws only what shows')
        self.assertIn('data.prefix(4 << 20)', self.viewer)
        self.assertIn('LauncherGuideFiles.configuration(files: files, handler: self)', self.viewer, 'pages offline, as the guide')
        self.assertIn('case .end: close(); return .cancel', self.viewer)
        self.assertIn('files.quiet = quiet', self.viewer); self.assertIn('quiet: true', block(self.viewer, 'struct GameDocWeb: GameDocRepresentable {'), 'no names of the player\'s files in the log')
        self.assertIn('private var page: some View { LauncherGuideWebView(index: index, root: root, model: model, close: close) }', self.viewer, 'the iPhone\'s guide as before play')
        self.assertIn('@MainActor final class LauncherGuidePageModel: ObservableObject', read('dm/ios/Sources/LauncherGuideFiles.swift'), 'the guide\'s model, shared with the Mac')

    def test_no_names_or_paths_in_logs(self):
        for line in re.findall(r'fputs\((.*)\)', self.viewer + block(self.panel, 'func openDocument(')):
            self.assertNotRegex(line, r'\\\((url|u|d\.title|d\.url|open\.doc\.title|.*\.path)', line)

    def test_player_page_end_logs_no_path(self):
        files = read('dm/ios/Sources/LauncherGuideFiles.swift')
        nav = files[files.index('static func navigation('):files.index('let root: URL')]
        self.assertIn('quiet ? "launcher: the page ended\\n"', nav, 'a page of the player\'s: the localhost link\'s path is not logged')
        self.assertIn('LauncherGuideFiles.navigation(action.request.url, quiet: files.quiet)', self.viewer)
        self.assertIn('model: nil, quiet: true', self.viewer, 'the player\'s pages are quiet, the guide is not')

    def test_uimenu_refreshes_when_the_listing_returns(self):
        menu = read('dm/ios/Sources/GameMenu.swift')
        self.assertIn('void *dm_game_menu(void *button);', read('dm/ios/Sources/DmGameMenu.h'))
        self.assertIn('dm_game_menu((__bridge void *)_menu)', read('dm/ios/Sources/DmGamepad.m'))
        self.assertIn('GameDocumentsStore.shared.menuChanged = refreshVisibleSystemMenu', menu)
        self.assertIn('updateVisibleMenu { m in m.identifier == systemMenuRoot ? m.replacingChildren(gameMenuItems()) : m }', menu, 'only the top level is rebuilt')
        store = block(self.viewer, 'final class GameDocumentsStore {')
        self.assertLess(store.index('self.changed?()'), store.index('self.menuChanged?()'))

    def test_mac_host_builds_it(self):
        make = read('dm/host/Makefile')
        files = re.search(r'MENU_SWIFT = (.*?)\nMENU_H', make, re.S).group(1)
        for f in ('GameDocuments.swift', 'GameDocumentsViewer.swift', 'LauncherGuideFiles.swift'): self.assertIn(f, files)
        self.assertRegex(make, r'MENU_LIBS = .*-framework PDFKit')
        self.assertIn('-framework WebKit', make)
        self.assertIn('-framework ImageIO', make)
        duo = read('dm/ios/tests/duo/project.yml')
        for f in ('GameDocuments.swift', 'GameDocumentsViewer.swift'): self.assertIn(f'../../Sources/{f}', duo, 'the Duo harness builds the menu with it')

    def test_uimenu_opens_the_panel_for_a_document(self):
        pad = read('dm/ios/Sources/DmGamepad.m')
        self.assertIn('- (void)panelOpenAlways { BOOL system = _systemMenu; _systemMenu = NO; [self panelOpen]; _systemMenu = system; }', pad, 'through panelOpen: the controllers held first')
        self.assertIn('bool dm_gamepad_panel_open_now(void) { if (g_view) [g_view panelOpenAlways]; return dm_game_panel_shown(); }', pad)
        self.assertIn('bool dm_gamepad_panel_open_now(void);', read('dm/ios/Sources/DmGameMenu.h'))
        self.assertIn('if dm_gamepad_panel_open_now(), let m = GameMenuPanelModel.current, !m.closed { m.openDocument(d, direct: true) }', self.viewer)

    def test_gate_shows_my_files_on_its_guide_button(self):
        launcher = read('dm/ios/Sources/Launcher.swift'); guide = read('dm/ios/Sources/GuideViewer.swift')
        self.assertIn('private var hasReading: Bool { content.hasGuide || !mine.isEmpty }', launcher)
        self.assertIn('if hasReading {   // the guide, else the manual, else the player\'s own documents (My files) on the same button: no new one', launcher)
        self.assertIn('LauncherGuideSheet(content: content, scroller: scroller, mine: mine,', launcher)
        self.assertIn('case guide, manual, mine', guide)
        self.assertIn('GameDocumentContent(doc: open.doc, url: url, control: docControl, close: { unpick() })', guide, 'the same views as in game')
        mac = read('dm/mac/Launcher.swift')
        self.assertIn('if !mine.isEmpty {   // the player\'s documents on the Manual pill\'s place, as a menu (no new pill)', mac)
        self.assertIn("HERE.parent / 'ios/Sources/GameDocuments.swift'", read('dm/mac/pack_app.py'))


SWIFTC = sys.platform == 'darwin' and shutil.which('xcrun')


@unittest.skipUnless(SWIFTC, 'needs the macOS Swift toolchain')
class DocumentsInGamePieces(unittest.TestCase):
    def run_swift(self, source):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp); (tmp / 'main.swift').write_text(source, encoding='utf-8')
            c = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-module-cache-path', str(tmp / 'mc'), '-o', str(tmp / 'check'), str(tmp / 'main.swift')],
                               capture_output=True, text=True, timeout=300)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            r = subprocess.run([str(tmp / 'check')], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            return r.stdout

    def test_door_lines(self):
        fn = block(read('dm/ios/Sources/GameMenuPanel.swift'), 'static func doorLines<T>(')
        out = self.run_swift('enum L {\n' + fn + '\n}\n'
                             'for n in 0...6 { print(n, L.doorLines(Array(0..<n)).map { $0.count }) }\n')
        self.assertIn('0 []', out)
        self.assertIn('3 [3]', out, 'three doors on one line, as before')
        self.assertIn('4 [2, 2]', out, 'Customize, Cheats, Manual & documents and More two by two')
        self.assertIn('5 [3, 2]', out)

    def test_controller_moves(self):
        viewer = read('dm/ios/Sources/GameDocumentsViewer.swift')
        event = re.search(r'enum LauncherPadEvent[^\n]*\n', read('dm/ios/Sources/LauncherFocus.swift')).group(0)
        control = block(viewer, '@MainActor final class GameDocumentControl: ObservableObject {')
        out = self.run_swift('import Combine\nimport CoreGraphics\n' + event +
                             '@MainActor final class LauncherGuidePageModel { var got: [LauncherPadEvent] = []; func handle(_ e: LauncherPadEvent) -> Bool { got.append(e); return e != .b } }\n'
                             + control + '\n'
                             '@MainActor func check() {\n'
                             '  let c = GameDocumentControl(); var log: [String] = []\n'
                             '  c.move = { x, y in log.append("move \\(Int(x)) \\(Int(y))") }; c.page = { log.append("page \\($0)") }; c.zoom = { log.append("zoom \\($0)") }; c.fit = { log.append("fit") }\n'
                             '  let all: [LauncherPadEvent] = [.up, .down, .left, .right, .l, .r, .x, .y, .a, .b, .plus, .zl, .zr, .minus]\n'
                             '  print("took", all.map { c.handle($0) ? 1 : 0 })\n'
                             '  print(log.joined(separator: ","))\n'
                             '  let g = LauncherGuidePageModel(); c.take(); c.guide = g\n'
                             '  print("guide", [.a, .b, .plus, .zl, .l].map { c.handle($0) ? 1 : 0 }, g.got.count)\n'
                             '}\n'
                             'MainActor.assumeIsolated { check() }\n')
        self.assertIn('took [1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1]', out, 'B, +, ZL and ZR are the viewer\'s; the rest the document\'s')
        self.assertIn('move 0 -1,move 0 1,move -1 0,move 1 0,page -1,page 1,zoom 1,zoom -1,fit', out, 'the D-pad moves, L / R page, X / Y zoom, A fits')
        self.assertIn('guide [1, 0, 0, 0, 1] 3', out, 'on the guide its page takes A, B (going back a page first) and L; +, ZL and ZR stay the viewer\'s')


if __name__ == '__main__':
    unittest.main()
