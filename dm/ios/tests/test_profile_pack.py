"""Pack tiny shader fixtures through build_ipa.sh's archive step, without Xcode or game files."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
import game
sys.path.insert(0, str(REPO / 'dm/tools'))
import shader_lib


class ProfilePackTests(unittest.TestCase):
    def test_an_image_without_pulling_libraries_stops_an_app_that_needs_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); lib = root / 'b-fixture'; lib.mkdir(); (lib / 'k_b.metallib').write_text('lib'); (lib / 'k_bp.metallib').write_text('pull')
            shader_lib.pack(lib, leave_out=True)
            def pack(*options): return subprocess.run([sys.executable, str(REPO / 'dm/ios/tools/pack_ipa.py'), str(root / 'x.ipa'), *options, f'Payload/DmIOS.app/msl/b-fixture={lib}'], capture_output=True, text=True)
            r = pack(); self.assertNotEqual(r.returncode, 0); self.assertIn('no pulling vertex libraries', r.stdout + r.stderr)
            r = pack('--skip-suffix', '_bp.metallib'); self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with zipfile.ZipFile(root / 'x.ipa') as archive: self.assertIn('Payload/DmIOS.app/msl/b-fixture.img', archive.namelist())
            self.assertEqual([n for n in os.listdir(root) if '.msl-' in n], [])

    def test_pulling_libraries_survive_runtime_prebuild_without_an_archive(self):
        # (game, IOS_PULL, with a pipeline archive, _bp libraries packed): an archive's bases are made of the pulling libraries, so an IPA with one carries them whatever IOS_PULL says.
        # The Metal 4 path is on by default; '<id>+off' is that profile with pso_mtl4 off, which still carries them (the launcher's Metal 4 toggle and its prebuild read them)
        cases = [('01007EF00011E000', None, False, True), ('010015100B514000', None, False, True), ('01008CF01BAAC000', None, False, True), ('010015100B514000+off', None, False, True),
                 ('01007EF00011E000', '0', False, False), ('01008CF01BAAC000', '0', False, False), ('010015100B514000+off', '0', False, False),
                 ('010015100B514000', '1', False, True), ('010015100B514000+off', '1', False, True),
                 ('010015100B514000', None, True, True), ('010015100B514000+off', None, True, True), ('01007EF00011E000', '0', True, True)]
        for gid, override, with_pso, included, packed in [c + (p,) for c in cases for p in (False, True)]:
            with self.subTest(game=gid, IOS_PULL=override, archive=with_pso, one_file=packed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                gid, off = gid.removesuffix('+off'), gid.endswith('+off')
                profile = REPO / 'dm/games' / gid
                if off:
                    profile = root / 'profile' / gid; profile.mkdir(parents=True)
                    (profile / 'game.tsv').write_text((REPO / 'dm/games' / gid / 'game.tsv').read_text(encoding='utf-8') + 'pso_mtl4\toff\n', encoding='utf-8')
                dm = root / 'dm'
                header = dm / 'host/gen' / gid / 'game_profile.h'
                header.parent.mkdir(parents=True)
                header.write_text(game.header(game.Game(profile)))
                app, shaders, romfs = [root / name for name in ('DmIOS.app', 'shaders', 'romfs')]
                for folder in (app, shaders / 'b-fixture', romfs): folder.mkdir(parents=True)
                for name in ('fixture_b.metallib', 'fixture_bp.metallib', 'fixture_bv.metallib', 'fixture_b.json'):
                    (shaders / 'b-fixture' / name).write_text(name)
                if packed: self.assertTrue(shader_lib.pack(shaders / 'b-fixture'))
                (app / 'executable').write_text('app')
                (romfs / 'marker').write_text('romfs')
                (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
                out = root / 'fixture.ipa'
                env = {k: v for k, v in os.environ.items() if k not in ('IOS_PULL', 'DM_GAMES_DIR', 'DM_GAMES_FIRST')}
                env.update(GAME=gid, DM=str(dm), APP=str(app), MSL_IOS=str(shaders), MSLDIR='b-fixture',
                           AOC='', ROMFS=str(romfs), OUT_IPA=str(out), PROFILE_TOOL=str(REPO / 'dm/games/game.py'))
                if override is not None: env['IOS_PULL'] = override
                if with_pso:
                    pso = root / 'pso'; pso.mkdir(); (pso / 'prebuilt.tsv').write_text('fixture')
                    env['PSO'] = str(pso)
                # Exercise the actual archive step; only the preceding Xcode build is bypassed.
                script = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
                packing = script[script.index('\nP=Payload/DmIOS.app\n'):]
                result = subprocess.run(['/bin/bash', '-c', 'set -u\nt() { :; }; die() { echo "$*" >&2; exit 1; }\n'
                                         'gp() { python3 "$PROFILE_TOOL" "$GAME" "$1"; }\n' + packing],
                                        cwd=root, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with zipfile.ZipFile(out) as archive:
                    names = set(archive.namelist())
                    prefix = 'Payload/DmIOS.app/msl/b-fixture/'
                    if packed:
                        self.assertFalse([n for n in names if n.startswith(prefix)])
                        (root / 'taken.img').write_bytes(archive.read('Payload/DmIOS.app/msl/b-fixture.img'))
                        names = {prefix + p.name for p in shader_lib.romfs.Path(root / 'taken.img').iterdir()} | names
                        self.assertEqual([n for n in os.listdir(root) if '.msl-' in n], [], 'the copy without the pulling libraries is gone')
                    self.assertEqual(prefix + 'fixture_bp.metallib' in names, included)
                    for name in ('fixture_b.metallib', 'fixture_bv.metallib', 'fixture_b.json'):
                        self.assertIn(prefix + name, names)
                    self.assertEqual(archive.read('Payload/DmIOS.app/romfs/marker'), b'romfs')
                    self.assertEqual('Payload/DmIOS.app/pso/prebuilt.tsv' in names, with_pso)

    def test_programs_pull_whatever_a_program_profile_says(self):
        # build_ipa.sh's _bp choice for a multi-program app (PROGRAMS_TSV) is the same as for one game: the pulling libraries go in unless IOS_PULL=0, and always with a pipeline archive (pso/).
        # No program's pso_mtl4 is read (a profile with it off can have Metal 4 turned on in the launcher)
        script = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        start = script.index('PACK_OPTS=(--store "$ZS");')
        line = script[start:script.index('\n', start)]
        code = [l for l in script[script.index('t "pack IPA'):start].splitlines() if not l.lstrip().startswith('#')]
        self.assertFalse([l for l in code if 'pso_mtl4' in l or 'PSO_MTL4' in l], 'the packing step reads no profile pso_mtl4')
        for override, pso, skip in [(None, '', False), ('1', '', False), ('0', '', True), ('0', '/x/pso', False), (None, '/x/pso', False)]:
            with self.subTest(IOS_PULL=override, archive=bool(pso)):
                env = {k: v for k, v in os.environ.items() if k not in ('IOS_PULL', 'PSO')}
                env.update(ZS='', PROGRAMS_TSV='/x/programs.tsv', PSO=pso)
                if override is not None: env['IOS_PULL'] = override
                r = subprocess.run(['/bin/bash', '-c', 'set -u\n' + line + '\necho "${PACK_OPTS[*]}"'], env=env, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual('--skip-suffix _bp.metallib' in r.stdout, skip, r.stdout)

    def test_programs_pack_the_pipeline_archive(self):
        # A multi-program IPA (PROGRAMS_TSV) carries the archive built for program 0 as pso/ (the Xcode build of an IPA copies no game resources), with that program's pulling libraries
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, pso = root / 'DmIOS.app', root / 'pso'
            for folder in (app, pso, root / 'p0/romfs', root / 'p1/romfs', root / 'p0/shaders/b-fixture', root / 'p1/shaders/b-fixture'): folder.mkdir(parents=True)
            (app / 'executable').write_text('app'); (pso / 'prebuilt.tsv').write_text('fixture')
            for n in (0, 1): (root / f'p{n}/romfs/marker').write_text(f'romfs {n}')
            for name in ('fixture_b.metallib', 'fixture_bp.metallib', 'fixture_bv.metallib', 'fixture_b.json'): (root / 'p0/shaders/b-fixture' / name).write_text(name)
            (root / 'p1/shaders/b-fixture/p1_b.metallib').write_text('p1')
            (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
            tsv = root / 'programs.tsv'
            tsv.write_text(f'0\t010049900F546000\t-\t{root}/p0/romfs\t{root}/p0/shaders\tnvn\n1\t010049900F546001\t-\t{root}/p1/romfs\t{root}/p1/shaders\tnvn\n')
            env = {k: v for k, v in os.environ.items() if k not in ('IOS_PULL', 'DM_GAMES_DIR', 'DM_GAMES_FIRST', 'DM_COPY_ROMFS')}
            env.update(GAME='010049900F546000', DM=str(REPO / 'dm'), APP=str(app), AOC='', OUT_IPA=str(root / 'fixture.ipa'), PSO=str(pso), PROGRAMS_TSV=str(tsv))
            script = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
            packing = script[script.index('\nP=Payload/DmIOS.app\n'):]
            # prog_set as build_ipa.sh's, without the profile's modules and marker, which the packing does not read
            helpers = ('set -u\nt() { :; }; die() { echo "$*" >&2; exit 1; }\ngp() { python3 "$DM/games/game.py" "$GAME" "$1"; }\n'
                       'prog_rows() { grep -v "^#" "$PROGRAMS_TSV" | grep -v "^$"; }\n'
                       'prog_set() { IFS=$\'\\t\' read -r PN GAME PATCHED ROMFS MSL_IOS GFXAPI <<< "$1"; MSLDIR=b-fixture; }\n'
                       'prog_back() { GAME=010049900F546000; }\n')
            r = subprocess.run(['/bin/bash', '-c', helpers + packing], cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            with zipfile.ZipFile(root / 'fixture.ipa') as archive:
                names = set(archive.namelist())
                self.assertIn('Payload/DmIOS.app/pso/prebuilt.tsv', names)
                self.assertIn('Payload/DmIOS.app/msl/p0/b-fixture/fixture_bp.metallib', names)
                self.assertIn('Payload/DmIOS.app/msl/p1/b-fixture/p1_b.metallib', names)
                self.assertEqual(archive.read('Payload/DmIOS.app/p1/romfs/marker'), b'romfs 1')


if __name__ == '__main__':
    unittest.main()
