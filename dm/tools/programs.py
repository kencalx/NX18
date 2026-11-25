"""The programs of one application, by title ID: what scripts/pack_nup.py, pack_nx.py and pack_dump.py take for a game's code (docs/reference/packing.md, "A NUP holding
several programs of one application").

A multi-program application has one program per program index, its title ID the application's plus the index (1 to 0xFF): Super Mario 3D All-Stars (a launcher and one program per
game), ROMANCE OF THE THREE KINGDOMS 8 REMAKE (a second program in its update). A Nintendo Switch 2 Edition puts its Switch 2 program beside the Switch 1 game in the same way, as
program 1, whose title ID starts 04 where the application's starts 01 (Xenoblade Chronicles 2: 0100E95004038000 and 0400E95004038001, upstream PR #1253). So two IDs are programs
of one application when they differ only in the program index and that platform byte. The application's DLC are every program's: a program numbers them from the application,
as the game asks for them (index = DLC title ID - application - 0x1000), with the platform byte left out of the sum, so a Switch 2 Edition's program finds the 01 DLC.

Reading every program right is the pack scripts' own; building one is not: a program other than the application's own (program 0) builds only with the owner's developer switch on
(supported; dm/tools/nx18_dev.py, docs/development.md "The developer switch"), and stops otherwise with a red line that says it is not supported yet (unsupported)."""
import nx18_dev

PLATFORM = 0xFF << 56   # the title ID's top byte: 01 a Switch 1 title, 04 a Switch 2 one
LOW = 0xFFF   # a program index (…000-…0FF), an update (…800) or a DLC (…001 and up of the next 0x1000)
MAX_INDEX = 0xFF
MAX_DLC = 2000   # the highest DLC index the pack scripts take


def index(tid):
    """The program index of a title ID that names a program (0 for the application's own, 1 to 0xFF for its others), else None (an update's …800, other IDs)"""
    low = tid & LOW
    return low if low <= MAX_INDEX else None


def application(tid):   # the application of a program's title ID, without its platform byte: the same for every program of one application
    return tid & ~(PLATFORM | LOW)


def switch2(tid): return tid >> 56 == 0x04


def same_application(a, b): return index(a) is not None and index(b) is not None and application(a) == application(b)


def dlc_index(tid, app):
    """The index of DLC title ID tid of the game whose program is app (aoc/<index>.img, the index the game asks for), or None when it is not one of that application's DLC"""
    i = (tid & ~PLATFORM) - application(app) - 0x1000
    return i if 0 < i <= MAX_DLC else None


def edition(progs):
    """The index of a Nintendo Switch 2 Edition's Switch 2 program in {index: title ID}: the lowest program whose ID starts 04 when the lowest program's starts otherwise; else None"""
    first = min(progs)
    if switch2(progs[first]): return None
    return next((i for i in sorted(progs) if switch2(progs[i])), None)


def pick(progs, want=None, known=None):
    """The program to pack of {index: title ID}, the programs a container holds code of: want (an index; None when it is not there); else, of the Switch 2 Edition's Switch 2
    program and the lowest program (the application's own, program 0 when it is there), the first that known(title ID) says has a game profile; else the first of them.
    Returns (index, why): why says how the default chose, '' when there was nothing to choose"""
    if want is not None: return (want if want in progs else None), ''
    if len(progs) == 1: return next(iter(progs)), ''
    first, ed = min(progs), edition(progs)
    order = ([ed] if ed is not None else []) + [first]
    for i in order:
        if known is not None and known(progs[i]): return i, 'the one with a game profile'
    return order[0], ('the Nintendo Switch 2 Edition\'s Switch 2 program' if ed is not None else 'the application\'s own')


def supported(tid, dev=None):
    """Whether a build of program tid goes on: the application's own (program 0, a base game) always; another program (1 to 0xFF: a Nintendo Switch 2 Edition's Switch 2 program,
    a program packed alone) only with NX18_DEV on (owner's decision of 2026-11-13). dev: whether the switch is on, None to ask nx18_dev"""
    return index(tid) == 0 or (nx18_dev.on() if dev is None else bool(dev))


def unsupported(where, tid, progs=None):
    """The line a build stops with for a program supported refuses (the pack scripts print it red): what it is, that it is not supported yet, and the application's own program when
    the container holds it (progs: {index: title ID}). Player-facing: it never names the switch"""
    own = (progs or {}).get(0)
    return (f'{where}: {tid:016X} is program {index(tid)} of a multi-program application' + (', a Switch 2 program' if switch2(tid) else '')
            + '. This program isn\'t supported yet: NX 18 builds an application\'s own program (program 0)'
            + (f'; {where} holds it ({own:016X}): --program 0 / PROGRAM_INDEX = 0 builds that one' if own is not None else ''))


def listing(progs): return ', '.join(f'{i} ({progs[i]:016X}{", Switch 2" if switch2(progs[i]) else ""})' for i in sorted(progs))


def note(where, progs, i, why):
    """The line a pack script prints for the program it packs: which of several, and how another is chosen; a program packed alone says what its title ID does. None for a base game alone"""
    tid = progs[i]
    if len(progs) > 1:
        return (f'{where} holds {len(progs)} programs of application {progs[min(progs)] & ~LOW:016X}: {listing(progs)}. Packing program {i} ({tid:016X}'
                + (f', {why}' if why else '') + '); --program N packs another. Its title ID names the profile and the build folder; its DLC are the application\'s')
    if index(tid): return f'{where}: {tid:016X} is program {index(tid)} of an application: its title ID names the profile and the build folder; its DLC are the application\'s'
    return None
