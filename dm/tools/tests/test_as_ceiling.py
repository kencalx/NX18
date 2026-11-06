"""The Mac-only games' guest blocks the iOS boot line names (dm/host/as_ceiling.h k_as_blocks): each entry is a profile whose mem_reserve is the size the table gives, under
the name the games table gives it, and the memory reference names each size, so the boot line's "fits" answers the question the reference asks."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
HEADER = REPO / 'dm' / 'host' / 'as_ceiling.h'
ENTRY = re.compile(r'\{"([^"]+)", (0x[0-9a-f]+)ull\},\s*// ([0-9A-F]{16})\b')   # {"name", bytes}, then the title ID in the row's comment (no title IDs in host code)


def profile_key(title_id, key):
    for line in (REPO / 'dm' / 'games' / title_id / 'game.tsv').read_text(encoding='utf-8').splitlines():
        cols = line.split('\t')
        if len(cols) >= 2 and cols[0] == key:
            return cols[1]
    return ''


class Blocks(unittest.TestCase):
    def setUp(self):
        self.entries = [(tid, name, size) for name, size, tid in ENTRY.findall(HEADER.read_text(encoding='utf-8'))]

    def test_table_is_read(self):
        self.assertGreaterEqual(len(self.entries), 4)

    def test_each_block_is_its_profiles_reservation(self):
        for title_id, _name, size in self.entries:
            with self.subTest(title_id=title_id):
                self.assertTrue((REPO / 'dm' / 'games' / title_id / 'game.tsv').exists(), f'{title_id}: no profile')
                value = profile_key(title_id, 'mem_reserve')
                self.assertTrue(value, f'{title_id}: no mem_reserve in its game.tsv')
                self.assertEqual(int(value, 0), int(size, 16))

    def test_each_name_is_the_games_tables(self):
        table = (REPO / 'dm' / 'games' / 'README.md').read_text(encoding='utf-8')
        for title_id, name, _size in self.entries:
            with self.subTest(title_id=title_id):
                row = next((line for line in table.splitlines() if title_id in line), '')
                self.assertIn(name, row, f'{title_id}: "{name}" is not its row in the games table')

    def test_memory_reference_names_each_size(self):
        ref = (REPO / 'docs' / 'reference' / 'memory.md').read_text(encoding='utf-8')
        for _title_id, _name, size in self.entries:
            gb = int(size, 16) / (1 << 30)
            with self.subTest(size=gb):
                self.assertIn(f'{gb:g} GB', ref)


if __name__ == '__main__':
    unittest.main()
