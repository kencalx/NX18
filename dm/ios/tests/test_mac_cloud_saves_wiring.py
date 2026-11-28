"""This game's saves on the Mac (dm/mac/Launcher.swift MacSavesFlow and MacProfileFlow, dm/mac/launcher.c dm_mac_cloud_place, NX18CloudSaves in dm/ios/Sources/NX18Profile.swift,
NX 18 Beam's GameSettingsView and game page), checked in the sources: the NX 18 card's This game's saves row is wired on the Mac, the window and Beam pass the NX 18 folder to the
Cloud saves door, the window asks launcher.c where the saves go (one rule for the check before Play and the host's DM_SAVE_SYNC), a switch moves the save with the host's
save_sync_move and asks before replacing, and launcher.c's log lines name the place, never the folder.

What runs elsewhere: launcher.c's choice in a packed app with a stand-in host and the layout an iPhone's host reads (dm/tools/tests/test_nsp_mac_app.py test_cloud_saves_place),
the rule in Swift (beam/Tests/CloudSavesPlaceTests.swift), the move itself (dm/host/tests/t_save_sync.c)."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the declaration whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class MacCloudSaves(unittest.TestCase):
    def setUp(self):
        self.mac = read('dm/mac/Launcher.swift'); self.c = read('dm/mac/launcher.c'); self.rule = read('dm/ios/Sources/NX18Profile.swift')

    def test_card_row_is_wired(self):
        rows = body(self.mac, 'static var rows: NX18CardProfile')
        self.assertIn('shared: MacCloud.place().inNX18', rows)
        self.assertIn('saves: saves', rows); self.assertIn('f.savesTapped()', rows)
        self.assertIn('busy: f.busy, note: f.note', rows)
        self.assertIn('CloudSavesSection.fixed == nil', rows)   # a DM_SAVE_SYNC the launch or an env file set: no choice on the card
        self.assertIn('MacSavesFlow.shared.enterShared()', body(self.mac, 'static func chooseFolder()'))   # connecting a folder: the saves go there, an own folder's asked about

    def test_door_and_page_follow_the_place(self):
        self.assertIn('savesInNX18Folder: cloudPlace.inNX18', self.mac)
        self.assertIn('return MacCloud.place()', body(self.mac, 'private var cloudPlace'))
        self.assertIn('place().folder', body(self.mac, 'static var folderName'))
        settings = read('beam/Sources/Views/GameSettingsView.swift')
        self.assertIn('savesInNX18Folder: place.inNX18', settings)
        self.assertIn('NX18CloudSaves.place(source.defaults, nx18: ProfileSetup.connectedFolder())', settings)
        self.assertIn('c.plainWords', read('beam/Sources/Views/GameDetailView.swift'))

    def test_one_rule_for_the_check_and_the_host(self):
        report = body(self.mac, 'static func report()')
        self.assertIn('MacCloud.place().folder', report); self.assertNotIn('"cloudSaves.folder"', report)
        place = body(self.mac, 'nonisolated static func place()')
        self.assertIn('dm_mac_cloud_place(', place)
        self.assertIn('@_silgen_name("dm_mac_cloud_place")', self.mac)
        self.assertIn('int dm_mac_cloud_place(char *out, size_t n, int *missed)', self.c)
        folder = body(self.c, 'static void cloud_saves_folder(void)')
        self.assertLess(folder.index('getenv("DM_SAVE_SYNC")'), folder.index('dm_mac_cloud_place('))   # the launch's or an env file's DM_SAVE_SYNC wins
        # launcher.c and NX18CloudSaves.decide say the same: shared when chosen (whatever the Profile switch, as on the iPhone), or by default with no choice ("own" is one),
        # no cloudSaves.folder at all ("" is a Turn off) and the Profile on; only with a folder there
        self.assertIn('int shared = !strcmp(choice, "shared"), dflt = !shared && strcmp(choice, "own") && !own_set && profile_on(domain);', self.c)
        self.assertIn('if ((shared || dflt) && *nx)', self.c)
        self.assertIn('let shared = choice == "shared", dflt = !shared && choice != "own" && own == nil && profileOn', self.rule)
        self.assertIn('if let nx = nx18, !nx.isEmpty, shared || dflt { return .nx18(nx) }', self.rule)
        self.assertIn('source.defaults.set("", forKey: NX18CloudSaves.folderKey)', read('beam/Sources/Views/GameSettingsView.swift'))   # Beam's Turn off stores "", as the window
        self.assertIn('S_ISDIR(st.st_mode)', body(self.c, 'int dm_mac_cloud_place('))
        self.assertIn('profile_on(domain)', body(self.c, 'int dm_mac_cloud_place('))

    def test_log_names_no_folder(self):
        folder = body(self.c, 'static void cloud_saves_folder(void)')
        calls = re.findall(r'fprintf\(stderr, "[^"]*"[^;]*;', folder)
        self.assertEqual(len(calls), 2)
        for call in calls: self.assertIsNone(re.search(r'[(,]\s*f\s*[),]', call.split('"')[-1]), call)   # the folder (f) is never an argument: the place's name only

    def test_move_rules(self):
        flow = body(self.mac, 'final class MacSavesFlow')
        self.assertIn('save_sync_move(save, from, to, title, how, 0, &out, out.count)', flow)
        self.assertIn('@_silgen_name("save_sync_move")', self.mac)
        after = body(flow, 'private func afterMove(')
        self.assertIn('case 0, 1:', after); self.assertIn('setShared(toShared)', after)   # only a move that read back (or the same file) switches the folder
        self.assertIn('move(toShared: toShared, how: 1)', after); self.assertIn('move(toShared: toShared, how: 2)', after)   # replace or use the one there: the player's pick
        self.assertIn('returnPicks: false', after)   # Replace never on Return
        self.assertIn('Choose this game\'s own folder first, on the Cloud saves page.', body(flow, 'func savesTapped()'))
        self.assertIn('if saves.busy != nil', body(self.mac, 'private func start()'))   # no Play while the save moves


if __name__ == '__main__':
    unittest.main()
