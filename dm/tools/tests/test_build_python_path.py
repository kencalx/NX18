"""build_ipa_from_nsp.py own_python_first: with a Mac app's bare PATH (/usr/bin:/bin, where python3 is macOS's 3.9), the steps the script starts find the script's own Python
first (Donkey Kong Bananza was packed without its pipeline archive when build_ipa.sh's pso_offline.py ran under 3.9)"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/build_ipa_from_nsp.py'


class OwnPythonFirst(unittest.TestCase):
    def test_children_get_this_python(self):
        code = ('import importlib.util, os, shutil, subprocess, sys\n'
                f'spec = importlib.util.spec_from_file_location("b", {str(SCRIPT)!r}); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
                'm.own_python_first()\n'
                'print(subprocess.run(["sh", "-c", "python3 -c \\"import sys; print(sys.version_info[:2])\\""], capture_output=True, text=True).stdout.strip())\n'
                'print(sys.version_info[:2])\n')
        r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=120,
                           env={**os.environ, 'PATH': '/usr/bin:/bin'}, cwd=SCRIPT.parent)
        lines = r.stdout.strip().splitlines()
        self.assertEqual(len(lines) >= 2 and lines[-2], lines[-1] if len(lines) >= 2 else None, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
