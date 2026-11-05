#!/usr/bin/env python3
# What lets a repeat IPA build of the same game reuse Xcode's work (build_ipa.sh, DM_GEN_REUSE): Xcode's build system decides what to build again by the size and modification time of each
# input (Swift Build's default file system mode ignores device and inode, so the derived data the NSP script keeps as one tar, dm/tools/tree_tar.py, still builds incrementally), and
# build_ipa.sh used to delete Gen/ and write every file again, so Xcode assembled embed.S (the .incbin of every rewritten module), linked, ran actool and copied the tables on every build.
#   sync <stage> <gen> [--keep <name>]...   mirror the folder <stage> (this run's complete generation) into <gen>: a file whose bytes are the same and a symlink with the same target stay
#                                            as they are (their inode and times too), any other entry is replaced by this run's, entries this run did not make are deleted (except the
#                                            top-level names --keep names), folders are made as needed; <stage> is deleted at the end. Prints one summary line
#   digest [item]...                         print a sha256 over the items, in order: --text <s>, --file <path> (its bytes; a missing file counts as such), --tree <dir> (every entry's path,
#                                            kind, mode and bytes or link target), --list <dir> (paths and kinds only), --stat <dir> (paths, kinds, modes, sizes, modification times and inodes:
#                                            whether anything there was touched), --env-of <file> (the value of every ${NAME} the file names, from the environment); --skip <path> leaves a
#                                            path and what is below it out of every walk, --shallow <path> lists a folder but not what is in it
#   copy-app <app> <dest> [--skip <name>]... a copy of the app folder <app> at <dest> (which is deleted first), without the top-level entries named: an APFS clone (clonefile) where the volume
#                                            can, which takes no space and no time, else an ordinary copy. Extended attributes are not copied by the ordinary copy (on exFAT they would become ._ files)
# The digest of a walk sorts the entries by path; a symlink is never followed below the walk's own root
import ctypes, hashlib, os, re, shutil, stat, sys

CHUNK = 1 << 20


def die(msg): sys.exit(f'gen_reuse.py: {msg}')


def same_bytes(a, b, size):
    with open(a, 'rb') as fa, open(b, 'rb') as fb:
        while size > 0:
            x, y = fa.read(CHUNK), fb.read(CHUNK)
            if x != y: return False
            if not x: return True
            size -= len(x)
    return True


def remove(p):
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p)
    else: os.unlink(p)


def sync(stage, gen, keep):
    n = {'kept': 0, 'written': 0, 'removed': 0}
    def mirror(src, dst, top):
        if os.path.lexists(dst) and not (os.path.isdir(dst) and not os.path.islink(dst)): remove(dst); n['removed'] += 1
        if not os.path.lexists(dst): os.mkdir(dst)
        names = sorted(os.listdir(src))
        for name in names:
            s, d = os.path.join(src, name), os.path.join(dst, name)
            st = os.lstat(s)
            try: dt = os.lstat(d)
            except FileNotFoundError: dt = None
            if stat.S_ISDIR(st.st_mode):
                mirror(s, d, False)
                if dt is None or stat.S_IMODE(dt.st_mode) != stat.S_IMODE(st.st_mode): os.chmod(d, stat.S_IMODE(st.st_mode))
            elif stat.S_ISLNK(st.st_mode):
                if dt is not None and stat.S_ISLNK(dt.st_mode) and os.readlink(d) == os.readlink(s): n['kept'] += 1; continue
                if dt is not None and stat.S_ISDIR(dt.st_mode): shutil.rmtree(d)
                os.replace(s, d); n['written'] += 1   # the link itself moves
            elif stat.S_ISREG(st.st_mode):
                if dt is not None and stat.S_ISREG(dt.st_mode) and dt.st_size == st.st_size and same_bytes(s, d, st.st_size):
                    if stat.S_IMODE(dt.st_mode) != stat.S_IMODE(st.st_mode): os.chmod(d, stat.S_IMODE(st.st_mode))   # the ctime only: Xcode goes by size and modification time
                    n['kept'] += 1; continue
                if dt is not None and stat.S_ISDIR(dt.st_mode): shutil.rmtree(d)
                os.replace(s, d); n['written'] += 1
            else: die(f'neither a file, a folder nor a symlink: {s}')
        wanted = set(names) | (keep if top else set())
        for name in sorted(os.listdir(dst)):
            if name not in wanted: remove(os.path.join(dst, name)); n['removed'] += 1
    stage, gen = os.path.normpath(stage), os.path.normpath(gen)
    if not os.path.isdir(stage) or os.path.islink(stage): die(f'no folder {stage}')
    if os.path.dirname(stage) == gen: keep = keep | {os.path.basename(stage)}   # a stage inside the folder it is mirrored into (build_ipa.sh: Gen/.stage)
    mirror(stage, gen, True)
    shutil.rmtree(stage)
    print(f'{n["kept"]} kept, {n["written"]} written, {n["removed"]} removed')


def file_sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(CHUNK), b''): h.update(b)
    return h.hexdigest()


def walk(root, skip, shallow):   # (path relative to root, lstat) of every entry below root, sorted, without the skipped paths; below a shallow folder nothing
    out = []
    def go(d, rel):
        try: names = sorted(os.listdir(d))
        except FileNotFoundError: return
        for name in names:
            p, r = os.path.join(d, name), f'{rel}{name}'
            if os.path.normpath(p) in skip: continue
            st = os.lstat(p); out.append((r, p, st))
            if stat.S_ISDIR(st.st_mode) and os.path.normpath(p) not in shallow: go(p, r + '/')
    go(root, '')
    return out


def kind(st):
    return 'd' if stat.S_ISDIR(st.st_mode) else 'l' if stat.S_ISLNK(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else 'o'


def digest(argv):
    items, skip, shallow, i = [], set(), set(), 0
    while i < len(argv):
        opt = argv[i]
        if i + 1 >= len(argv): die(f'{opt} needs a value')
        val = argv[i + 1]; i += 2
        if opt == '--skip': skip.add(os.path.normpath(val))
        elif opt == '--shallow': shallow.add(os.path.normpath(val))
        elif opt in ('--text', '--file', '--tree', '--list', '--stat', '--env-of'): items.append((opt, val))
        else: die(f'unknown item {opt}')
    h = hashlib.sha256()
    def put(*parts): h.update(('\0'.join(str(p) for p in parts) + '\n').encode('utf-8', 'surrogateescape'))
    for opt, val in items:
        put(opt, val)
        if opt == '--text': continue
        if opt == '--file':
            put(file_sha(val) if os.path.isfile(val) else 'missing'); continue
        if opt == '--env-of':
            text = open(val, encoding='utf-8', errors='surrogateescape').read() if os.path.isfile(val) else ''
            for name in sorted(set(re.findall(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', text))): put(name, 'set' if name in os.environ else 'unset', os.environ.get(name, ''))
            continue
        if not os.path.isdir(val): put('missing'); continue
        for rel, p, st in walk(val, skip, shallow):
            k = kind(st)
            if opt == '--list': put(rel, 'd' if k == 'd' or (k == 'l' and os.path.isdir(p)) else 'f'); continue
            mode = stat.S_IMODE(st.st_mode)
            if opt == '--stat': put(rel, k, mode, st.st_size, st.st_mtime_ns, st.st_ino, os.readlink(p) if k == 'l' else ''); continue
            put(rel, k, mode, os.readlink(p) if k == 'l' else file_sha(p) if k == 'f' else '')
    print(h.hexdigest())


def clonefile():   # the macOS system call (sys/clonefile.h, macOS 10.12): int clonefile(const char *src, const char *dst, uint32_t flags); None where it does not exist
    try: f = ctypes.CDLL(None, use_errno=True).clonefile
    except (AttributeError, OSError): return None
    f.argtypes, f.restype = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32), ctypes.c_int
    return f


CLONE_NOFOLLOW = 0x0001   # a symlink is cloned as the link


def copy_app(app, dest, skip):
    if not os.path.isdir(app): die(f'no app folder {app}')
    if os.path.lexists(dest): remove(dest)
    os.makedirs(dest)
    clone = clonefile()
    for name in sorted(os.listdir(app)):
        if name in skip: continue
        s, d = os.path.join(app, name), os.path.join(dest, name)
        if clone and clone(os.fsencode(s), os.fsencode(d), CLONE_NOFOLLOW) == 0: continue
        if os.path.lexists(d): remove(d)   # what a clone that failed half way left
        if os.path.islink(s): os.symlink(os.readlink(s), d)
        elif os.path.isdir(s): shutil.copytree(s, d, symlinks=True)
        else: shutil.copy2(s, d, follow_symlinks=False)
    shutil.copystat(app, dest)


def main(argv):
    if not argv: die('usage: gen_reuse.py sync <stage> <gen> [--keep <name>]... | digest [item]... | copy-app <app> <dest> [--skip <name>]...')
    cmd, rest = argv[0], argv[1:]
    def names(args, flag):
        out, i = set(), 0
        while i < len(args):
            if args[i] != flag or i + 1 >= len(args): die(f'expected {flag} <name>: {args[i]}')
            out.add(args[i + 1]); i += 2
        return out
    if cmd == 'sync' and len(rest) >= 2: sync(rest[0], rest[1], names(rest[2:], '--keep'))
    elif cmd == 'digest': digest(rest)
    elif cmd == 'copy-app' and len(rest) >= 2: copy_app(rest[0], rest[1], names(rest[2:], '--skip'))
    else: die(f'unknown command or missing arguments: {" ".join(argv)}')


if __name__ == '__main__':
    main(sys.argv[1:])
