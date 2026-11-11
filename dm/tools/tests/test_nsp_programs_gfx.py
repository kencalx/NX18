"""NSP script, a game of several programs (the profile's key programs, Super Mario 3D All-Stars): every other program's graphics are detected before the first program's rewrite and shader
steps (check_programs_gfx), so a Vulkan or OpenGL program stops the build at its start, not after the launcher's whole build. No game files, keys or Xcode needed."""
import importlib.util
import inspect
from pathlib import Path
import types
from typing import Any
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
assert spec and spec.loader   # a path that exists: narrows the Optional for the type checker
nsp: Any = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)   # Any: the script's globals, which the tests set as main does, are not known to the checker


class Profile:
    def __init__(self, programs=''): self.programs = programs
    def get(self, k, d=None): return self.programs if k == 'programs' else d
    def pairs(self, k): return [tuple(x.split('=', 1)) for x in self.programs.split()] if k == 'programs' else []


class ProgramsGfx(unittest.TestCase):
    def setUp(self):
        self.prog = types.SimpleNamespace(k=3, n=9)
        for cm in (mock.patch.object(nsp, 'PROG', self.prog), mock.patch.object(nsp, 'say', lambda m: None)):
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)
        self.calls = []

    def fake_main(self, gfx):
        def main(sub):
            self.calls.append((sub.program, sub.in_programs, getattr(sub, 'gfx_probe', False)))
            nsp.PROGRAM_INDEX = sub.program; self.prog.k, self.prog.n = 1, 1   # as main does: its own program index and progress plan
            if gfx.get(sub.program, 'nvn') != 'nvn': raise nsp.BuildError(nsp.unsupported_gfx(gfx[sub.program], f'program {sub.program}'))
            return 'nvn'
        return main

    def test_every_program_is_probed_and_a_vulkan_one_stops(self):
        args = types.SimpleNamespace(program=None, out=None)
        with mock.patch.object(nsp, 'main', self.fake_main({1: 'vulkan', 2: 'vulkan'})):
            with self.assertRaisesRegex(nsp.BuildError, r'program 1 renders with Vulkan; NX 18 release 1 supports NVN games only'):
                nsp.check_programs_gfx(args, Profile('1=010049900F546001 2=010049900F546002'))
        self.assertEqual(self.calls, [(1, {}, True)])   # stops at the first: before program 0's rewrite and shaders, which come after this call in main
        self.assertEqual((nsp.PROGRAM_INDEX, self.prog.k, self.prog.n), (0, 3, 9))   # the first program's index and progress plan, as they were
        self.assertFalse(hasattr(args, 'gfx_probe'))   # the caller's arguments are not changed

    def test_nvn_programs_pass(self):
        with mock.patch.object(nsp, 'main', self.fake_main({})):
            nsp.check_programs_gfx(types.SimpleNamespace(program=None), Profile('1=A 2=B'))
        self.assertEqual(self.calls, [(1, {}, True), (2, {}, True)])
        self.assertEqual((nsp.PROGRAM_INDEX, self.prog.k, self.prog.n), (0, 3, 9))

    def test_not_for_one_program_or_a_program_of_the_package(self):
        with mock.patch.object(nsp, 'main', self.fake_main({1: 'vulkan'})):
            nsp.check_programs_gfx(types.SimpleNamespace(program=None), Profile(''))
            nsp.check_programs_gfx(types.SimpleNamespace(program=1, in_programs={}), Profile('1=A'))
        self.assertEqual(self.calls, [])

    def test_main_checks_before_the_metal_check_and_the_shader_steps(self):   # the order in main: detection, the probe's return, the other programs, then check_metal
        src = inspect.getsource(nsp.main)
        at = [src.index(x) for x in ("if gfx != 'nvn': raise BuildError", 'if probe: return gfx', 'check_programs_gfx(args, g)', 'check_metal(py, repo, env)', 'other_programs(')]
        self.assertEqual(at, sorted(at))
        self.assertIn('if mods_root and not probe:', src)   # a probe leaves the mods to the program's build


if __name__ == '__main__':
    unittest.main()
