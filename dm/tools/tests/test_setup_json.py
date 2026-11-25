"""nx18-setup.sh --json (the setup an app drives, NX 18 Beam; docs/frontends.md "Setting up a Mac"): read only (--check) on an empty folder, every stdout
line is one JSON event, the clone is offered as a fix, nothing is created; and the plain output is unchanged"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/release/nx18-setup.sh'


class SetupJson(unittest.TestCase):
    def test_check_json_on_an_empty_folder(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t) / 'NX18'
            r = subprocess.run(['bash', str(SCRIPT), '--check', '--json', '--dir', str(d), '--ref', 'main'], capture_output=True, text=True, timeout=300)
            events = [json.loads(line) for line in r.stdout.splitlines()]   # every line is JSON
            self.assertEqual(events[0]['ev'], 'start')
            self.assertEqual(events[-1]['ev'], 'done')
            self.assertFalse(events[-1]['ready'])
            self.assertIn('clone', [e['id'] for e in events if e['ev'] == 'fixable'])
            self.assertTrue(all(e['state'] in ('ok', 'warn', 'missing') for e in events if e['ev'] == 'item'))
            self.assertFalse(d.exists(), '--check creates nothing')
            self.assertEqual(r.returncode, 1)

    def test_json_never_asks(self):   # --json alone answers no: nothing installed, and it does not wait for a terminal
        with tempfile.TemporaryDirectory() as t:
            r = subprocess.run(['bash', str(SCRIPT), '--json', '--dir', str(Path(t) / 'NX18')], capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
            asks = [json.loads(line) for line in r.stdout.splitlines() if '"ask"' in line]
            self.assertTrue(asks and all(a['answer'] == 'no' for a in asks))
            self.assertFalse((Path(t) / 'NX18').exists())

    def test_only_answers_no_to_the_rest(self):
        with tempfile.TemporaryDirectory() as t:
            r = subprocess.run(['bash', str(SCRIPT), '--json', '--only', 'venv', '--dir', str(Path(t) / 'NX18')], capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
            clone = [json.loads(line) for line in r.stdout.splitlines() if '"id":"clone"' in line]
            self.assertTrue(clone and clone[0]['answer'] == 'no', 'clone is not in --only')

    def test_plain_output_unchanged(self):
        with tempfile.TemporaryDirectory() as t:
            r = subprocess.run(['bash', str(SCRIPT), '--check', '--dir', str(Path(t) / 'NX18')], capture_output=True, text=True, timeout=300)
            self.assertTrue(r.stdout.startswith('NX 18 setup'))
            self.assertNotIn('"ev"', r.stdout)


if __name__ == '__main__':
    unittest.main()
