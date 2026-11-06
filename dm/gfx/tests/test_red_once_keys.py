"""RED_ONCE keys (nvn_mtl.m's one-time red lines, used across dm/gfx/nvn): a key shared by two lines hides whichever fires second.

The fork's depth-bounds 'min above max' line (12c76dde) took key 154, which upstream's DrawMeshTasksIndirect line in nvn_geometry.inc
already used, and nothing caught it. The keys shared below were shared upstream already at b4318c7a (the same message twice, or upstream's
own choice); any other shared key fails, so a merge or a new red line that reuses a key is caught off the Mac."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
NVN = REPO / 'dm' / 'gfx' / 'nvn'
UPSTREAM_SHARED = {2, 22, 31, 32, 40, 41, 45, 88, 100, 104, 118, 121}


def uses():
    out = {}
    for f in sorted(NVN.iterdir()):
        if f.suffix not in ('.m', '.inc', '.h', '.c'): continue
        for n, line in enumerate(f.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
            for m in re.finditer(r'\bRED_ONCE\((\d+)\s*,', line):
                out.setdefault(int(m.group(1)), []).append(f'{f.name}:{n}')
    return out


class Keys(unittest.TestCase):
    def test_no_new_shared_key(self):
        shared = {k: v for k, v in uses().items() if len(v) > 1 and k not in UPSTREAM_SHARED}
        self.assertEqual(shared, {}, 'RED_ONCE keys used by more than one line: give the newer line the next free key')

    def test_table_is_one_past_the_highest_key(self):   # the macro's _Static_assert refuses a key past the table; this keeps it from growing unused
        size = int(re.search(r'static int g_red_once\[(\d+)\];', (NVN / 'nvn_mtl.m').read_text(encoding='utf-8')).group(1))
        self.assertEqual(size, max(uses()) + 1)


if __name__ == '__main__':
    unittest.main()
