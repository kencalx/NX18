#!/usr/bin/env python3
# About this game's facts (NX18-X2.0 gate-ui.md §18.1, F9): dm/facts.json in the app, written at build beside about.json. Nothing online: the control data's age ratings,
# the profile's `tested` and `known_issue` keys (set after a device sitting), and each packed switchable mod's credit (an optional credit.json in the mod's folder:
# {"author", "link", "license"}). The app picks the rating body by the device's region and shows "No credit given in the mod's folder" for a mod without one.
# Usage: about_facts.py <control.nacp> <game profile folder> <out facts.json> [<mods root> <role>=<mod folder name> ...]
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nacp

ROLE_LABEL = {'fps': 'High frame rate', 'ultrawide': 'Ultrawide'}


def profile_key(game_dir, key):
    try:
        for line in (Path(game_dir) / 'game.tsv').read_text(encoding='utf-8').splitlines():
            c = line.split('\t')
            if c and c[0].strip() == key and len(c) > 1: return '\t'.join(v.strip() for v in c[1:]).strip()
    except OSError: pass
    return ''


def credit(folder):
    try: d = json.loads((Path(folder) / 'credit.json').read_text(encoding='utf-8'))
    except (OSError, ValueError): return None
    if not isinstance(d, dict): return None
    out = {k: str(d[k])[:200] for k in ('author', 'link', 'license') if isinstance(d.get(k), (str, int, float)) and str(d[k]).strip()}
    if 'link' in out and not out['link'].startswith(('https://', 'http://')): del out['link']   # only a web link is offered, opened when tapped
    return out or None


def facts(control, game_dir, mods_root=None, roles=None):
    f = {'ratings': nacp.ratings(control) if control else {}}
    tested, issue = profile_key(game_dir, 'tested'), profile_key(game_dir, 'known_issue')
    if tested: f['tested'] = tested
    if issue: f['known_issue'] = issue[:80]
    mods = []
    for role, name in sorted((roles or {}).items()):
        m = {'role': ROLE_LABEL.get(role, role), 'name': name}
        c = credit(Path(mods_root) / name) if mods_root else None
        if c: m.update(c)
        mods.append(m)
    if mods: f['mods'] = mods
    return f


def main(argv):
    if len(argv) < 3: sys.exit('usage: about_facts.py <control.nacp> <game profile folder> <out facts.json> [<mods root> <role>=<mod folder> ...]')
    control, game_dir, out = argv[0], argv[1], Path(argv[2])
    root = argv[3] if len(argv) > 3 else None
    roles = dict(a.split('=', 1) for a in argv[4:] if '=' in a)
    out.write_text(json.dumps(facts(control, game_dir, root, roles), ensure_ascii=False, indent=1) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main(sys.argv[1:])
