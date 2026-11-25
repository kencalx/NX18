"""The replay borrows objects other tables hold, without a reference of its own (docs/reference/frame-rate.md, "Reference counting on the replay for objects other tables
already hold"): a texture ID's views (treg_t view / alt / im, through tex_by_id_ptr, tex_fast and tex_fast_rid), the view cache (vc_set view[]), the sampler views (g_sview,
g_sview_w), the programs of the serial table (prog_get_ptr) and g_prog_noserial, the pipelines of g_pso and g_pso_hy (pso_get_ptr), and the arena blocks of g_sub_arenas
(arena_take_u). That is safe only while every holder lets go through the deferred path (defer_obj_unref / defer_obj_release: kept until fence g_fence + 1, the submission being
encoded, has completed), the pipeline caches never let an entry go, and an arena block leaves g_sub_arenas only at the submission's commit. A change that releases one of them at
once would hand the submission being encoded a freed object; this scan fails at that line.

Rules over dm/gfx/nvn/*.m and *.inc (comment-only lines skipped):
1. every CFRelease of a holder field is preceded on its line by defer_obj_unref(;
2. every deletion from g_by_serial has defer_obj_ on its line, or a "borrow-safe:" note naming who keeps the object;
3. g_by_serial, g_pso and g_pso_hy are never cleared and g_pso / g_pso_hy never lose an entry (NX 18 has no session reset that could);
4. g_sub_arenas is emptied only in arena_commit;
5. g_prog_noserial is replaced only after defer_obj_unref of the old one, on the same line.
The rules' own fixtures check that each reports a bad line and passes a good one.
Ported from S2Arm 21f506c2 (Apache-2.0), adapted to NX 18's holders."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
NVN = REPO / 'dm/gfx/nvn'

HOLD = re.compile(r'CFRelease\(\s*(?:\(__bridge [^)]*\)\s*)?(?:(?:r|rp|s)->(?:view|alt|im)|g_sview(?:_w)?)(?:\[[^\]]*\])?\s*\)')
CLEAR = re.compile(r'nvn_hm_clear\(\s*&g_(?:by_serial|pso|pso_hy)\b|(?:nvn_hm_del|hm_del_id)\(\s*&g_pso(?:_hy)?\b')


def bad_release(line):   # 1
    m = HOLD.search(line)
    return bool(m) and 'defer_obj_unref(' not in line[:m.start()]


def bad_serial_del(line):   # 2
    return bool(re.search(r'(?:hm_del_id|nvn_hm_del)\(\s*&g_by_serial\b', line)) and 'defer_obj_' not in line and 'borrow-safe:' not in line


def bad_clear(line):   # 3
    return bool(CLEAR.search(line))


def bad_noserial(line):   # 5
    m = re.search(r'\bg_prog_noserial\s*=(?!=)', line)
    return bool(m) and 'defer_obj_unref(g_prog_noserial)' not in line[:m.start()]


def sources():
    for p in sorted(list(NVN.glob('*.m')) + list(NVN.glob('*.inc'))):
        for i, line in enumerate(p.read_text(encoding='utf-8', errors='replace').split('\n'), 1):
            if line.lstrip().startswith('//'):
                continue
            yield p.relative_to(REPO), i, line


class BorrowRelease(unittest.TestCase):
    def test_rules_report_bad_lines(self):
        for b in ['    if (r->view) { CFRelease(r->view); r->view = NULL; }', 'CFRelease(s->view[i]); defer_obj_unref((__bridge id)s->view[i]);',
                  'if (x) CFRelease((__bridge CFTypeRef)rp->view);', 'CFRelease(g_sview[id_]);']:
            self.assertTrue(bad_release(b), b)
        for g in ['    if (r->view) { defer_obj_unref((__bridge id)r->view); CFRelease(r->view); r->view = NULL; }', 'CFRelease(old);',
                  'if (g_sview[i]) { defer_obj_unref((__bridge id)g_sview[i]); CFRelease(g_sview[i]); }']:
            self.assertFalse(bad_release(g), g)
        self.assertTrue(bad_serial_del('hm_del_id(&g_by_serial, &k);'))
        self.assertFalse(bad_serial_del('defer_obj_unref(old); hm_del_id(&g_by_serial, &k);'))
        self.assertFalse(bad_serial_del('hm_del_id(&g_by_serial, &k);   // borrow-safe: the ghost ring keeps it'))
        for b in ['nvn_hm_clear(&g_pso, hm_rel);', 'hm_del_id(&g_pso, &k);', 'nvn_hm_clear(&g_by_serial, NULL);', 'nvn_hm_del(&g_pso_hy, k);']:
            self.assertTrue(bad_clear(b), b)
        self.assertFalse(bad_clear('nvn_hm_clear(&g_pso_fail, NULL);'))
        self.assertTrue(bad_noserial('else g_prog_noserial = o;'))
        self.assertFalse(bad_noserial('else { if (g_prog_noserial) defer_obj_unref(g_prog_noserial); g_prog_noserial = o; }'))
        self.assertFalse(bad_noserial('if (g_prog_noserial == o) x();'))

    def test_holders_release_through_deferred_path(self):
        hits = {1: [], 2: [], 3: [], 5: []}; n1 = n2 = 0
        for p, i, line in sources():
            n1 += bool(HOLD.search(line)); n2 += bool(re.search(r'(?:hm_del_id|nvn_hm_del)\(\s*&g_by_serial\b', line))
            for k, f in ((1, bad_release), (2, bad_serial_del), (3, bad_clear), (5, bad_noserial)):
                if f(line):
                    hits[k].append(f'{p}:{i}')
        self.assertGreater(n1, 0, 'no CFRelease of a holder field found: the pattern no longer matches the code')
        self.assertGreater(n2, 0, 'no deletion from g_by_serial found: the pattern no longer matches the code')
        self.assertEqual(hits[1], [], 'a borrowed holder field is CFRelease\'d without defer_obj_unref before it on its line')
        self.assertEqual(hits[2], [], 'an entry leaves g_by_serial without defer_obj_ or a "borrow-safe:" note')
        self.assertEqual(hits[3], [], 'g_by_serial / g_pso / g_pso_hy cleared, or a pipeline cache entry deleted, while the replay borrows from them')
        self.assertEqual(hits[5], [], 'g_prog_noserial replaced without defer_obj_unref of the old program first')

    def test_sub_arenas_emptied_only_at_commit(self):
        text = (NVN / 'nvn_mtl.m').read_text(encoding='utf-8', errors='replace').split('\n')
        fn, where = None, []
        for i, line in enumerate(text, 1):
            m = re.match(r'^(?:static\s+)?[\w<>* ]+?\b(\w+)\([^;]*\)\s*\{', line)
            if m:
                fn = m.group(1)
            if re.search(r'\[g_sub_arenas\s+remove', line) or re.search(r'\bg_sub_arenas\s*=(?!=)', line) and 'NSMutableArray array' not in line:
                where.append((fn, i))
        self.assertTrue(where, 'no removal from g_sub_arenas found: the pattern no longer matches the code')
        self.assertEqual([w for w in where if w[0] != 'arena_commit'], [], 'g_sub_arenas loses a block outside arena_commit (an arena block the replay borrows)')


if __name__ == '__main__':
    unittest.main()
