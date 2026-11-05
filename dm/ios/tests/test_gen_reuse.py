"""build_ipa.sh's generated Gen/ kept across builds (DM_GEN_REUSE): dm/ios/tools/gen_reuse.py's mirror, digests and app copy, gen_embed.py's input digests, and build_ipa.sh's own
generation lines run with stand-ins for the Apple tools (xcodegen, sips) and for the host's make (gen_build.py), without Xcode or game files.
What they prove: a repeat run with the same inputs rewrites no file in Gen/ and does not run xcodegen or sips again; a changed input replaces exactly the files it makes; another game's
build removes what only the first game had; and DM_GEN_REUSE=0 deletes Gen/ and writes every file again"""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / 'dm/ios/tools/gen_reuse.py'
SCRIPT = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
OLD = 1_000_000_000_123_456_789   # a modification time no file written now has


def tool(*args, cwd=None):
    r = subprocess.run([sys.executable, '-I', str(TOOL), *map(str, args)], capture_output=True, text=True, cwd=cwd)
    if r.returncode: raise AssertionError(r.stdout + r.stderr)
    return r.stdout.strip()


def tree(root, skip=()):   # every file and symlink below root: relative path → (inode, mtime_ns)
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if os.path.relpath(os.path.join(d, x), root) not in skip]
        for name in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, name); st = os.lstat(p)
            out[os.path.relpath(p, root)] = (st.st_ino, st.st_mtime_ns)
    return out


def contents(root, skip=()):   # relative path → bytes, or the link target
    out = {}
    for rel in tree(root, skip):
        p = os.path.join(root, rel)
        out[rel] = ('link', os.readlink(p)) if os.path.islink(p) else Path(p).read_bytes()
    return out


def age(root, skip=()):   # an old modification time on every file and symlink: a file the next run writes has a new one
    for rel in tree(root, skip):
        os.utime(os.path.join(root, rel), ns=(OLD, OLD), follow_symlinks=False)


class Sync(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name); self.gen = self.root / 'Gen'; self.stage = self.gen / '.stage'

    def put(self, base, rel, data=None, link=None):
        p = base / rel; p.parent.mkdir(parents=True, exist_ok=True)
        if link is not None: p.symlink_to(link)
        else: p.write_bytes(data)
        return p

    def test_same_bytes_and_links_stay_others_replaced_stale_removed(self):
        for base in (self.gen, self.stage):
            self.put(base, 'dm/same.tsv', b'same'); self.put(base, 'src/a.c', link='/x/a.c')
        self.put(self.gen, 'dm/changed.tsv', b'old'); self.put(self.stage, 'dm/changed.tsv', b'new')
        self.put(self.gen, 'src/b.c', link='/x/b.c'); self.put(self.stage, 'src/b.c', link='/y/b.c')   # the same name, another target (another checkout)
        self.put(self.gen, 'dm/cheats/other_game.txt', b'cheat'); self.put(self.gen, 'other.variants.bin', b'pages')
        self.put(self.gen, '.reuse/icon', b'key'); self.put(self.gen, 'Info.plist', b'plist')
        self.put(self.stage, 'dm/new.tsv', b'added')
        self.put(self.gen, 'kind', b'a file'); self.put(self.stage, 'kind/inside', b'now a folder')
        age(self.gen, skip={'.stage'}); before = tree(self.gen)
        out = tool('sync', self.stage, self.gen, '--keep', '.reuse', '--keep', 'Info.plist')
        after = tree(self.gen)
        for rel in ('dm/same.tsv', 'src/a.c', '.reuse/icon', 'Info.plist'): self.assertEqual(after[rel], before[rel], rel)   # inode and time
        self.assertEqual((self.gen / 'dm/changed.tsv').read_bytes(), b'new'); self.assertNotEqual(after['dm/changed.tsv'][1], OLD)
        self.assertEqual(os.readlink(self.gen / 'src/b.c'), '/y/b.c')
        self.assertFalse((self.gen / 'dm/cheats').exists()); self.assertFalse((self.gen / 'other.variants.bin').exists())
        self.assertEqual((self.gen / 'dm/new.tsv').read_bytes(), b'added'); self.assertEqual((self.gen / 'kind/inside').read_bytes(), b'now a folder')
        self.assertFalse(self.stage.exists())   # the generation folder goes
        self.assertEqual(set(contents(self.gen, skip={'.reuse'})) - {'.reuse/icon', 'Info.plist'}, {'dm/same.tsv', 'src/a.c', 'src/b.c', 'dm/changed.tsv', 'dm/new.tsv', 'kind/inside'})
        self.assertIn('2 kept', out)

    def test_a_mode_change_does_not_rewrite(self):
        self.put(self.gen, 'tool.sh', b'#!/bin/sh\n'); s = self.put(self.stage, 'tool.sh', b'#!/bin/sh\n'); s.chmod(0o755)
        age(self.gen, skip={'.stage'}); before = tree(self.gen)
        tool('sync', self.stage, self.gen)
        self.assertEqual(tree(self.gen)['tool.sh'], before['tool.sh'])
        self.assertTrue(os.stat(self.gen / 'tool.sh').st_mode & stat.S_IXUSR)

    def test_a_missing_gen_is_made(self):
        stage = self.root / 'stage'; self.put(stage, 'dm/a', b'a')
        tool('sync', stage, self.gen)
        self.assertEqual((self.gen / 'dm/a').read_bytes(), b'a'); self.assertFalse(stage.exists())

    def test_a_name_changed_only_in_case_on_a_case_insensitive_volume(self):   # the Mac's default APFS and exFAT: the old spelling must not take this run's file away with it
        self.put(self.gen, 'dm/cheats/0100abcdef012345.txt', b'[inf hp]\n'); self.put(self.stage, 'dm/cheats/0100ABCDEF012345.txt', b'[inf hp]\n')
        self.put(self.gen, 'dm/p1/main.gates.tsv', b'g'); self.put(self.stage, 'dm/P1/main.gates.tsv', b'g')   # a folder too
        import builtins, importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location('gen_reuse_ci', TOOL); gr = importlib.util.module_from_spec(spec); spec.loader.exec_module(gr)
        root, real = str(self.root), {'lstat': os.lstat, 'listdir': os.listdir, 'replace': os.replace, 'unlink': os.unlink, 'open': builtins.open}
        def ci(p):   # the spelling on disk: each part of the path matched without regard to case, as such a volume does
            if not isinstance(p, (str, os.PathLike)): return p
            p = os.path.abspath(p)
            if not p.startswith(root + os.sep): return p
            cur = root
            for part in os.path.relpath(p, root).split(os.sep):
                try: names = real['listdir'](cur)
                except OSError: names = []
                cur = os.path.join(cur, part if part in names else next((x for x in names if x.lower() == part.lower()), part))
            return cur
        def replace(s, d):   # a rename onto another case's entry replaces it under the new spelling
            t = ci(d)
            if t != os.path.abspath(d) and os.path.lexists(t): (shutil.rmtree if os.path.isdir(t) and not os.path.islink(t) else real['unlink'])(t)
            real['replace'](ci(s), d)
        fd = lambda f: lambda p, *a, **k: f(p if k.get('dir_fd') is not None else ci(p), *a, **k)   # shutil.rmtree's calls relative to a folder's descriptor pass as they are
        with mock.patch('os.lstat', fd(real['lstat'])), mock.patch('os.listdir', lambda p='.': real['listdir'](ci(p))), mock.patch('os.unlink', fd(real['unlink'])), \
             mock.patch('builtins.open', lambda p, *a, **k: real['open'](ci(p), *a, **k)), mock.patch('os.replace', replace):
            with contextlib.redirect_stdout(io.StringIO()): gr.sync(str(self.stage), str(self.gen), {'.reuse', 'Info.plist'})
        self.assertEqual(os.listdir(self.gen / 'dm/cheats'), ['0100ABCDEF012345.txt'])
        self.assertEqual((self.gen / 'dm/cheats/0100ABCDEF012345.txt').read_bytes(), b'[inf hp]\n')
        self.assertEqual(sorted(os.listdir(self.gen / 'dm')), ['P1', 'cheats']); self.assertEqual((self.gen / 'dm/P1/main.gates.tsv').read_bytes(), b'g')
        self.assertFalse(self.stage.exists())


class Digest(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); self.root = Path(t.name)
        (self.root / 'd/sub').mkdir(parents=True); (self.root / 'd/sub/f').write_bytes(b'one'); (self.root / 'd/x').write_bytes(b'x')

    def d(self, *args, **env):
        r = subprocess.run([sys.executable, '-I', str(TOOL), 'digest', *map(str, args)], capture_output=True, text=True, env=dict(os.environ, **env))
        self.assertEqual(r.returncode, 0, r.stderr); return r.stdout.strip()

    def test_items(self):
        d = self.root / 'd'
        tree0, list0, stat0 = self.d('--tree', d), self.d('--list', d), self.d('--stat', d)
        (d / 'sub/f').write_bytes(b'two')   # same size, other bytes
        self.assertNotEqual(self.d('--tree', d), tree0); self.assertEqual(self.d('--list', d), list0)
        self.assertNotEqual(self.d('--stat', d), stat0)   # a new time at least
        self.assertEqual(self.d('--tree', d, '--skip', d / 'sub'), self.d('--tree', d, '--skip', d / 'sub'))
        self.assertEqual(self.d('--list', d, '--shallow', d / 'sub'), self.d('--list', d, '--shallow', d / 'sub', '--skip', d / 'sub/f'))
        (d / 'sub/g').write_bytes(b'')
        self.assertNotEqual(self.d('--list', d), list0)
        self.assertNotEqual(self.d('--file', d / 'x'), self.d('--file', d / 'nope'))
        self.assertNotEqual(self.d('--text', 'a', '--text', 'b'), self.d('--text', 'ab'))

    def test_env_of_names_the_values_the_file_uses(self):
        yml = self.root / 'p.yml'; yml.write_text('name: ${DM_A}\nid: ${DM_B}\nkeep: $(DM_C)\n')
        a = self.d('--env-of', yml, DM_A='x', DM_B='y', DM_C='1')
        self.assertEqual(self.d('--env-of', yml, DM_A='x', DM_B='y', DM_C='2'), a)   # $(…) is Xcode's, not the environment's
        self.assertNotEqual(self.d('--env-of', yml, DM_A='x', DM_B='z', DM_C='1'), a)
        env = {k: v for k, v in os.environ.items() if k != 'DM_B'}
        r = subprocess.run([sys.executable, '-I', str(TOOL), 'digest', '--env-of', str(yml)], capture_output=True, text=True, env=dict(env, DM_A='x', DM_B=''))
        self.assertNotEqual(r.stdout.strip(), a)


class CopyApp(unittest.TestCase):
    def test_copy_without_the_skipped_folders(self):
        with tempfile.TemporaryDirectory() as t:
            app, dest = Path(t) / 'DmIOS.app', Path(t) / 'sign/DmIOS.app'
            (app / 'dm').mkdir(parents=True); (app / 'romfs').mkdir(); (app / 'DmIOS').write_bytes(b'exe'); (app / 'DmIOS').chmod(0o755)
            (app / 'dm/launcher.json').write_text('{}'); (app / 'romfs/huge').write_bytes(b'game'); (app / 'link').symlink_to('dm')
            dest.parent.mkdir(); dest.mkdir(); (dest / 'stale').write_text('old')
            tool('copy-app', app, dest, '--skip', 'romfs')
            self.assertEqual(sorted(p.name for p in dest.iterdir()), ['DmIOS', 'dm', 'link'])
            self.assertEqual((dest / 'DmIOS').read_bytes(), b'exe'); self.assertTrue(os.stat(dest / 'DmIOS').st_mode & stat.S_IXUSR)
            self.assertEqual(os.readlink(dest / 'link'), 'dm'); self.assertEqual((dest / 'dm/launcher.json').read_text(), '{}')
            self.assertEqual((app / 'romfs/huge').read_bytes(), b'game')   # the source is not touched


class GenEmbed(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.out = Path(t.name) / 'patched'; self.out.mkdir()
        (self.out / 'main.patched.bin').write_bytes(bytes(range(256)) * (0x10000 // 256))
        (self.out / 'main.fixups.tsv').write_text('# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n')
        (self.out / 'main.variants').write_text('# header\nfps\tc\t0x10\t0x10\taabb\n')
        self.jit = Path(t.name) / 'jit.img'; self.jit.write_bytes(b'\x01' * 100)
        self.stage = Path(t.name) / 'Gen/.stage'; self.stage.mkdir(parents=True); self.final = Path(t.name) / 'Gen'

    def embed(self, dst=None, *extra):
        dst = dst or self.stage / 'embed.S'
        subprocess.run([sys.executable, REPO / 'dm/ios/tools/gen_embed.py', '--ref-dir', self.final, '--jit', self.jit, *extra, self.out, dst, 'main'], check=True, capture_output=True)
        return dst.read_text()

    def test_inputs_named_by_digest_and_the_variants_pages_by_their_final_place(self):
        asm = self.embed()
        sha = hashlib.sha256((self.out / 'main.patched.bin').read_bytes()).hexdigest()
        self.assertIn(f'// input sha256={sha} size=65536 {self.out / "main.patched.bin"}', asm)
        self.assertIn(f'.incbin "{self.final / "main.variants.bin"}"', asm)   # assembled from Gen/, written into the generation folder
        vbin = (self.stage / 'main.variants.bin').read_bytes()
        self.assertIn(f'// input sha256={hashlib.sha256(vbin).hexdigest()} size={len(vbin)} {self.final / "main.variants.bin"}', asm)
        self.assertIn(f'// input sha256={hashlib.sha256(self.jit.read_bytes()).hexdigest()} size=100 {self.jit}', asm)
        lines = asm.splitlines(); self.assertTrue(lines[0].startswith('// Generated')); self.assertTrue(all(l.startswith('// input ') for l in lines[1:4]))

    def test_a_changed_byte_in_any_input_changes_the_file_and_nothing_else_does(self):
        dst = self.final / 'embed.S'; first = self.embed(dst)
        os.utime(dst, ns=(OLD, OLD)); self.assertEqual(self.embed(dst), first)
        self.assertEqual(dst.stat().st_mtime_ns, OLD)   # the same bytes are not written again
        for change in (lambda: self.patch(self.out / 'main.patched.bin', 0x5000), lambda: (self.out / 'main.variants').write_text('# header\nfps\tc\t0x10\t0x10\taabc\n'),
                       lambda: self.patch(self.jit, 3)):
            before = self.embed(dst); change()
            self.assertNotEqual(self.embed(dst), before)

    def patch(self, path, at):
        b = bytearray(path.read_bytes()); b[at] ^= 0xff; path.write_bytes(bytes(b))

    def test_default_reference_is_the_output_folder(self):   # without --ref-dir, as before: the .incbin names the file written beside the output
        dst = self.final / 'embed.S'
        subprocess.run([sys.executable, REPO / 'dm/ios/tools/gen_embed.py', self.out, dst, 'main'], check=True, capture_output=True)
        self.assertIn(f'.incbin "{self.final / "main.variants.bin"}"', dst.read_text()); self.assertTrue((self.final / 'main.variants.bin').is_file())


STUB_GEN_BUILD = '''import os, sys
host, gen = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(f'{gen}/src'); os.makedirs(f'{gen}/main')
for n in sorted(os.listdir(host)):
    if n == 'main.c': os.symlink(f'{host}/{n}', f'{gen}/main/main.c')
    elif n.endswith('.c'): os.symlink(f'{host}/{n}', f'{gen}/src/host__{n}')
print(f'HEADER_SEARCH_PATHS = $(inherited) "{host}"')
'''
STUB_SETTINGS = '''import json, sys
json.dump({"game": sys.argv[1], "settings": [{"env": "DM_LANG", "default": "en-US"}]}, open(sys.argv[4], "w")); print("1 setting")
'''
STUB_GAME = """import os, sys
a = sys.argv[1:]
if a[0] == 'dir': print(os.environ['STUB_GD'])
else: print({'modules': 'main', 'romfs_marker': 'marker'}.get(a[1], a[2] if len(a) > 2 else ''))
"""   # game.py dir <id> | <id> <key> [default]
STUB_FONT = 'import os, sys, time\nopen(sys.argv[1], "w").write("font " + os.environ.get("SOURCE_DATE_EPOCH", str(time.time_ns())) + "\\n")\n'   # as fontTools: the time unless SOURCE_DATE_EPOCH
STUB_XCODEGEN = '''#!/bin/sh
case "$1" in
--version) echo "Version: 2.99.0";;
generate) echo generate >> "$STUB_LOG"; [ -z "${STUB_XCODEGEN_FAIL:-}" ] || exit 1; mkdir -p DmIOS.xcodeproj/project.xcworkspace DmIOS.xcodeproj/xcshareddata/xcschemes Gen
  printf 'pbxproj %s %s\\n' "$DM_BUNDLE_ID" "$(ls Gen/src | tr '\\n' ' ')" > DmIOS.xcodeproj/project.pbxproj; echo workspace > DmIOS.xcodeproj/project.xcworkspace/contents.xcworkspacedata
  echo scheme > "DmIOS.xcodeproj/xcshareddata/xcschemes/$DM_SCHEME_NAME.xcscheme"
  printf '<plist>%s %s %s %s</plist>\\n' "$DM_DISPLAY_NAME" "$DM_BUNDLE_ID" "$DM_LANG" "$DM_SHOW_FPS" > Gen/Info.plist;;
*) exit 2;;
esac
'''
STUB_SIPS = '#!/bin/sh\necho "sips $7" >> "$STUB_LOG"; { cat "$7"; date +%s%N; } > "$9"\n'   # sips -s format png -z 1024 1024 <in> --out <out>: not the same bytes twice


class BuildScriptGen(unittest.TestCase):
    """build_ipa.sh from its Gen/ generation to the workspace settings, as written, in a stand-in checkout (a Vulkan game: no NVN shader tables, no PlistBuddy)"""
    SEGMENT = SCRIPT[SCRIPT.index('\nGEN_REUSE=1;'):SCRIPT.index('\nif [ "$PREPARE_XCODE" = YES ]; then\n  t "Xcode project:')]
    PROGRAMS = SCRIPT[SCRIPT.index('\nprog_rows() {'):SCRIPT.index('\n', SCRIPT.index('\nprog_back() {') + 1)] + '\n'   # a game of several programs: its rows' helpers

    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        r = self.root = Path(t.name).resolve()
        self.ios, self.dm, self.log = r / 'ios', r / 'dm', r / 'stub.log'
        for d in ('ios/tools', 'ios/Sources', 'dm/games', 'dm/tools', 'dm/host', 'dm/gfx/nvn', 'bin', 'gd', 'msl/vk', 'w'): (r / d).mkdir(parents=True)
        for n in ('gen_embed.py', 'gen_resources.py', 'gen_reuse.py'): (self.ios / 'tools' / n).symlink_to(REPO / 'dm/ios/tools' / n)
        (self.ios / 'tools/gen_build.py').write_text(STUB_GEN_BUILD)
        shutil.copy(REPO / 'dm/ios/project.yml', self.ios / 'project.yml')
        for n in ('main.m', 'Launcher.swift'): (self.ios / 'Sources' / n).write_text(n)
        (self.dm / 'games/settings.py').write_text(STUB_SETTINGS); (self.dm / 'games/game.py').write_text(STUB_GAME); (self.dm / 'tools/make_ext_font.py').write_text(STUB_FONT)
        for n in ('main.c', 'hle_a.c', 'hle_b.c'): (self.dm / 'host' / n).write_text(n)
        (self.dm / 'gfx/nvn/dmsh_chain.h').write_text('#define DMSH_CHAIN "fixture"\n')
        for n, body in (('xcodegen', STUB_XCODEGEN), ('sips', STUB_SIPS)): (r / 'bin' / n).write_text(body); (r / 'bin' / n).chmod(0o755)
        (r / 'gd/shader_map.tsv').write_text('map\n'); (r / 'gd/pso_manifest.tsv').write_text('pso\n'); (r / 'msl/vk/vk_shaders.metallib').write_text('lib')
        (r / 'std.ttf').write_text('standard font'); (r / 'cheats').mkdir(); (r / 'cheats/inf.txt').write_text('cheat'); (r / 'env.txt').write_text('DM_X=1\n')
        self.game('A', variants=True, icon=b'icon A')
        self.game('B', variants=False, icon=None)

    def game(self, name, variants, icon):   # a game's rewritten modules and RomFS folder
        p = self.root / f'patched_{name}'; p.mkdir()
        (p / 'main.patched.bin').write_bytes(bytes(range(256)) * (0x10000 // 256) + name.encode() * 16)
        (p / 'main.fixups.tsv').write_text('# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n')
        for k in ('gates', 'cuts', 'obs'): (p / f'main.{k}.tsv').write_text(f'{k} {name}\n')
        if variants: (p / 'main.variants').write_text('# header\nfps\tc\t0x10\t0x10\taabb\n')
        g = self.root / f'game_{name}'; (g / 'RomFS').mkdir(parents=True); (g / 'RomFS/marker').write_text('romfs')
        if icon: (g / 'icon.jpg').write_bytes(icon)

    def run_gen(self, name='A', ok=True, **extra):
        r = self.root
        env = {k: v for k, v in os.environ.items() if not k.startswith(('DM_', 'SOURCE_DATE_EPOCH'))}
        env.update(PATH=f'{r}/bin:{os.environ["PATH"]}', STUB_LOG=str(self.log), STD_FONT=str(r / 'std.ttf'), LC_ALL='C', STUB_GD=str(r / 'gd'),
                   DM_BUNDLE_ID=f'org.example.{name.lower()}', DM_DISPLAY_NAME=f'Game {name}', DM_APP_VERSION='1.0', DM_APP_CATEGORY='public.app-category.games',
                   DM_TEAM_ID='0000000000', DM_SHOW_FPS='NO', DM_LANG='en-US', DM_SCHEME_NAME='DmIOS')
        if name == 'A': env.update(DM_PACKED_CHEATS=str(r / 'cheats'), DM_ENV_FILE=str(r / 'env.txt'))
        env.update(extra)
        pre = ('set -u\nt() { echo "[t] $*"; }\ndie() { echo "FAIL: $*" >&2; exit 1; }\ngp() { python3 "$DM/games/game.py" "$GAME" "$1"; }\n'
               f'IOS="{self.ios}"; IOS_SOURCE="$IOS"; DM="{self.dm}"; GAME={name}; GD="{r}/gd"; PATCHED="{r}/patched_{name}"; ROMFS="{r}/game_{name}/RomFS"; MSL_IOS="{r}/msl"\n'
               f'GFXAPI=vulkan; MODS=main; MARKER=marker; VNACP="{r}/game_{name}/control.nacp"; W="{r}/w"; PREPARE_XCODE=NO; XCODE_DD="{r}/xdd"; AOC=; PKG=; V=fixture\n'
               'P0=$GAME; P0_PATCHED=$PATCHED; P0_ROMFS=$ROMFS; P0_MSL=$MSL_IOS; P0_GFX=$GFXAPI\n' + self.PROGRAMS)
        res = subprocess.run(['/bin/bash', '-c', pre + self.SEGMENT + '\necho "[t] segment done"\n'], cwd=self.ios, env=env, capture_output=True, text=True)
        if not ok: self.assertNotEqual(res.returncode, 0, res.stdout + res.stderr); return res.stdout + res.stderr
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr); self.assertIn('segment done', res.stdout)
        return res.stdout

    def no_stage_paths(self):   # what Xcode reads names Gen/, never the generation folder, which is gone by then
        for base in (self.ios / 'Gen', self.ios / 'DmIOS.xcodeproj'):
            for d, dirs, files in os.walk(base):
                dirs[:] = [x for x in dirs if x != '.reuse']
                for n in files:
                    p = Path(d, n)
                    if not p.is_symlink(): self.assertNotIn(b'.stage', p.read_bytes(), p)
                    else: self.assertNotIn('.stage', os.readlink(p), p)

    def calls(self, word): return self.log.read_text().count(word) if self.log.exists() else 0

    def files(self): return tree(self.ios / 'Gen', skip={'.reuse'})

    def changed(self, before):   # the files a run wrote: other inode or time (all were aged)
        after = self.files()
        return {k for k in after if after[k] != before.get(k)}, set(before) - set(after)

    def test_repeat_run_writes_nothing_and_a_changed_input_only_its_file(self):
        self.run_gen()
        gen = self.ios / 'Gen'
        for rel in ('embed.S', 'main.variants.bin', 'dm.xcconfig', 'resources.env', 'Info.plist', 'dm/main.gates.tsv', 'dm/launcher.json', 'dm/cheats/inf.txt', 'dm/env.txt',
                    'dm/font/standard.ttf', 'dm/font/nintendo_ext.ttf', 'Assets.xcassets/AppIcon.appiconset/icon.png', 'src/host__hle_a.c', 'main/main.c'):
            self.assertTrue(os.path.lexists(gen / rel), rel)
        self.assertFalse((gen / '.stage').exists())
        self.assertEqual((self.calls('generate'), self.calls('sips')), (1, 1))
        age(gen); age(self.ios / 'DmIOS.xcodeproj'); before, project = self.files(), tree(self.ios / 'DmIOS.xcodeproj')
        out = self.run_gen()
        self.assertEqual(self.changed(before), (set(), set()))   # no file of Gen/ written again: same inode, same time
        self.assertEqual(tree(self.ios / 'DmIOS.xcodeproj'), project)
        self.assertEqual((self.calls('generate'), self.calls('sips')), (1, 1)); self.assertIn('Xcode project: its inputs are unchanged, kept', out)
        b = bytearray((self.root / 'patched_A/main.patched.bin').read_bytes()); b[0x5000] ^= 1; (self.root / 'patched_A/main.patched.bin').write_bytes(bytes(b))   # a module rewritten again
        self.run_gen()
        self.assertEqual(self.changed(before), ({'embed.S'}, set()))   # Xcode assembles again; nothing else changes, the project neither
        self.assertEqual(self.calls('generate'), 1)
        age(gen); before = self.files()
        (self.root / 'patched_A/main.gates.tsv').write_text('gates A, again\n')
        self.run_gen()
        self.assertEqual(self.changed(before), ({'dm/main.gates.tsv'}, set()))
        age(gen); before = self.files()
        self.run_gen(DM_SHOW_FPS='YES')   # an Info.plist value: the project is generated again; only the plist changes
        self.assertEqual(self.changed(before), ({'Info.plist'}, set())); self.assertEqual(self.calls('generate'), 2)
        self.assertIn('YES', (gen / 'Info.plist').read_text())

    def test_another_games_build_takes_away_the_first_ones_files(self):
        self.run_gen('A'); age(self.ios / 'Gen'); before = self.files()
        self.run_gen('B')
        written, removed = self.changed(before)
        self.assertEqual(removed, {'main.variants.bin', 'dm/cheats/inf.txt', 'dm/env.txt', 'Assets.xcassets/AppIcon.appiconset/icon.png', 'Assets.xcassets/AppIcon.appiconset/Contents.json'})
        self.assertTrue({'embed.S', 'Info.plist', 'dm/main.gates.tsv', 'dm/launcher.json'} <= written, written)
        self.assertFalse({'dm/font/standard.ttf', 'dm/font/nintendo_ext.ttf', 'src/host__hle_a.c', 'main/main.c'} & written)   # the same for every game: kept
        self.assertIn('Game B', (self.ios / 'Gen/Info.plist').read_text()); self.assertEqual(self.calls('generate'), 2)
        self.assertNotIn('patched_A', (self.ios / 'Gen/embed.S').read_text())
        self.assertNotIn('DM_APPICON', (self.ios / 'Gen/dm.xcconfig').read_text())
        reused = contents(self.ios / 'Gen', skip={'.reuse'})
        self.run_gen('B', DM_GEN_REUSE='0')   # the same game generated from nothing: the same Gen/, but for the time fontTools puts in the font without SOURCE_DATE_EPOCH
        fresh = contents(self.ios / 'Gen')
        self.assertEqual(set(fresh), set(reused)); self.assertEqual({k for k in fresh if fresh[k] != reused[k]}, {'dm/font/nintendo_ext.ttf'})
        self.run_gen('A'); self.assertEqual(self.calls('sips'), 2)   # back to the first game: its icon is converted again (Gen/ had none)

    def test_reuse_off_writes_everything_again(self):
        self.run_gen(); reused = contents(self.ios / 'Gen', skip={'.reuse'})
        age(self.ios / 'Gen'); before = self.files()
        out = self.run_gen(DM_GEN_REUSE='0')
        after = self.files()
        self.assertEqual(set(after), set(before)); self.assertFalse([k for k, v in after.items() if v[1] == OLD])   # every file written now
        self.assertFalse((self.ios / 'Gen/.reuse').exists())
        self.assertEqual((self.calls('generate'), self.calls('sips')), (2, 2)); self.assertIn('DM_GEN_REUSE=0: all of them again', out)
        fresh = contents(self.ios / 'Gen')
        self.assertEqual({k for k in fresh if fresh[k] != reused[k]}, {'dm/font/nintendo_ext.ttf', 'Assets.xcassets/AppIcon.appiconset/icon.png'})   # as before: the time in the font, sips's own bytes
        self.run_gen(); self.assertEqual(self.calls('generate'), 3)   # no record of the project after a run without reuse: generated again

    def test_icon_converted_again_when_its_image_changes(self):
        self.run_gen(); icon = (self.ios / 'Gen/Assets.xcassets/AppIcon.appiconset/icon.png').read_bytes()
        (self.root / 'game_A/icon.jpg').write_bytes(b'icon A, new')
        self.run_gen(); self.assertEqual(self.calls('sips'), 2)
        self.assertNotEqual((self.ios / 'Gen/Assets.xcassets/AppIcon.appiconset/icon.png').read_bytes(), icon)
        (self.ios / 'Gen/Assets.xcassets/AppIcon.appiconset/icon.png').write_bytes(b'touched')   # not what the record names: converted again
        self.run_gen(); self.assertEqual(self.calls('sips'), 3)

    def test_project_generated_again_when_its_files_change(self):
        self.run_gen()
        (self.dm / 'host/hle_c.c').write_text('new source')   # a source file the project lists
        self.run_gen(); self.assertEqual(self.calls('generate'), 2); self.assertIn('host__hle_c.c', (self.ios / 'DmIOS.xcodeproj/project.pbxproj').read_text())
        (self.ios / 'DmIOS.xcodeproj/project.pbxproj').write_text('edited in Xcode')   # the project is not what xcodegen wrote: generated again
        self.run_gen(); self.assertEqual(self.calls('generate'), 3)
        (self.ios / 'Gen/Info.plist').unlink()
        self.run_gen(); self.assertEqual(self.calls('generate'), 4); self.assertTrue((self.ios / 'Gen/Info.plist').is_file())

    def test_no_file_names_the_generation_folder(self):   # embed.S's .incbin of the variants pages, resources.env, dm.xcconfig, the project: Gen/ paths only (Gen/.stage is deleted before xcodegen)
        self.run_gen(); self.no_stage_paths()
        self.assertIn(f'.incbin "{self.ios / "Gen/main.variants.bin"}"', (self.ios / 'Gen/embed.S').read_text())
        tsv = self.root / 'programs.tsv'
        tsv.write_text(''.join(f'{i}\t{n}\t{self.root}/patched_{n}\t{self.root}/game_{n}/RomFS\t{self.root}/msl\tvulkan\n' for i, n in enumerate('AB')))
        self.run_gen(PROGRAMS_TSV=str(tsv)); self.no_stage_paths()

    def test_a_failed_project_generation_is_not_taken_for_a_kept_one(self):   # the record of the last good run stays, but the Info.plist set aside is missing: generated again
        self.run_gen()
        self.run_gen(ok=False, DM_SHOW_FPS='YES', STUB_XCODEGEN_FAIL='1')   # another input, and xcodegen stops
        self.assertFalse((self.ios / 'Gen/Info.plist').exists())
        n = self.calls('generate'); self.run_gen()   # the first run's inputs again: its record's key matches, its outputs do not
        self.assertEqual(self.calls('generate'), n + 1); self.assertIn('NO</plist>', (self.ios / 'Gen/Info.plist').read_text())
        n = self.calls('generate'); self.run_gen(); self.assertEqual(self.calls('generate'), n)   # and then kept

    def test_a_game_of_several_programs(self):   # PROGRAMS_TSV (Super Mario 3D All-Stars): each program's tables in dm/p<N>, its modules under its tag, its variants pages beside embed.S
        r = self.root; tsv = r / 'programs.tsv'
        rows = lambda *names: tsv.write_text('# program\tprofile\tpatched\tRomFS\tshaders\tAPI\n' + ''.join(f'{i}\t{n}\t{r}/patched_{n}\t{r}/game_{n}/RomFS\t{r}/msl\tvulkan\n' for i, n in enumerate(names)))
        rows('A', 'B'); self.run_gen(PROGRAMS_TSV=str(tsv))
        gen = self.ios / 'Gen'
        self.assertEqual((gen / 'dm/programs.txt').read_text(), '0\n1\n'); self.assertEqual((gen / 'dm/p1/main.gates.tsv').read_text(), 'gates B\n')
        asm = (gen / 'embed.S').read_text()
        self.assertIn('__dmp0mainx0', asm); self.assertIn('__dmp1mainx0', asm); self.assertIn(f'.incbin "{gen / "p0main.variants.bin"}"', asm); self.assertTrue((gen / 'p0main.variants.bin').is_file())
        self.assertIn(f'DM_RESOURCE_PROGRAMS={gen / "resources_programs.tsv"}', (gen / 'resources.env').read_text())
        self.assertEqual(len((gen / 'resources_programs.tsv').read_text().splitlines()), 3)
        age(gen); before = self.files()
        self.run_gen(PROGRAMS_TSV=str(tsv)); self.assertEqual(self.changed(before), (set(), set()))
        rows('A'); self.run_gen(PROGRAMS_TSV=str(tsv))
        written, removed = self.changed(before)
        self.assertEqual(removed, {'dm/p1/main.gates.tsv', 'dm/p1/main.cuts.tsv', 'dm/p1/main.obs.tsv', 'dm/p1/main.fixups.tsv', 'dm/p1/launcher.json', 'dm/p1/shader_map.tsv', 'dm/p1/pso_manifest.tsv'})
        self.assertEqual(written, {'embed.S', 'dm.xcconfig', 'dm/programs.txt', 'resources_programs.tsv'})   # dm.xcconfig: program 1's -segprot link flag goes


if __name__ == '__main__':
    unittest.main()
