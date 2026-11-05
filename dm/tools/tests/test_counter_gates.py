"""The counter-timer reads the rewriter sends to the host gate (patch_nso.py) and the gate kinds the host knows (hle.c gate_register): every kind one emits the other takes,
and mrs cntpct_el0 / cntvct_el0 / cntfrq_el0 are each classified, cntfrq_el0 returning the guest's frequency (19.2 MHz, 31.25 MHz for the Switch 2), not Apple's 24 MHz"""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
PATCH = (REPO / 'dm/tools/patch_nso.py').read_text()
HLE = (REPO / 'dm/host/hle.c').read_text()


class CounterGates(unittest.TestCase):
    def test_every_gate_kind_the_rewriter_emits_is_known_to_the_host(self):
        emitted = set(re.findall(r"site_gate\(ins, '(\w+)'", PATCH))
        for group in re.findall(r"elif k in \(([^)]*)\): st = site_gate\(ins, k", PATCH):
            emitted |= set(re.findall(r"'(\w+)'", group))
        known = set(re.findall(r'!strcmp\(kind, "(\w+)"\)', HLE))
        self.assertTrue({'svc', 'cntpct', 'cntvct', 'cntfrq'} <= emitted, emitted)
        self.assertEqual(emitted - known, set(), 'a gate kind the host would refuse at load ("unknown gate kind")')

    def test_counter_registers_are_classified(self):
        for enc, kind in (('0xD53BE020', 'cntpct'), ('0xD53BE040', 'cntvct'), ('0xD53BE000', 'cntfrq')):   # mrs xN, cntpct_el0 / cntvct_el0 / cntfrq_el0
            self.assertRegex(PATCH, rf"w & 0xFFFFFFE0 == {enc}: kinds\[o\] = \('{kind}', w & 31\)")

    def test_the_frequency_is_the_guests(self):
        case = HLE[HLE.index('case G_CNTFRQ:'):]
        case = case[:case.index('}')]
        self.assertIn('31250000', case); self.assertIn('19200000', case); self.assertIn('dm_sdk_ounce()', case)
        self.assertIn('guest_ns() / 32 : guest_ns() * 12 / 625', (REPO / 'dm/host/hle_os.c').read_text(), 'the ticks the frequency describes: 31.25 MHz and 19.2 MHz')


if __name__ == '__main__':
    unittest.main()
