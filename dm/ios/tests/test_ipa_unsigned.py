"""The unsigned IPA of build_ipa.sh: the game files stay out with DM_COPY_ROMFS=NO, and the executable carries the entitlements in an ad-hoc signature.
Only the archive step and the signing step run (a stand-in app, no Xcode or game files)."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
import game
sys.path.insert(0, str(REPO / 'dm/tools'))
import romfs_image

GAME = '010015100B514000'
SCRIPT = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
ENT_DEFAULT = next(line for line in SCRIPT.splitlines() if line.startswith('ENT_DEFAULT='))   # the default entitlements, defined once above for the Xcode project and the IPA alike
SIGNING = ENT_DEFAULT + '\n' + SCRIPT[SCRIPT.index('# The entitlements of an unsigned IPA'):SCRIPT.index('\nP=Payload/DmIOS.app\n')]
PACKING = SCRIPT[SCRIPT.index('\nP=Payload/DmIOS.app\n'):]
PREAMBLE = 'set -u\nt() { :; }; die() { echo "$*" >&2; exit 1; }\ngp() { python3 "$PROFILE_TOOL" "$GAME" "$1"; }\n'
CAN_SIGN = sys.platform == 'darwin' and shutil.which('codesign') and shutil.which('cc')


def run_step(script, root, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith('DM_') and k not in ('IOS_PULL', 'AOC', 'PSO')}
    env.update(GAME=GAME, DM=str(root / 'dm'), PROFILE_TOOL=str(REPO / 'dm/games/game.py'), **extra)
    return subprocess.run(['/bin/bash', '-c', PREAMBLE + script], cwd=root, env=env, capture_output=True, text=True)


class UnsignedIpaTests(unittest.TestCase):
    def stand_in(self, root):
        header = root / 'dm/host/gen' / GAME / 'game_profile.h'
        header.parent.mkdir(parents=True)
        header.write_text(game.header(game.Game(REPO / 'dm/games' / GAME)))
        for folder in ('DmIOS.app', 'shaders/b-fixture', 'romfs', 'aoc/0', 'pkg'): (root / folder).mkdir(parents=True)
        (root / 'shaders/b-fixture/fixture_b.metallib').write_text('lib')
        (root / 'romfs/marker').write_text('romfs')
        (root / 'aoc/0/file').write_text('aoc')
        (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
        (root / 'dm/tools').symlink_to(REPO / 'dm/tools', target_is_directory=True)

    def pack(self, image=False, identity=None, **extra):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.stand_in(root)
            (root / 'DmIOS.app/executable').write_text('app')
            if image: romfs_image.pack(root / 'romfs', root / 'RomFS.img')
            result = run_step(PACKING, root, APP=str(root / 'DmIOS.app'), MSL_IOS=str(root / 'shaders'), MSLDIR='b-fixture', ROMFS=str(root / ('RomFS.img' if image else 'romfs')),
                              AOC=str(root / 'aoc'), OUT_IPA=str(root / 'out.ipa'), O=str(root / 'pkg'), DM_APP_VERSION='1.2.1', PKG='v327680', **extra)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with zipfile.ZipFile(root / 'out.ipa') as archive:
                if identity is not None: identity.append((archive.read('Payload/DmIOS.app/romfs.id').decode() if 'Payload/DmIOS.app/romfs.id' in archive.namelist() else None, (root / 'RomFS.img').read_bytes() if image else None))
                return set(archive.namelist())

    def test_game_files_are_packed_by_default(self):
        names = self.pack()
        self.assertIn('Payload/DmIOS.app/romfs/marker', names)
        self.assertIn('Payload/DmIOS.app/aoc/0/file', names)

    def test_copy_romfs_no_leaves_the_game_files_out_and_keeps_the_rest(self):
        names = self.pack(DM_COPY_ROMFS='NO')
        self.assertFalse([n for n in names if '/romfs' in n])
        self.assertIn('Payload/DmIOS.app/executable', names)
        self.assertIn('Payload/DmIOS.app/msl/b-fixture/fixture_b.metallib', names)
        self.assertIn('Payload/DmIOS.app/aoc/0/file', names)   # add-on content has no place outside the app yet

    def test_slim_ipa_of_an_image_carries_its_identity_and_the_default_does_not(self):
        got = []
        names = self.pack(image=True, identity=got, DM_COPY_ROMFS='NO')
        self.assertFalse([n for n in names if n.endswith(('/romfs', '/romfs.img')) or '/romfs/' in n])
        self.assertIn('Payload/DmIOS.app/romfs.id', names)
        line, data = got[0]
        self.assertTrue(line.startswith(f'DMROMFSID1 title={GAME} version=1.2.1 build=v327680 size={len(data)} index='), line)   # read back
        with tempfile.NamedTemporaryFile() as f:
            f.write(data); f.flush(); self.assertTrue(romfs_image.same_identity(line, romfs_image.identity(f.name)))
        got = []
        names = self.pack(image=True, identity=got)   # bundle: exactly as before
        self.assertIn('Payload/DmIOS.app/romfs.img', names); self.assertNotIn('Payload/DmIOS.app/romfs.id', names); self.assertIsNone(got[0][0])

    def test_slim_ipa_of_a_folder_has_no_identity(self):
        self.assertNotIn('Payload/DmIOS.app/romfs.id', self.pack(DM_COPY_ROMFS='NO'))

    @unittest.skipUnless(CAN_SIGN, 'needs macOS codesign and a C compiler')
    def test_executable_carries_the_entitlements(self):
        # the default signs a copy of the app, $O/sign/DmIOS.app, which is packed in its place; DM_SIGN_REUSE=0 signs Xcode's product in place, as before
        cases = [({}, True, 'pkg/sign/DmIOS.app'), ({'DM_ENTITLEMENTS': ''}, False, 'DmIOS.app'), ({'DM_SIGN_REUSE': '0'}, True, 'DmIOS.app')]
        for extra, expected, packed in cases:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'DmIOS.app').mkdir(); (root / 'pkg').mkdir()
                (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
                (root / 'main.c').write_text('int main(void) { return 0; }\n')
                subprocess.run(['cc', '-o', str(root / 'DmIOS.app/DmIOS'), str(root / 'main.c')], check=True)
                result = run_step(SIGNING + '\necho "PACK_APP=$PACK_APP"\n', root, APP=str(root / 'DmIOS.app'), O=str(root / 'pkg'), **extra)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'PACK_APP={root / packed}\n', result.stdout)
                shown = subprocess.run(['codesign', '-d', '--entitlements', '-', str(root / packed / 'DmIOS')], capture_output=True, text=True)
                for key in ('com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'):   # both memory entitlements by default
                    self.assertEqual(key in shown.stdout + shown.stderr, expected, key)


STUB_CODESIGN = """#!/bin/sh
# codesign --force --sign - --entitlements <plist> <executable> | codesign -d --entitlements - <executable>
if [ "$1" = --force ]; then echo "sign $6" >> "$STUB_LOG"; [ -z "${STUB_CODESIGN_FAIL:-}" ] || exit 1; printf 'SIGNED(%s)\\n' "$(cat "$5")" >> "$6"; mkdir -p "$(dirname "$6")/_CodeSignature"; echo seal > "$(dirname "$6")/_CodeSignature/CodeResources"; exit 0; fi
if [ "$1" = -d ]; then grep -q 'SIGNED(' "$4"; exit; fi
exit 2
"""


class SignedCopyTests(unittest.TestCase):
    """build_ipa.sh's signing step with a stand-in codesign (Linux too): the copy it signs is kept while the app Xcode built, the entitlements and the copy itself are unchanged,
    and signed again when any of them changes; Xcode's product is never signed (it would link again); DM_SIGN_REUSE=0 / DM_GEN_REUSE=0 sign it in place as before"""

    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = root = Path(t.name).resolve()
        self.app, self.pkg, self.log = root / 'dd/DmIOS.app', root / 'pkg', root / 'stub.log'
        (self.app / 'dm').mkdir(parents=True); (self.app / 'romfs').mkdir(); self.pkg.mkdir(); (root / 'bin').mkdir()
        (self.app / 'DmIOS').write_bytes(b'executable\n'); (self.app / 'DmIOS').chmod(0o755); (self.app / 'dm/launcher.json').write_text('{}')
        (self.app / 'romfs/old').write_text('game files an old build left')   # skipped by the packing: not copied, not signed
        (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
        for name, body in (('codesign', STUB_CODESIGN), ('xattr', '#!/bin/sh\nexit 0\n')): (root / 'bin' / name).write_text(body); (root / 'bin' / name).chmod(0o755)

    def sign(self, **extra):
        r = run_step(SIGNING + '\necho "PACK_APP=$PACK_APP"\n', self.root, APP=str(self.app), O=str(self.pkg), PATH=f'{self.root}/bin:{os.environ["PATH"]}', STUB_LOG=str(self.log), **extra)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout.split('PACK_APP=')[1].strip()

    def signs(self): return self.log.read_text().count('sign ') if self.log.exists() else 0

    def files(self, d): return {str(p.relative_to(d)): (p.stat().st_ino, p.stat().st_mtime_ns) for p in sorted(d.rglob('*')) if p.is_file()}

    def test_kept_while_unchanged_signed_again_on_any_change(self):
        exe = (self.app / 'DmIOS').read_bytes(); built = self.files(self.app)
        packed = Path(self.sign()); copy = self.pkg / 'sign/DmIOS.app'
        self.assertEqual(packed, copy); self.assertEqual(self.signs(), 1)
        self.assertIn(b'SIGNED(', (copy / 'DmIOS').read_bytes()); self.assertFalse((copy / 'romfs').exists())
        self.assertEqual((self.app / 'DmIOS').read_bytes(), exe); self.assertEqual(self.files(self.app), built)   # Xcode's product as Xcode left it
        signed = self.files(copy)
        self.assertEqual(Path(self.sign()), copy); self.assertEqual(self.signs(), 1); self.assertEqual(self.files(copy), signed)   # kept, inode and times: pack_ipa.py reuses it
        changes = [lambda: (self.app / 'DmIOS').write_bytes(b'linked again\n'),            # a new executable
                   lambda: (self.app / 'dm/launcher.json').write_text('{"a": 1}'),         # a resource: codesign seals them with the app
                   lambda: (self.root / 'ent.plist').write_text('<plist>other</plist>'),   # other entitlements (below)
                   lambda: (copy / 'DmIOS').write_bytes(b'touched'),                       # the copy changed since it was signed
                   lambda: (self.pkg / 'sign/key').unlink()]
        for n, change in enumerate(changes, 2):
            change()
            extra = {'DM_ENTITLEMENTS': str(self.root / 'ent.plist')} if n >= 4 else {}
            self.sign(**extra); self.assertEqual(self.signs(), n, n)
            self.sign(**extra); self.assertEqual(self.signs(), n, n)   # and kept again after it
        self.assertIn(b'linked again', (copy / 'DmIOS').read_bytes()); self.assertIn(b'other', (copy / 'DmIOS').read_bytes())

    def test_a_failed_signature_leaves_no_key(self):   # the key goes before the copy is made again: a copy codesign stopped on is never taken for a signed one
        self.sign(); (self.app / 'DmIOS').write_bytes(b'linked again\n')
        r = run_step(SIGNING, self.root, APP=str(self.app), O=str(self.pkg), PATH=f'{self.root}/bin:{os.environ["PATH"]}', STUB_LOG=str(self.log), STUB_CODESIGN_FAIL='1')
        self.assertNotEqual(r.returncode, 0); self.assertFalse((self.pkg / 'sign/key').exists())
        n = self.signs(); self.sign(); self.assertEqual(self.signs(), n + 1)
        self.assertIn(b'linked again', (self.pkg / 'sign/DmIOS.app/DmIOS').read_bytes()); self.assertTrue((self.pkg / 'sign/key').is_file())

    def test_reuse_off_signs_in_place_and_no_entitlements_signs_nothing(self):
        for extra in ({'DM_SIGN_REUSE': '0'}, {'DM_GEN_REUSE': '0'}):
            with self.subTest(**extra):
                (self.app / 'DmIOS').write_bytes(b'executable\n')
                self.assertEqual(Path(self.sign(**extra)), self.app); self.assertIn(b'SIGNED(', (self.app / 'DmIOS').read_bytes())
        n = self.signs(); (self.app / 'DmIOS').write_bytes(b'executable\n')
        self.assertEqual(Path(self.sign(DM_ENTITLEMENTS='')), self.app); self.assertEqual(self.signs(), n)

    def test_the_ipa_holds_the_signed_copy(self):
        root = self.root / 'ipa'; UnsignedIpaTests.stand_in(None, root)
        app = root / 'DmIOS.app'; shutil.copytree(self.app, app, dirs_exist_ok=True)
        r = run_step(SIGNING + PACKING, root, APP=str(app), O=str(root / 'pkg'), PATH=f'{self.root}/bin:{os.environ["PATH"]}', STUB_LOG=str(self.log),
                     MSL_IOS=str(root / 'shaders'), MSLDIR='b-fixture', ROMFS=str(root / 'romfs'), AOC=str(root / 'aoc'), OUT_IPA=str(root / 'out.ipa'), DM_APP_VERSION='1.2.1', PKG='v327680')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with zipfile.ZipFile(root / 'out.ipa') as archive:
            self.assertIn(b'SIGNED(', archive.read('Payload/DmIOS.app/DmIOS'))
            names = archive.namelist()
            self.assertEqual(archive.read('Payload/DmIOS.app/romfs/marker'), b'romfs')   # the game files from their own place, not the old build's
            self.assertNotIn('Payload/DmIOS.app/romfs/old', names); self.assertFalse([n for n in names if '_CodeSignature' in n])
            self.assertEqual(archive.read('Payload/DmIOS.app/dm/launcher.json'), b'{}')
        self.assertNotIn(b'SIGNED(', (app / 'DmIOS').read_bytes())


if __name__ == '__main__':
    unittest.main()
