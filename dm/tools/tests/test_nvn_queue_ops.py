"""The NVN queue scheduler (dm/gfx/nvn/nvn_queue.inc nq_flatten) copies every record a game submits and walks its fields with cap_rec_fields (nvn_capture.c), which knows only
the capture format's ops (those before OP_COUNT_) and answers 0 for any other: nq_flatten then stops the host ("queue snapshot: unknown command"). The fork's opt-in records
numbered past OP_COUNT_ (nvn_obj.h, OP_DEPTH_BOUNDS for DM_DEPTH_BOUNDS) must each be exempted there, or DM_DEPTH_BOUNDS=1 stops every game that calls
nvnCommandBufferSetDepthBounds at its first submit on an Apple10-or-later GPU. The Mac test t_depth_bounds.m replays records directly (mtl_exec), not through the queue, so it
cannot see this."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def past_count_ops():
    """The names nvn_obj.h numbers at or past OP_COUNT_ (enum { OP_X = OP_COUNT_, OP_Y, ... } or OP_X = OP_COUNT_ + k)"""
    src = re.sub(r'//[^\n]*', '', read('dm/gfx/nvn/nvn_obj.h'))
    names = []
    for body in re.findall(r'enum\s*\{([^}]*)\}', src):
        items = [i.strip() for i in body.split(',') if i.strip()]
        if not items or not re.search(r'=\s*OP_COUNT_\b', items[0]): continue
        names += [m.group(1) for m in (re.match(r'(\w+)', i) for i in items) if m]
    return names


def nq_flatten(src):
    i = src.index('static void nq_flatten('); j = src.index('\n}\n', i)
    return src[i:j]


class QueueOps(unittest.TestCase):
    def test_ops_past_count_exist(self):
        self.assertIn('OP_DEPTH_BOUNDS', past_count_ops())

    def test_nq_flatten_exempts_each(self):
        body = nq_flatten(read('dm/gfx/nvn/nvn_queue.inc'))
        call = [ln for ln in body.splitlines() if 'cap_rec_fields(' in ln]
        self.assertEqual(len(call), 1, 'nq_flatten walks the fields in one place')
        for op in past_count_ops():
            self.assertRegex(call[0], r'h\.op\s*!=\s*' + op + r'\s*&&\s*!cap_rec_fields\(',
                             op + ' is past OP_COUNT_: cap_rec_fields refuses it, so nq_flatten must not ask it (or must walk the op itself)')

    def test_cap_rec_fields_keeps_to_the_format(self):
        src = read('dm/gfx/nvn/nvn_capture.c')
        i = src.index('int cap_rec_fields('); body = src[i:src.index('\n}\n', i)]
        for op in past_count_ops():
            self.assertNotIn(op, body, op + ' is outside the capture format: nvn_capture.inc refuses it, and cap_rec_fields is the format\'s walk')

    def test_replay_knows_each(self):
        src = read('dm/gfx/nvn/nvn_mtl.m')
        for op in past_count_ops():
            self.assertIn('case ' + op + ':', src, 'the replay (mtl_exec) has a case for ' + op)


if __name__ == '__main__':
    unittest.main()
