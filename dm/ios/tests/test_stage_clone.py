"""stage_resources.sh's sync_romfs: a RomFS image that changed since the last Xcode build (another size or modification time to the second, rsync's quick check) is removed and cloned again
(cp -cp) instead of written whole by rsync -a; an unchanged image, a link, or DM_ROMFS_CLONE=0 goes through rsync as before, and the app ends up with the same bytes, mode and modification time
to the second either way (cp -p also keeps the time below the second, where macOS rsync, protocol 29, sets whole seconds).
The script's own function runs with logging wrappers for rsync, cp and stat: on a Mac they run the real tools, elsewhere stand-ins with rsync's quick check, its whole-second times and macOS stat's format."""
import os
from pathlib import Path
import random
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SCRIPT = (REPO / 'dm/ios/tools/stage_resources.sh').read_text()
SEGMENT = SCRIPT[SCRIPT.index('\nsync_dir() {'):SCRIPT.index('\nif [ -n "$DM_RESOURCE_PROGRAMS" ]; then\n    # A game of several programs')]
MAC = sys.platform == 'darwin'
WRAP = {   # tool: (the path the script names, its stand-in off a Mac)
    'rsync': ('/usr/bin/rsync', '''[ "$1 $2" = "-a --" ] && [ $# = 4 ] || exit 3   # a single file, as sync_romfs syncs it
s=$3; d=$4
if [ -f "$d" ] && [ ! -L "$d" ] && [ ! -L "$s" ] && [ "$(stat -c '%s %Y' -- "$s")" = "$(stat -c '%s %Y' -- "$d")" ]; then chmod --reference="$s" -- "$d"; exit 0; fi   # quick check: attributes only
cp -P --preserve=mode,timestamps -- "$s" "$d.rsync-tmp" || exit 1   # a new file renamed over the old one; -l: a link stays a link
[ -L "$s" ] || touch -m -d "@$(stat -c %Y -- "$s")" -- "$d.rsync-tmp" || exit 1   # whole seconds, as macOS rsync (2.6.9, openrsync: protocol 29) sets them
mv -fT -- "$d.rsync-tmp" "$d"'''),
    'cp': ('/bin/cp', '''[ -e "$4" ] && [ ! -d "$4" ] && echo "cp onto an existing file" >> "$LOG"   # a clone needs the place free
f=$1; exec /bin/cp "-${f#-c}" -- "$3" "$4"'''),
    'stat': ('/usr/bin/stat', '''[ "$1 $2 $3" = "-f %z %m --" ] || exit 3
exec /usr/bin/stat -c '%s %Y' -- "$4"'''),
}


class SyncRomfs(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.d = Path(t.name).resolve(); self.log = self.d / 'tools.log'
        (self.d / 'bin').mkdir()
        segment = SEGMENT
        for tool, (path, stand_in) in WRAP.items():
            w = self.d / 'bin' / tool
            w.write_text(f'#!/bin/bash\necho "{tool} $*" >> "$LOG"\n' + (f'exec {path} "$@"\n' if MAC else stand_in + '\n')); w.chmod(0o755)
            segment = segment.replace(path + ' ', f'"$BIN/{tool}" ')
        self.assertEqual([p for p, _ in WRAP.values() if p + ' ' in segment], [])
        self.segment = segment

    def sync(self, src, app, **env):
        if self.log.exists(): self.log.unlink()
        e = {k: v for k, v in os.environ.items() if not k.startswith('DM_')} | {'BIN': str(self.d / 'bin'), 'LOG': str(self.log)} | env
        r = subprocess.run(['/bin/bash', '-c', 'set -eu\ndie() { echo "[RED] $*" >&2; exit 1; }\n' + self.segment + '\nsync_romfs "$1" "$2"\n', 'x', str(src), str(app)],
                           env=e, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        self.assertNotIn('cp onto an existing file', calls)
        return [c.split()[0] for c in calls if not c.startswith('stat ')]

    def put(self, p, data, mtime, mode=0o644):
        p.write_bytes(data); os.chmod(p, mode); os.utime(p, ns=(mtime, mtime))

    def state(self, p):   # what the app's file is: kind, bytes, mode, modification time to the second (rsync sets whole seconds; the clone keeps the time below the second, which nothing reads)
        st = os.lstat(p)
        return ('link', os.readlink(p)) if stat.S_ISLNK(st.st_mode) else ('file', p.read_bytes(), stat.S_IMODE(st.st_mode), st.st_mtime_ns // 10**9)

    def test_first_unchanged_changed_and_the_switch(self):
        src, app = self.d / 'RomFS.img', self.d / 'app'; app.mkdir(); dst = app / 'romfs.img'
        T = 1_700_000_000 * 10**9
        self.put(src, b'image one', T, 0o640)
        self.assertEqual(self.sync(src, app), ['cp']); self.assertEqual(self.state(dst), self.state(src))   # the first copy, as before
        ino = dst.stat().st_ino
        self.assertEqual(self.sync(src, app), ['rsync']); self.assertEqual(dst.stat().st_ino, ino)   # unchanged: rsync, which leaves it
        self.put(src, b'image two', T + 10**9, 0o600)   # same size, another second
        self.assertEqual(self.sync(src, app), ['cp']); self.assertEqual(self.state(dst), self.state(src))   # removed first (sync checks cp found no file there)
        self.put(src, b'image three', T + 10**9, 0o600)   # another size, the same time
        self.assertEqual(self.sync(src, app), ['cp']); self.assertEqual(self.state(dst), self.state(src))
        self.put(src, b'image four!', T + 2 * 10**9)
        self.assertEqual(self.sync(src, app, DM_ROMFS_CLONE='0'), ['rsync']); self.assertEqual(self.state(dst), self.state(src))   # the switch: rsync, as before
        ino = dst.stat().st_ino
        self.put(src, b'image five!', T + 2 * 10**9 + 400_000_000)   # same size and second: rsync's quick check takes it for the same file, so no clone either
        self.assertEqual(self.sync(src, app), ['rsync']); self.assertEqual(dst.read_bytes(), b'image four!'); self.assertEqual(dst.stat().st_ino, ino)
        self.put(src, b'image six', T + 3 * 10**9 + 250_000_000)   # a clone keeps the time below the second (cp -p), the stand-in rsync sets whole seconds, as macOS's does
        self.assertEqual(self.sync(src, app), ['cp']); self.assertEqual(self.state(dst), self.state(src))
        if not MAC: self.assertEqual(dst.stat().st_mtime_ns, T + 3 * 10**9 + 250_000_000)
        self.put(src, b'image seven', T + 4 * 10**9 + 250_000_000)
        self.assertEqual(self.sync(src, app, DM_ROMFS_CLONE='0'), ['rsync']); self.assertEqual(self.state(dst), self.state(src))
        if not MAC: self.assertEqual(dst.stat().st_mtime_ns, T + 4 * 10**9)

    def test_a_link_goes_through_rsync(self):   # rsync -a copies the link itself
        src, app = self.d / 'RomFS.img', self.d / 'app'; app.mkdir()
        self.put(self.d / 'real.img', b'image', 10**18); src.symlink_to(self.d / 'real.img')
        self.put(app / 'romfs.img', b'old', 10**18)
        self.assertEqual(self.sync(src, app), ['rsync']); self.assertEqual(self.state(app / 'romfs.img'), ('link', str(self.d / 'real.img')))

    def test_same_file_as_rsync_alone(self):   # random histories, side by side: the default and DM_ROMFS_CLONE=0 (rsync whenever the app has an image, as before) leave the same file
        rng = random.Random(1)
        src = self.d / 'RomFS.img'
        T = 1_700_000_000 * 10**9
        used = set()
        for case in range(40):
            apps = [self.d / f'a{case}', self.d / f'b{case}']
            for a in apps: a.mkdir()
            for step in range(4):
                data = rng.choice([b'', b'aaaa', b'bbbb', b'cccccc', bytes(rng.randrange(256) for _ in range(rng.randrange(1, 64)))])
                mtime = T + rng.choice([0, 0, 10**9, 2 * 10**9]) + rng.choice([0, 0, 300_000_000])
                self.put(src, data, mtime, rng.choice([0o644, 0o600, 0o755]))
                if rng.random() < 0.2:   # the app's copy touched since (another size or time), or a link where the image was
                    for a in apps:
                        if (a / 'romfs.img').exists(): os.utime(a / 'romfs.img', ns=(mtime + 5 * 10**9, mtime + 5 * 10**9))
                tools = [self.sync(src, apps[0]), self.sync(src, apps[1], DM_ROMFS_CLONE='0')]
                used.add(tools[0][0])
                self.assertEqual(self.state(apps[0] / 'romfs.img'), self.state(apps[1] / 'romfs.img'), (case, step, tools))
                self.assertEqual(sorted(p.name for p in apps[0].iterdir()), ['romfs.img'])
        self.assertEqual(used, {'cp', 'rsync'})   # both ways were taken


if __name__ == '__main__':
    unittest.main()
