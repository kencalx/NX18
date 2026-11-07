"""Exercise the host/test Makefiles with a fake Metal compiler: deployment targets, toolchain recovery and incremental builds, without a GPU or game files."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
GAME = '010015100B514000'
# host_msl.py also compiles the start-up self-test's kernel with the game chain's compile (hmma_selftest.py), from these files
SELFTEST_FILES = ('dm/gfx/tools/hmma_selftest.py', 'dm/gfx/tools/dmsh_build.py', 'dm/gfx/tools/dmsh_pch.py', 'dm/ios/tools/ios_metal.py')
sys.path.insert(0, str(REPO / 'dm/gfx/tools')); import hmma_selftest


def script(name):
    spec = importlib.util.spec_from_file_location(name, REPO / 'scripts' / (name + '.py'))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class HostMSL(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ('dm/host/Makefile', 'dm/mac/min_os.mk', 'dm/gfx/tests/Makefile', 'dm/gfx/tools/host_msl.py', f'dm/games/{GAME}/game.tsv',
                     *SELFTEST_FILES):
            dst = self.root / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, dst)
        (self.root / 'dm/third_party/libvpx').mkdir(parents=True)
        self.source = self.root / 'dm/gfx/msl/clear.metal'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('kernel void clear() {}\n')
        tools = self.root / 'bin'
        tools.mkdir()
        compiler = tools / 'xcrun'
        compiler.write_text(f'#!{sys.executable}\n' + textwrap.dedent('''\
            import json, os, pathlib, sys
            args = sys.argv[1:]
            if '--show-sdk-path' in args:
                print(os.environ['TEST_METAL_SDK'])
            elif '--version' in args:
                version = os.environ['TEST_METAL_VERSION']
                if not version: sys.exit(1)
                print(version)
            else:
                if os.environ.get('TEST_METAL_REFUSE') and os.environ['TEST_METAL_REFUSE'] in args:
                    with open(os.environ['TEST_METAL_LOG'], 'a') as f: f.write(json.dumps(['<refused>'] + args) + '\\n')
                    sys.exit(1)
                with open(os.environ['TEST_METAL_LOG'], 'a') as f:
                    f.write(json.dumps(args + (['<stdin>', sys.stdin.read()] if '-' in args else [])) + '\\n')
                pathlib.Path(args[args.index('-o') + 1]).write_bytes(b'compiled library')
            '''))
        compiler.chmod(0o755)
        self.log = self.root / 'compiles.jsonl'
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                        TEST_METAL_VERSION='Metal test compiler 1', TEST_METAL_SDK='/sdk/1', TEST_METAL_LOG=str(self.log))
        self.header = self.root / 'dm/host/gen/msl-macosx/host_msl_gen.h'

    def make(self, *args, gfx=False):
        target = '../../host/gen/msl-macosx/host_msl_gen.h' if gfx else 'host_msl'
        p = subprocess.run(['make', '-s', '-C', 'dm/gfx/tests' if gfx else 'dm/host', f'GAME={GAME}', target, *args],
                           cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def compiles(self):   # the host libraries' compiles (dm/gfx/msl/*.metal)
        return [c for c in self.calls() if c[-1].endswith('.metal') and '/msl/' in c[-1]]

    def chain_compiles(self):   # the self-test kernels': their sources on standard input, as the chain compiles a game shader
        return [c for c in self.calls() if '<stdin>' in c]

    def refused(self):   # the compiles TEST_METAL_REFUSE made fail
        return [c for c in self.calls() if c[0] == '<refused>']

    def host_dirs(self, dirs):
        for d in dirs: (self.root / d).mkdir(parents=True, exist_ok=True)
        (self.root / 'dm/games/game.py').touch()

    def test_mac_and_ios_use_their_deployment_targets(self):
        self.make()
        minimum = (self.root / 'dm/mac/min_os.mk').read_text().split('MACOS_MIN := ')[1].split()[0]
        self.assertIn(f'-mmacosx-version-min={minimum}', self.compiles()[-1])
        self.make('MSL_SDK=iphoneos')
        self.assertIn('-mios-version-min=27.0', self.compiles()[-1])
        self.assertIn('iphoneos', self.compiles()[-1])

    def test_self_test_kernel_is_compiled_as_each_platforms_game_shaders(self):
        import ios_metal
        libs = tuple(hmma_selftest.LIBRARIES)
        self.assertIn(f'CHAIN_LIBS = {libs!r}', (REPO / 'dm/gfx/tools/host_msl.py').read_text())   # every kernel of the self-test has its entry in the header
        # the game chain's compile commands: dmsh_build.py's mac_compile (MAC_METAL with METAL_DEPTH), ios_metal.compile (METAL with DEPTH): the bracket depth, which neither record names
        for args, metal, label in ((), hmma_selftest.CHAIN['MAC_METAL'] + hmma_selftest.CHAIN['METAL_DEPTH'], 'macosx'), (('MSL_SDK=iphoneos',), ios_metal.METAL + ios_metal.DEPTH, 'iphoneos'):
            self.assertIn('-fbracket-depth=1024', metal)
            self.make(*args)
            chains = self.chain_compiles()[-len(libs):]   # one compile a kernel, in the header's order
            header = (self.root / f'dm/host/gen/msl-{label}/host_msl_gen.h').read_text()
            for chain, name in zip(chains, libs):
                self.assertEqual(chain[:chain.index('-x')], metal[1:])   # the chain's own command, without the precompiled header
                self.assertEqual(chain[-1], hmma_selftest.msl(name))   # dmsh_build.py's body, as every game gets it
                self.assertIn(f'{{"{name}", "{" ".join(metal)} -x metal -; ', header)
            for array in ('k_host_msl_chain_hmma', 'k_host_msl_chain_hmma_flags'): self.assertRegex(header, array + r', 16\}')   # the fake compiler's 'compiled library'
        self.assertIn('-std=metal4.1', chain); self.assertIn('-fmetal-math-mode=relaxed', chain); self.assertIn('-mios-version-min=27.0', chain)
        self.assertEqual(len(self.compiles()), 2)   # the host's libraries keep their own flags

    def test_self_test_kernel_falls_back_or_is_left_out_without_stopping_the_build(self):
        import ios_metal
        self.env['TEST_METAL_REFUSE'] = ios_metal.STD   # Metal 4.1 refuses it: ios_metal.compile takes its fallback language, as for a game shader
        self.make('MSL_SDK=iphoneos')
        self.assertIn(ios_metal.FALLBACK_STD, self.chain_compiles()[-1])
        fallback = (self.root / 'dm/host/gen/msl-iphoneos/host_msl_gen.h').read_text()
        for name in hmma_selftest.LIBRARIES: self.assertIn(f'{{"{name}", "{" ".join(ios_metal.METAL_FALLBACK + ios_metal.DEPTH)} -x metal -; ', fallback)   # with the bracket depth too
        self.env['TEST_METAL_REFUSE'] = '-fpreserve-invariance'   # no language takes it: the host is built without it, and says why at run time
        self.env['TEST_METAL_VERSION'] = 'Metal test compiler 2'
        self.make('MSL_SDK=iphoneos')
        ios = self.root / 'dm/host/gen/msl-iphoneos/host_msl_gen.h'
        failed = ios.read_text()
        for name, array in (('hmma_selftest', 'k_host_msl_chain_hmma'), ('hmma_selftest_flags', 'k_host_msl_chain_hmma_flags')):
            self.assertRegex(failed, f'"{name}", "it did not compile when the host was built \\(.*<build folder>.*\\)", {array}, 0}}')
        self.assertNotIn(tempfile.gettempdir() + os.sep + 'tmp', failed.split('k_host_msl_chain[]')[1])   # no temporary folder in the record: the same failure, the same header
        self.assertIn('(the self-test kernel did not compile: tried again at the next build)', failed.split('\n')[1])
        n = len(self.refused())
        self.make('MSL_SDK=iphoneos')   # the same inputs, the same failure: tried again, the header unchanged (the host is not rebuilt for it)
        self.assertGreater(len(self.refused()), n); self.assertEqual(ios.read_text(), failed)
        del self.env['TEST_METAL_REFUSE']   # the cause has passed (the compiler service, a full disk): the next build has the kernel, with nothing else changed
        self.make('MSL_SDK=iphoneos')
        self.assertRegex(ios.read_text(), r'k_host_msl_chain_hmma, 16\}'); self.assertRegex(ios.read_text(), r'k_host_msl_chain_hmma_flags, 16\}')
        self.env['TEST_METAL_VERSION'] = ''
        self.make()
        self.assertIn('"hmma_selftest", "no Metal compiler for macosx when the host was built", k_host_msl_chain_hmma, 0}', self.header.read_text())
        self.assertIn('"hmma_selftest_flags", "no Metal compiler for macosx when the host was built", k_host_msl_chain_hmma_flags, 0}', self.header.read_text())

    def test_compiler_installation_recovers_without_cleaning(self):
        self.env['TEST_METAL_VERSION'] = ''
        self.make()
        self.assertIn('#define HOST_MSL_COMPILER "none"', self.header.read_text())
        self.assertEqual(self.compiles(), [])
        self.env['TEST_METAL_VERSION'] = 'Metal test compiler 1'
        self.make()
        self.assertEqual(len(self.compiles()), 1)
        self.assertNotIn('#define HOST_MSL_COMPILER "none"', self.header.read_text())

    def test_gfx_tests_also_recheck_a_source_only_header(self):
        self.env['TEST_METAL_VERSION'] = ''
        self.make(gfx=True)
        self.env['TEST_METAL_VERSION'] = 'Metal test compiler 1'
        self.make(gfx=True)
        self.assertEqual(len(self.compiles()), 1)

    def test_gfx_tests_regenerate_a_stale_profile_header(self):
        # a header left by a host built before game.py gained a key: the graphics tests' make remakes it through the host Makefile, and leaves an unchanged one as it is
        shutil.copyfile(REPO / 'dm/games/game.py', self.root / 'dm/games/game.py')
        profile = self.root / f'dm/host/gen/{GAME}/game_profile.h'; profile.parent.mkdir(parents=True); profile.write_text('#define DM_GAME_OLD 1\n')
        def make():
            p = subprocess.run(['make', '-s', '-C', 'dm/gfx/tests', f'GAME={GAME}', f'../../host/gen/{GAME}/game_profile.h'], cwd=self.root, env=self.env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        make()
        self.assertIn('#define DM_GAME_DRAW_BARRIERS_GAME ', profile.read_text())
        before = profile.stat().st_mtime_ns
        make()
        self.assertEqual(profile.stat().st_mtime_ns, before)

    def test_unchanged_inputs_preserve_header_and_skip_compilation(self):
        self.make()
        before = self.header.stat().st_mtime_ns
        self.make()
        self.make(gfx=True)
        self.assertEqual(len(self.compiles()), 1)
        self.assertEqual(self.header.stat().st_mtime_ns, before)

    def test_compiler_sdk_target_and_source_changes_recompile(self):
        self.make()
        self.env['TEST_METAL_VERSION'] = 'Metal test compiler 2'
        self.make()
        self.assertEqual(len(self.compiles()), 2)
        self.env['TEST_METAL_SDK'] = '/sdk/2'
        self.make()
        self.assertEqual(len(self.compiles()), 3)
        self.make('MACOS_MIN=26.7')
        self.assertEqual(len(self.compiles()), 4)
        self.assertIn('-mmacosx-version-min=26.7', self.compiles()[-1])
        before = self.source.stat()
        self.source.write_text('kernel void clear_changed() {}\n')
        os.utime(self.source, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.make('MACOS_MIN=26.7')
        self.assertEqual(len(self.compiles()), 5)

    def test_regress_cache_refreshes_shaders_before_reusing_a_host(self):
        regress = script('regress')
        self.host_dirs(regress.HOST_DIRS)
        tree = NS(path=self.root, id='candidate')
        game = NS(id=GAME, env=lambda tree: self.env, profile_dir=lambda tree: self.root / f'dm/games/{GAME}')
        real_run = subprocess.run
        builds = []

        def run(cmd, **kw):
            if cmd[0] == 'make' and 'host_msl' not in cmd:
                if 'dmhost' in cmd:
                    builds.append(cmd)
                    (self.root / 'dm/host/dmhost').write_bytes(b'host executable')
                return NS(returncode=0)
            return real_run(cmd, **kw)

        with patch.object(regress, 'game_root', return_value=self.root / 'regress'), patch.object(regress, 'say'), patch.object(regress.subprocess, 'run', side_effect=run):
            self.env['TEST_METAL_VERSION'] = ''
            _, source_key, _ = regress.host_for(tree, game, 1)
            self.env['TEST_METAL_VERSION'] = 'Metal test compiler 1'
            _, compiled_key, _ = regress.host_for(tree, game, 1)
            self.assertNotEqual(compiled_key, source_key)
            self.assertEqual(regress.host_for(tree, game, 1)[1], compiled_key)
            self.assertEqual(len(builds), 2)
            self.source.write_text('kernel void changed() {}\n')
            _, changed_key, _ = regress.host_for(tree, game, 1)
            self.assertNotEqual(changed_key, compiled_key)
            tool = self.root / 'dm/gfx/tools/host_msl.py'
            tool.write_text(tool.read_text() + '\n# changed generator\n')
            self.assertNotEqual(regress.host_for(tree, game, 1)[1], changed_key)
            self.assertEqual(len(builds), 4)

    def test_nsp_packer_generates_and_fingerprints_the_header(self):
        nsp = script('build_ipa_from_nsp')
        self.host_dirs(nsp.HOST_DIRS)
        real_run = subprocess.run
        out = self.root / 'packed/dmhost'
        logs = self.root / 'logs'
        logs.mkdir()
        builds = []

        def run(cmd, log, env=None, cwd=None):
            if cmd[0] == 'make':
                self.assertIn('host_msl', cmd)
                p = real_run(['make', '-s', f'GAME={GAME}', 'host_msl'], cwd=cwd, env=env, capture_output=True, text=True)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            else:
                self.assertTrue(self.header.is_file(), 'direct clang needs the header before its first compile')
                builds.append(cmd)
                out.write_bytes(b'host executable')

        def command(cmd, **kw):
            return NS(returncode=0, stdout='clang -o dmhost main.c\n' if cmd[0] == 'make' else 'test toolchain', stderr='')

        with patch.object(nsp, 'apple_silicon', return_value=True), patch.object(nsp, 'run', side_effect=run), patch.object(nsp.subprocess, 'run', side_effect=command):
            self.env['TEST_METAL_VERSION'] = ''
            nsp.build_mac_host(self.root, out, self.env, logs, NS(id=GAME))
            nsp.build_mac_host(self.root, out, self.env, logs, NS(id=GAME))
            self.assertEqual(len(builds), 1)
            self.env['TEST_METAL_VERSION'] = 'Metal test compiler 1'
            nsp.build_mac_host(self.root, out, self.env, logs, NS(id=GAME))
            self.assertEqual(len(builds), 2)
            self.source.write_text('kernel void changed() {}\n')
            nsp.build_mac_host(self.root, out, self.env, logs, NS(id=GAME))
            self.assertEqual(len(builds), 3)

    def test_decoder_identity_normalizes_only_chain_and_verifies_executable(self):
        nsp = script('build_ipa_from_nsp')
        self.host_dirs(nsp.HOST_DIRS)
        out = self.root / 'packed/dmhost'; logs = self.root / 'logs'; logs.mkdir()
        chain = self.root / nsp.CHAIN_H; chain.write_text('#define DMSH_CHAIN "aaaaaaaaaaaa"\n')
        decoder = self.root / 'dm/host/hle_oodle.c'; decoder.write_text('void decode(void) {}\n')
        profile = self.root / f'dm/host/gen/{GAME}/game_profile.h'; profile.parent.mkdir(parents=True); profile.write_text('#define HEAP 1\n')
        toolchain, builds = ['compiler 1'], []
        def run(cmd, log, env=None, cwd=None):
            if cmd[0] != 'make':
                builds.append(cmd)
                out.write_bytes(f'host {len(builds)}'.encode())
        def command(cmd, **kw):
            return NS(returncode=0, stdout='clang -o dmhost main.c\n' if cmd[0] == 'make' else toolchain[0], stderr='')
        with patch.object(nsp, 'apple_silicon', return_value=True), patch.object(nsp, 'run', side_effect=run), patch.object(nsp.subprocess, 'run', side_effect=command):
            def build(): return nsp.build_mac_host(self.root, out, self.env, logs, NS(id=GAME))
            build()
            record = out.with_name(out.name + '.decoder.json')
            self.assertTrue(record.is_file(), 'a managed host needs verified decoder provenance')
            first = nsp.decoder_host_key(out)
            self.assertIsNotNone(first)
            chain.write_text('#define DMSH_CHAIN "bbbbbbbbbbbb"\n'); build()
            self.assertEqual(nsp.decoder_host_key(out), first)
            self.assertEqual(len(builds), 2, 'the runtime host still rebuilds for a new chain')
            for change in (lambda: decoder.write_text('void decode(void) { fixed(); }\n'),
                           lambda: profile.write_text('#define HEAP 2\n'),
                           lambda: toolchain.__setitem__(0, 'compiler 2'),
                           lambda: chain.write_text(chain.read_text() + '#define OTHER_INPUT 1\n')):
                before = nsp.decoder_host_key(out)
                change(); build()
                self.assertNotEqual(nsp.decoder_host_key(out), before)
            before = nsp.decoder_host_key(out)
            out.write_bytes(b'replaced without rebuilding')
            self.assertIsNone(nsp.decoder_host_key(out))
            build(); self.assertEqual(nsp.decoder_host_key(out), before)
            record.write_text('[]')
            self.assertIsNone(nsp.decoder_host_key(out))
            build(); self.assertEqual(nsp.decoder_host_key(out), before)
            record.unlink()
            self.assertIsNone(nsp.decoder_host_key(out))
            build(); self.assertEqual(nsp.decoder_host_key(out), before)


if __name__ == '__main__':
    unittest.main()
