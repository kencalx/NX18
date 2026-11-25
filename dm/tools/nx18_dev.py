#!/usr/bin/env python3
"""NX18_DEV: the owner's local developer switch for trying a game NX 18 has not been tested with (docs/development.md, "The developer switch"). It is never in player docs or help.

On when the environment variable NX18_DEV has a value other than 0, or, when the variable is unset or empty, when the file ~/NX18-work/NX18_DEV exists (its content does not matter):
NX Play and Beam, started from the Dock, do not see the shell's variables, so the file is how their builds turn it on. NX18_DEV=0 turns it off even with the file there.
What it changes, and nothing else:
  - scripts/pack_nup.py, pack_nx.py, pack_dump.py and the NSP script on a NUP, an NX or a dump folder: a program other than the application's own (program index 1 to 0xFF: a Nintendo
    Switch 2 Edition's Switch 2 program, or a program packed alone) is built; off, the build stops with a red line that says the program is not supported yet (dm/tools/programs.py
    supported / unsupported; the owner's decision of 2026-11-13). Which program is read and how, its DLC numbering and its art are the same with it and without it.
  - scripts/build_ipa_from_nsp.py: a cached provisional profile that describes other versions than the one selected is kept, and the selected version is surveyed into a profile
    folder of its own beside it (dev_profile_folder), instead of the build stopping.
  - dm/ios/tools/build_ipa.sh: compiles the app with DM_DEV_BUILD=1, so a player build (DM_PLAYER_BUILD=1, player_env.h) takes env.txt's DM_NVN_* and DM_SLOWFRAME lines too,
    and the app's log names a developer build.
  - The build log warns (WARNING) at the start and at the end.
Usage: nx18_dev.py   (exit 0 and the source on stdout when it is on, exit 1 when it is off)"""
import os
from pathlib import Path
import sys

NAME = 'NX18_DEV'
FILE = Path('NX18-work') / NAME   # under the home folder
WARNING = ('[RED] NX18_DEV is on ({source}): a developer build for trying an untested game; a program other than an application\'s own and a cached provisional profile '
           'of other versions do not stop this one, '
           'and an iPhone player build keeps the DM_NVN_* and DM_SLOWFRAME lines of env.txt. Not for players')


def source(env=None):
    """What turns it on: 'NX18_DEV=<value>' (the environment), the file's path, or None when it is off"""
    env = os.environ if env is None else env
    value = (env.get(NAME) or '').strip()
    if value: return None if value.strip('0') == '' else f'{NAME}={value}'
    home = env.get('HOME')
    path = (Path(home) if home else Path.home()) / FILE
    return str(path) if path.exists() else None


def on(env=None):
    return source(env) is not None


def warning(env=None):
    return WARNING.format(source=source(env) or 'off')


if __name__ == '__main__':
    s = source()
    if s: print(s)
    sys.exit(0 if s else 1)
