"""CI builds with the toolchain the project supports: the Xcode that .github/workflows/tests.yml names in DEVELOPER_DIR is the one README tells players to install and the NSP
script names beside dmsh_chain.lock, and every macOS job runs on the GitHub image of that Xcode (xcode-<major>). The build check compares the image's Metal compiler with the
lock itself (own_compilers.py --check-metal); this test keeps the names in step (own_compilers.py's stop message too), so raising the toolchain is one change in all of them. No Xcode or network needed."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


class Toolchain(unittest.TestCase):
    def setUp(self):
        self.workflow = (REPO / '.github/workflows/tests.yml').read_text()
        m = re.search(r'DEVELOPER_DIR: /Applications/Xcode_(\d+\.\d+)\.app/Contents/Developer', self.workflow)
        if m is None: self.fail('tests.yml: DEVELOPER_DIR names no /Applications/Xcode_<version>.app')
        self.xcode = m.group(1)

    def test_every_macos_job_runs_on_that_xcodes_image(self):
        runners = re.findall(r'runs-on: (\S+)', self.workflow)
        self.assertTrue(runners, 'tests.yml: no runs-on')
        image = f'xcode-{self.xcode.split(".")[0]}'
        self.assertEqual(sorted({r for r in runners if r.startswith(('macos-', 'xcode-'))}), [image], f'tests.yml: every macOS job runs on {image} (Xcode {self.xcode})')

    def test_readme_names_the_same_xcode(self):
        readme = (REPO / 'README.md').read_text()
        named = re.findall(r'\[Xcode\]\([^)]*\) (\d+\.\d+)', readme)
        self.assertEqual(set(named), {self.xcode}, f'README.md: the Xcode to install is not CI\'s {self.xcode}')
        self.assertEqual(set(re.findall(r'Xcode[ -](\d+\.\d+)', readme)), {self.xcode}, f'README.md: an Xcode it names (the side-by-side one too) is not CI\'s {self.xcode}')

    def test_building_page_names_the_same_xcode(self):   # docs/building.md has the command-line steps the README's Requirements link to
        page = (REPO / 'docs/building.md').read_text()
        named = re.findall(r'\[Xcode\]\([^)]*\) (\d+\.\d+)', page)
        self.assertEqual(set(named), {self.xcode}, f'docs/building.md: the Xcode to install is not CI\'s {self.xcode}')
        self.assertEqual(set(re.findall(r'Xcode[ -](\d+\.\d+)', page)), {self.xcode}, f'docs/building.md: an Xcode it names (the side-by-side one too) is not CI\'s {self.xcode}')

    def test_development_page_and_lint_workflow_name_the_same_xcode(self):   # docs/development.md's CI section and lint-c.yml's DEVELOPER_DIR (its clang-tidy reads the SDK's headers)
        named = re.findall(r"Xcode (\d+\.\d+) on GitHub's", (REPO / 'docs/development.md').read_text())
        self.assertTrue(named, 'docs/development.md names no Xcode for CI')
        self.assertEqual(set(named), {self.xcode}, f'docs/development.md: the Xcode CI runs is not tests.yml\'s {self.xcode}')
        lint = re.findall(r'DEVELOPER_DIR: /Applications/Xcode_(\d+\.\d+)\.app/Contents/Developer', (REPO / '.github/workflows/lint-c.yml').read_text())
        self.assertEqual(set(lint), {self.xcode}, f'lint-c.yml: DEVELOPER_DIR is not tests.yml\'s {self.xcode}')

    def test_metal_stop_names_the_same_xcode(self):   # own_compilers.py's stop message: the Xcode to install and select (GitHub issue #717)
        named = re.findall(r"XCODE_VERSION = '(\d+\.\d+)'", (REPO / 'dm/gfx/tools/own_compilers.py').read_text())
        self.assertEqual(named, [self.xcode], f'dm/gfx/tools/own_compilers.py: XCODE_VERSION is not CI\'s {self.xcode}')

    def test_nsp_script_names_the_same_xcode(self):
        named = re.findall(r'Xcode (\d+\.\d+)', (REPO / 'scripts/build_ipa_from_nsp.py').read_text())
        self.assertTrue(named, 'scripts/build_ipa_from_nsp.py names no Xcode version')
        self.assertEqual(set(named), {self.xcode}, f'scripts/build_ipa_from_nsp.py: the tested Xcode is not CI\'s {self.xcode}')

    def test_jobs_that_compile_the_hosts_shaders_install_the_metal_toolchain(self):
        """host_msl.py stops without a Metal compiler (the host compiles no shader source at run time), and the xcode-27 image has none until the job downloads it. So every
        job that builds the host's shaders header (a gfx test, the host, the iOS sources, the compile database) installs the toolchain in an earlier step"""
        builds = re.compile(r'make\b[^\n]*-C dm/gfx/tests|cd dm/gfx/tests|make\b[^\n]*-C dm/host(?:\s|$)|lint_c\.py compdb|build_smoke\.py|gen_build\.py|compile_check\.py')
        missing, seen = [], 0
        for wf in sorted((REPO / '.github/workflows').glob('*.yml')):
            jobs = wf.read_text().split('\njobs:\n', 1)
            if len(jobs) < 2: continue
            for m in re.finditer(r'^  ([\w-]+):\n((?:(?:    .*|[ \t]*)\n)*)', jobs[1], re.M):
                name, body = m.groups()
                b = builds.search(body)
                if not b: continue
                seen += 1
                t = body.find('downloadComponent MetalToolchain')
                if t < 0 or t > b.start(): missing.append(f'{wf.name}: {name} ({b.group(0)})')
        self.assertGreaterEqual(seen, 4, 'the job parser found too few jobs that build the host\'s shaders')
        self.assertEqual(missing, [], 'jobs that compile the host\'s shaders before installing the Metal toolchain (xcodebuild -downloadComponent MetalToolchain)')


if __name__ == '__main__':
    unittest.main()
