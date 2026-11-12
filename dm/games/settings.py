#!/usr/bin/env python3
# The iOS launcher's settings for one game, from settings.tsv (its header describes the columns): the rows whose condition holds for the game, with the game's defaults, as JSON.
# build_ipa.sh writes it into the app as dm/launcher.json; Launcher.swift draws the screen from it (an app without the file starts the game at once).
# Usage: settings.py <game id> <rewritten modules dir> <control.nacp> <out.json>   (DM_GAMES_DIR finds provisional profiles, as in game.py; build:<VAR> defaults come from the environment;
#   GFXAPI is the packer's graphics API, SETTINGS_PLATFORM the app's platform: ios (default) or mac, whose launcher is the Mac front end)
import json, os, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'tools'))
import game, nacp

SECTIONS = ('Game', 'Controls', 'Performance')   # headings on the single settings screen
SCHEMA = 1   # launcher.json's version (docs/launcher.schema.json); it grows only by optional fields, so a reader of 1 reads every 1
# The meta column's keys, each with the pattern its value must match. A key is added here, in docs/frontends.md and in
# docs/launcher.schema.json together (test_launcher_settings.py checks that the three agree); a reader ignores keys it does not know
META = {
    'level': r'basic',                       # a setting a front end shows first; without it, the front end decides
    'needs': r'DM_[A-Z0-9_]+=[^;=]+',        # <VAR>=<value>: a sub-setting, drawn only while the row that sets <VAR> has that value
    'inactive': r'[^;|~]+~[^;|~]+(\|[^;|~]+~[^;|~]+)*',   # <rule>|<rule>: the row (or one option) is drawn greyed, with the rule's reason as its note, while a rule holds
    'hint': r'[^;|~]+~[^;|~]+(\|[^;|~]+~[^;|~]+)*',       # <rule>|<rule>: the row stays selectable and shows the rule's reason as its note while a rule holds
    'hide': r'[^;|~]+(\|[^;|~]+)*',                       # <when>|<when>: the row is not drawn on a device where one holds (device terms only)
    'shows': r'[^;|~:]+:[^;|~]+(\|[^;|~:]+:[^;|~]+)*',     # <value>:<when>|...: while the row is greyed by a whole-row inactive rule with that <when>, it shows <value> (what the host uses then) in place of its saved choice
    'preset': r'[a-z]+:[^,;:=|~]+(,[a-z]+:[^,;:=|~]+)*',   # <preset>:<value>,...: the value the row takes in a preset (PRESETS), def for its default; a preset it does not name keeps the default
}
RULE_KEYS = ('inactive', 'hint', 'hide', 'shows')
# The launcher's presets besides Balanced, which is the tested defaults (Reset): a front end shows them as one choice over the rows that have a preset (frame rate, resolution,
# upscaling, anti-aliasing). Applying one sets each such row to its preset value, except a row an env file or the launch sets, a row a rule greys and an option a rule greys
PRESETS = ('battery', 'quality')
# A rule is [<option>:]<when>~<why>, and <when> is terms joined by &, all of which must hold. A front end evaluates two kinds of term on the device:
# - <VAR>=<v>/<v> or <VAR>!=<v>/<v>: another row's current value (a range compares as a number), or the environment for a switch no row sets (ENV_ONLY); false when neither has it
# - DEVICE_TERMS: what the device, its screen or the app has
# A third kind, the shown column's terms (PACK_TERM, ! to negate, / for any of several), settings.py decides when the app is packed: a rule whose pack terms fail is left out of
# the list, and the others go out without them. So a rule that depends on what the game has (MetalFX greyed under Stretch: a game without Picture shape keeps the 16:9
# picture, one with it stretches it only where the shape chosen differs from the window's by 1 % or more, nvn_mtl.m fx_why) is a few rules in the table rather than a column per game
# A shows rule is <value>:<when> with no reason: while it holds the row shows <value>, the value the host uses then (Ultrawide holds Picture at Stretch, front_ios.m startGame),
# instead of the player's saved choice, which stays and comes back when the rule stops holding. It needs a whole-row inactive rule with the same terms, so the row it
# changes is always greyed and a pick never meets a value it cannot change. Other rows' rules still test the saved value (LauncherModel.holds)
DEVICE_TERMS = (r'device:(iphone|ipad|mac)(/(iphone|ipad|mac))*',   # the kind of device the app runs on
                r'(screen|window)(<|>=)\d+(\.\d+)?',               # the long side over the short side of the window's screen (front_ios.m's Ultrawide test) or of the app's window (Match screen's)
                r'hz(<|>=)\d+',                                    # the highest refresh rate of the connected screens (hle_nvn.c's 120 fps test)
                r'haptics:none',                                   # no haptic engine in the device (CHHapticEngine supportsHaptics, as haptics_apple.m and DmGamepad.m test it)
                r'controller:none',                                # no game controller connected now
                r'tv:none',                                        # no external display (a TV) connected now: front_ios.m shows the picture there, whole, when one is
                r'mfx:none',                                       # no Metal 4 MetalFX spatial scaler (nvn_mtl.m's test before it upscales)
                r'capture:on')                                     # GPU capture: Metal's capture layer loaded, or an app built for capture (MetalCaptureEnabled), nvn_mtl.m's capture profile
PACK_TERM = r'!?(fixups|mods|gfxapi|platform):[\w-]+(/[\w-]+)*|DM_GAME_\w+(==|!=)[^&]*'
VAR_TERM = r'([A-Z][A-Z0-9_]*)(!=|=)([^&=/!]+(/[^&=/!]+)*)'
# Switches a rule may test that no row sets, as the host reads them from the environment (an env file or the launch environment), each with the values a rule may name; None takes
# only *, which holds while the switch is set to anything (DM_GPU_CAPTURE runs nvn_mtl.m's capture profile, which opens no pipeline archive: the prebuild has none to build into; the
# capture layer itself, whichever variable or Info.plist key loads it, is the device term capture:on)
ENV_ONLY = {'DM_PAD_MERGE': {'0', '1'}, 'DM_GPU_CAPTURE': None}
# Values the host takes as another value of the row (nvn_upscale_pick.h up_parse: 1 is metalfx, 0 off). A term naming one goes out with its aliases, so a front end whose value
# came from an env file in the other spelling still matches
ALIASES = {'DM_PRESENT_UPSCALE': {'metalfx': ('1',), 'off': ('0',)}}
WHY_MAX = 60   # a reason is a note under the row and a subtitle in the in-game menu: one short line


def meta(text, n):
    """The meta column as {key: value}: key=value pairs separated by ;, each key from META once, its value matching its pattern"""
    out = {}
    for pair in filter(None, (p.strip() for p in text.split(';'))):
        key, eq, value = pair.partition('=')
        if not eq or key not in META: sys.exit(f'settings.tsv:{n}: unknown meta key {pair!r} (keys: {", ".join(META)})')
        if key in out: sys.exit(f'settings.tsv:{n}: meta key {key} given twice')
        if not re.fullmatch(META[key], value): sys.exit(f'settings.tsv:{n}: meta {key}={value!r} does not match {META[key]}')
        out[key] = value
    return out


def rules(key, text, n, var, table):
    """inactive, hint, hide or shows's value as [(option or None, [term, ...], why or None)], checked against the whole table (as needs is: a rule on a row this game
    does not list is still checked). table is {variable: (kind, values)} for every row. A shows rule's option is the value the row shows, and it has no reason"""
    out = []
    for part in text.split('|'):
        if key == 'shows' and '~' in part: sys.exit(f'settings.tsv:{n}: shows takes no reason (the row\'s inactive rule gives it): {part}')
        head, _, why = part.partition('~') if key not in ('hide', 'shows') else (part, '', None)
        why = why.strip() if why is not None else None
        if why is not None and not why: sys.exit(f'settings.tsv:{n}: {key} rule without a reason after ~: {part}')
        if why and len(why) > WHY_MAX: sys.exit(f'settings.tsv:{n}: {key} reason longer than {WHY_MAX} characters: {why}')
        option, terms = None, head.strip().split('&')
        first, colon, rest = terms[0].partition(':')
        if colon and not re.fullmatch(PACK_TERM, terms[0]) and not any(re.fullmatch(t, terms[0]) for t in DEVICE_TERMS):   # <option>:<term>
            if key == 'hide': sys.exit(f'settings.tsv:{n}: hide is for the whole row, not one option: {part}')
            kind, values = table[var]
            can = takes(kind, values)
            if can is None: sys.exit(f'settings.tsv:{n}: {key} names an option, which a {kind} row does not have: {part}')
            if first not in can: sys.exit(f'settings.tsv:{n}: {key} names an option {var} does not have: {first} (it has {", ".join(sorted(can))})')
            option, terms[0] = first, rest
        if key == 'shows' and option is None: sys.exit(f'settings.tsv:{n}: shows names the value the row shows first, <value>:<when>: {part}')
        device = False
        for t in terms:
            if re.fullmatch(PACK_TERM, t): continue
            if any(re.fullmatch(d, t) for d in DEVICE_TERMS): device = True; continue
            m = re.fullmatch(VAR_TERM, t)
            if not m: sys.exit(f'settings.tsv:{n}: unknown {key} term {t!r} (<VAR>=<value>, <VAR>!=<value>, a device term or a shown-column term)')
            if key == 'hide': sys.exit(f'settings.tsv:{n}: hide takes device terms, not settings ({t}): a row drawn only with another\'s value is needs')
            check_value(m[1], m[3].split('/'), n, key, table)
        if key == 'hide' and not device: sys.exit(f'settings.tsv:{n}: hide needs a device term: {part}')
        if not any(not re.fullmatch(PACK_TERM, t) for t in terms): sys.exit(f'settings.tsv:{n}: {key} rule with only pack-time terms: that is the shown column\'s job: {part}')
        out.append((option, terms, why))
    return out


def presets(text, n, var, table):
    """preset's value as {preset: value}, def for the row's default, each value one the row's variable takes (checked against the whole table, as rules are)"""
    out = {}
    kind, values = table[var]
    for part in text.split(','):
        name, _, v = part.partition(':')
        if name not in PRESETS: sys.exit(f'settings.tsv:{n}: unknown preset {name!r} (presets: {", ".join(PRESETS)}; balanced is the defaults)')
        if name in out: sys.exit(f'settings.tsv:{n}: preset {name} given twice')
        if v != 'def':
            if kind == 'range':
                lo, hi, _ = (float(x) for x in values.split(':'))
                try: f = float(v)
                except ValueError: sys.exit(f'settings.tsv:{n}: preset {name} sets the range {var} to {v}, not a number')
                if not lo <= f <= hi: sys.exit(f'settings.tsv:{n}: preset {name} sets {var} to {v}, which it never takes (it takes {lo:g} to {hi:g})')
            else:
                can = takes(kind, values)
                if can is None: sys.exit(f'settings.tsv:{n}: preset {name} on {var}, whose values are the game\'s: only def')
                if v not in can: sys.exit(f'settings.tsv:{n}: preset {name} sets {var} to {v}, which it never takes (it takes {", ".join(sorted(can))})')
        out[name] = v
    return out


def check_value(name, wanted, n, key, table):   # a term's variable is a row or an environment-only switch, and each value one it takes
    if name.startswith('DM_GAME_'): sys.exit(f'settings.tsv:{n}: {key} tests the profile macro {name} with ==, not =')
    if name in table:
        kind, values = table[name]
        if kind == 'range':
            lo, hi, _ = (float(x) for x in values.split(':'))
            for v in wanted:
                try: f = float(v)
                except ValueError: sys.exit(f'settings.tsv:{n}: {key} compares the range {name} with {v}, not a number')
                if not lo <= f <= hi: sys.exit(f'settings.tsv:{n}: {key} names a value {name} never takes: {v} (it takes {lo:g} to {hi:g})')
            return
        can = takes(kind, values)
    elif name in ENV_ONLY:
        can = ENV_ONLY[name]
        if can is None:
            if wanted != ['*']: sys.exit(f'settings.tsv:{n}: {key} tests {name} only as set: {name}=*')
            return
    else: sys.exit(f'settings.tsv:{n}: {key} names a variable no row sets and no known environment switch: {name} (those: {", ".join(ENV_ONLY)})')
    for v in wanted:
        if can is not None and v not in can: sys.exit(f'settings.tsv:{n}: {key} names a value {name} never takes: {v} (it takes {", ".join(sorted(can))})')


def takes(kind, values):   # the values a row's variable can take, for needs and rules; None when any (a range, the game's languages)
    if kind == 'toggle': return {'1', '0'} if values == '-' else set(values.split('/'))
    if kind == 'choice' and values != 'languages': return {v.split('?', 1)[0].split('=', 1)[0] for v in values.split(',')}
    return None


def greying_cycle(table_rules):
    """A row greyed by another row's value that is itself greyed by the first (directly or through others) could leave the player unable to change either: the rows
    each inactive rule reads, followed until one comes back. table_rules is {variable: [(option, terms, why), ...]}; returns the cycle as a list, or None"""
    reads = {v: {m[1] for _, terms, _ in rs for t in terms if (m := re.fullmatch(VAR_TERM, t)) and m[1] in table_rules} for v, rs in table_rules.items()}
    state = {}
    def walk(v, path):
        if state.get(v) == 1: return path[path.index(v):] + [v]
        if state.get(v) == 2: return None
        state[v] = 1
        for w in sorted(reads.get(v, ())):
            c = walk(w, path + [v])
            if c: return c
        state[v] = 2
        return None
    for v in sorted(reads):
        c = walk(v, [])
        if c: return c
    return None


def render_base(g):
    """The profile's render_base ("<w>x<h> <w>x<h>": the 3D views' base size docked, then handheld, which DM_RENDER_SCALE scales) as
    {"docked": [w, h], "handheld": [w, h]}, for a front end to show the render scale in pixels; None when the profile has none"""
    v = g.get('render_base', '')
    if not v: return None
    m = re.fullmatch(r'\s*(\d+)x(\d+)\s+(\d+)x(\d+)\s*', v)
    if not m: sys.exit(f'{g.id}: render_base is "<w>x<h> <w>x<h>" (docked, then handheld): {v}')
    return {'docked': [int(m[1]), int(m[2])], 'handheld': [int(m[3]), int(m[4])]}


def rows():
    for n, line in enumerate((HERE / 'settings.tsv').read_text(encoding='utf-8').splitlines(), 1):
        if not line.strip() or line.startswith('#'): continue
        c = line.split('\t')
        if len(c) not in (7, 8, 9): sys.exit(f'settings.tsv:{n}: 7 to 9 columns expected, {len(c)} found')
        if c[5] not in SECTIONS: sys.exit(f'settings.tsv:{n}: unknown section: {c[5]}')
        yield n, c + [''] * (9 - len(c))


def fixups_keys(path):   # '# KEY<TAB>value' header rows of a rewriter table, as {KEY: value}
    if not path.is_file(): return {}
    return {m[1]: m[2].strip() for m in re.finditer(r'^# (\w+)\t(.*)$', path.read_text(encoding='utf-8'), re.M)}


UNKNOWN_LANGUAGES = 'This game\'s files do not list its languages, so some of these may not be in the game. It may then show another one.'


def build(gid, patched, control):
    platform = os.environ.get('SETTINGS_PLATFORM') or 'ios'
    if platform not in ('ios', 'mac'): sys.exit(f'SETTINGS_PLATFORM must be ios or mac: {platform}')
    g = game.load(gid)
    macros = dict(re.findall(r'^#define (DM_GAME_\w+) (.*)$', game.header_one(g), re.M))   # the host's own defaults, as it is compiled for this game
    keys = fixups_keys(Path(patched) / 'main.fixups.tsv')
    mods_tsv = Path(patched) / 'mods.tsv'   # the switchable mods the NSP script packed (build_variants): a role per row
    mod_roles = {l.split('\t')[0] for l in mods_tsv.read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')} if mods_tsv.is_file() else set()
    have = nacp.languages(control)
    langs = [(c, n) for c, n in nacp.LANGUAGES if not have or c in have]   # no list (a dump or a NUP has no control data, none of its packages may): any language may be the game's, as DM_LANG and the NSP script's check take it

    def macro(name, n):
        if name not in macros: sys.exit(f'settings.tsv:{n}: no {name} in the game profile header (game.py header)')
        return macros[name].strip('"')

    def shown(cond, n):
        if '&' in cond: return all(shown(c, n) for c in cond.split('&'))   # every one of them
        if cond == 'always': return True
        if cond.startswith('mods:'): return cond[5:] in mod_roles
        if cond == 'languages>1': return len(langs) > 1
        if cond.startswith('fixups:'): return cond[7:] in keys
        if cond.startswith('gfxapi:'): return os.environ.get('GFXAPI', '') == cond[7:]
        if cond.startswith('platform:'): return platform == cond[9:]
        m = re.fullmatch(r'(DM_GAME_\w+)(!=|==)(.*)', cond)
        if m: return (macro(m[1], n) == m[3]) == (m[2] == '==')
        sys.exit(f'settings.tsv:{n}: unknown condition {cond}')

    def value(d, n):
        if '|' in d:
            parts = d.split('|')
            if len(parts) != 2 or not all(parts): sys.exit(f'settings.tsv:{n}: platform default is <ios>|<mac>: {d}')
            d = parts[0] if platform == 'ios' else parts[1]
        if d.startswith('DM_GAME_'): return macro(d, n)
        if d.startswith('build:'):
            v = os.environ.get(d[6:], '')
            return {'YES': '1', 'NO': '0', '': '0'}.get(v, v)   # build_ipa.sh's yes / no switches
        return d

    def offered(v, n):   # value=label?cond&cond: an option only some games or platforms have
        parts = v.split('?', 1)
        return len(parts) == 1 or all(shown(c, n) for c in parts[1].split('&'))

    def pack(term, n):   # a rule's pack-time term: the shown column's condition, ! negating it, / for any of several values
        if term.startswith('DM_GAME_'): return shown(term, n)
        neg, term = term.startswith('!'), term.lstrip('!')
        kind, _, values = term.partition(':')
        return any(shown(f'{kind}:{v}', n) for v in values.split('/')) != neg

    def resolve(rs, listed, opts, n):   # a row's rules for this game: pack terms decided, rules on settings it does not list or options it does not offer left out
        out = []
        for option, terms, why in rs:
            if option is not None and opts is not None and option not in opts: continue
            when, holds = [], True
            for t in terms:
                if re.fullmatch(PACK_TERM, t): holds = holds and pack(t, n); continue
                m = re.fullmatch(VAR_TERM, t)
                if m and m[1] not in listed and m[1] not in ENV_ONLY: holds = False   # a setting this game's list does not have: the rule can never hold
                if m and m[1] in ALIASES:
                    vals = m[3].split('/'); vals += [a for v in vals for a in ALIASES[m[1]].get(v, ()) if a not in vals]
                    t = f'{m[1]}{m[2]}{"/".join(vals)}'
                when.append(t)
            if holds: out.append({**({'option': option} if option is not None else {}), 'when': when, **({'why': why} if why is not None else {})})
        return out

    out, base = [], render_base(g)
    table = {r[1][0]: (r[1][1], r[1][2]) for r in rows()}
    listed = {var for n, (var, kind, values, default, cond, *_) in rows() if shown(cond, n)}
    inactive = {}   # every row's inactive rules, this game's or not, for the greying cycle check
    for n, (var, kind, values, default, cond, section, label, note, extra) in rows():
        m = meta(extra, n)
        if 'needs' in m:
            need, want = m['needs'].split('=', 1)
            if need not in table: sys.exit(f'settings.tsv:{n}: needs names a variable no row sets: {m["needs"]}')
            can = takes(*table[need])
            if can is not None and want not in can: sys.exit(f'settings.tsv:{n}: needs a value {need} never takes: {want} (it takes {", ".join(sorted(can))})')
        parsed = {k: rules(k, m.pop(k), n, var, table) for k in RULE_KEYS if k in m}
        for _, terms, _ in parsed.get('shows', []):   # the row shows another value only while it is greyed, so the player never sees a value that a pick could not change
            if not any(o is None and t == terms for o, t, _ in parsed.get('inactive', [])):
                sys.exit(f'settings.tsv:{n}: a shows rule needs a whole-row inactive rule with the same terms, so the row is greyed while it shows the value: {"&".join(terms)}')
        preset = presets(m.pop('preset'), n, var, table) if 'preset' in m else None
        inactive[var] = parsed.get('inactive', [])
        if not shown(cond, n): continue
        s = {'env': var, 'kind': kind, 'section': section, 'label': label, 'note': note, 'default': value(default, n), **m}
        if var == 'DM_RENDER_SCALE' and base: s['base'] = base   # the render scale in pixels, for the console mode chosen
        if kind == 'choice':
            opts = [list(l) for l in langs] if values == 'languages' else [v.split('?', 1)[0].split('=', 1) for v in values.split(',') if offered(v, n)]
            if any(len(o) != 2 for o in opts): sys.exit(f'settings.tsv:{n}: choice values are value=label,...')
            if s['default'] not in [o[0] for o in opts]: s['default'] = opts[0][0]   # a default the game does not offer (a language it lacks): its first
            s['options'] = opts
            if values == 'languages' and not have: s['note'] = UNKNOWN_LANGUAGES
        elif kind == 'range':
            lo, hi, st = (float(x) for x in values.split(':'))
            if var == 'DM_RENDER_SCALE' and keys.get('RENDER_SCALE', '1') != '1':   # a stub that also raises the size: up to its largest scale (the rewriter's RENDER_SCALE, hex as every header value)
                hi = float(int(keys['RENDER_SCALE'], 16))
            s.update(min=lo, max=hi, step=st)
        elif kind == 'toggle':
            if s['default'] not in ('0', '1'): sys.exit(f'settings.tsv:{n}: a toggle defaults to 0 or 1: {s["default"]}')
            on_off = ['1', '0'] if values == '-' else values.split('/')
            if len(on_off) != 2 or not all(on_off) or on_off[0] == on_off[1]: sys.exit(f'settings.tsv:{n}: toggle values are - or <on>/<off>: {values}')
            s.update(on=on_off[0], off=on_off[1], default=on_off[0] if s['default'] == '1' else on_off[1])   # the default as the value the variable takes
        else: sys.exit(f'settings.tsv:{n}: unknown kind {kind}')
        opts = [o[0] for o in s['options']] if kind == 'choice' else None
        if preset is not None:   # every preset, def resolved to this game's default; an option this game does not offer: its default too
            s['preset'] = {p: s['default'] if (v := preset.get(p, 'def')) == 'def' or (opts is not None and v not in opts) else v for p in PRESETS}
        for k, rs in parsed.items():
            r = resolve(rs, listed, opts, n)
            if r: s[k] = r
        out.append(s)
    cycle = greying_cycle(inactive)
    if cycle: sys.exit(f'settings.tsv: inactive rules grey each other in a cycle, which could leave the player unable to change any of them: {" → ".join(cycle)}')
    # Below 100 % the render scale fixes the 3D views' size, which a game's own dynamic resolution would otherwise change (loader.c dm_fps_state_apply): no game has both rows
    # today, and one that does needs a rule saying which of them wins before the player sees two settings that fight
    envs = {s['env']: s for s in out}
    if {'DM_DYNAMIC_RESOLUTION', 'DM_RENDER_SCALE'} <= set(envs):
        def reads(a): return {m[1] for k in ('inactive', 'hint') for r in envs[a].get(k, ()) for t in r['when'] if (m := re.fullmatch(VAR_TERM, t))}
        linked = 'DM_RENDER_SCALE' in reads('DM_DYNAMIC_RESOLUTION') or 'DM_DYNAMIC_RESOLUTION' in reads('DM_RENDER_SCALE')
        if not linked: sys.exit(f'{g.id}: the game has both Dynamic resolution and Render scale, and below 100 % the render scale overrides the dynamic resolution: '
                                'give one of the two rows an inactive or hint rule on the other in settings.tsv')
    return {'schema': SCHEMA, 'game': g.id, 'console': console(g.id, patched), 'settings': out}


def console(gid, patched):
    """'switch2' for a game built for the Switch 2, else 'switch1', for the launcher's line under the game's name: the rewritten sdk module's build spec ("spec: Ounce",
    loader.c dm_sdk_ounce, profile_guess.py), else the title ID (Switch 2 titles are 04...)"""
    sdk = next(iter(sorted(Path(patched).glob('sdk*.bin'))), None)
    if sdk is not None and b'spec: Ounce' in sdk.read_bytes(): return 'switch2'
    return 'switch2' if sdk is None and gid.upper().startswith('04') else 'switch1'


if __name__ == '__main__':
    if len(sys.argv) != 5: sys.exit('usage: settings.py <game id> <rewritten modules dir> <control.nacp> <out.json>')
    d = build(*sys.argv[1:4])
    Path(sys.argv[4]).write_text(json.dumps(d, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
    print(' '.join(s['env'] for s in d['settings']))
