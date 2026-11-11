#!/usr/bin/env python3
# The launcher's key art and "About this game" text for one game, settled once per app in <build folder>/art/ (build_ipa_from_nsp.py calls settle(); run on its own, this script settles one game's art/ folder).
# The art, in this order: the player's own image (--art / ART), else online (ART_ONLINE): the game's banner in titledb, else a hero image from SteamGridDB when a key is set, else none (the launcher blurs the app icon).
#   With a key, SteamGridDB's game is looked up first: when it has both a hero (textless by design) and a logo, that pair is the art (art.jpg) and the logo (logo.png), as titledb's banner has the logo painted in.
# The logo (the game's title wordmark, a transparent PNG the launcher shows in place of the name): the player's own (--logo / LOGO), else SteamGridDB's with a key, which goes over a SteamGridDB hero or the
#   player's art but never over a titledb banner (two logos); a player's logo goes over whatever art there is. titledb has no logo. A logo that fails is a line, and the art falls back to the banner.
#   titledb: https://github.com/blawar/titledb's US.en.json (about 90 MB, keyed by nsuId), downloaded whole, so the list's host is sent no title ID, into CACHE_ROOT/titledb/; it is turned into a small index.json
#   ({TITLE ID: name, bannerUrl, screenshots, description, intro, publisher, releaseDate}) and the 90 MB file is deleted. The index is checked again when it is older than 14 days, with If-None-Match /
#   If-Modified-Since, so an unchanged list is not downloaded again. Its text is also the launcher's "About this game" (about.json), whatever the art came from.
#   SteamGridDB: only with a key (STEAMGRIDDB_KEY), which goes only into the Authorization header of SteamGridDB's API requests: never into a URL, a say line, art.json, argv or the environment
#   (the curl fallback reads it on stdin). The search term is the game's name. A key with characters an API key does not have (a pasted second line) is not used.
#   The image itself (titledb's banner on Nintendo's image server, SteamGridDB's hero on its CDN) does tell that host which game this is: it is fetched without the nxnative-build User-Agent.
# Writes in the art folder: art.jpg (JPEG, longest side at most 1920, made with sips), logo.png (PNG with its alpha, longest side at most 1200, made with sips), art.json (where they came from: source
#   given|titledb|steamgriddb or null, the image URL, "logo": {source given|steamgriddb or null, url}, the title ID, the name, when, and the inputs that decided them, so the next build reuses the folder
#   without the network and looks again when they change: --art or --logo given or not, a key newly set), about.json (titledb's text). Offline (ART_ONLINE off) nothing is downloaded at all; art and a logo
#   an earlier online build downloaded are still used (from an earlier --art or --logo they are not: without the option they are not wanted). When a new online lookup fails (the network is down), the art
#   and logo an earlier one downloaded stay.
# Nothing here stops a build: a network error, a timeout, bad JSON or a sips error is one say line, and the build goes on with what there is. Every request goes through fetch() (tests replace it).
# Usage: game_art.py <title ID in hex> <game name> <art folder> [--art IMAGE] [--logo IMAGE] [--offline]   (the key from the STEAMGRIDDB_KEY environment variable)
import argparse, http.client, json, os, re, ssl, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Callable, NamedTuple

CACHE_ROOT = Path.home() / 'Library/Caches/nxnative'   # the user's cache shared by all builds; titledb's index is in CACHE_ROOT/titledb/
TITLEDB_URL = 'https://raw.githubusercontent.com/blawar/titledb/master/US.en.json'
STEAMGRIDDB_API = 'https://www.steamgriddb.com/api/v2'
USER_AGENT = 'nxnative-build'
CURL = '/usr/bin/curl'   # the fallback when Python cannot check a certificate
MAX_AGE = 14 * 86400   # seconds before the titledb index is checked again
TITLEDB_TIMEOUT = 300   # the 90 MB list; every other request has 30 s
FIELDS = ('name', 'bannerUrl', 'description', 'intro', 'publisher', 'releaseDate')   # what the index keeps of a titledb entry, with its first 6 screenshots
ONLINE = ('titledb', 'steamgriddb')
MARKS = re.compile('[™®©]')   # ™ ® ©, which names carry and searches do not
MAX_BODY = 32 << 20   # a JSON answer read into memory, or an image
MAX_FILE = 1 << 30   # a download to a file (the titledb list)
DEADLINE = 10   # a request may take at most this many times its timeout in all (a server that trickles a byte at a time never trips the socket timeout)
STALE_PART = 3600   # seconds after its last write when a .part file a killed build left behind is deleted
GONE = (403, 404, 410)   # an image URL that answers these is gone for good: a final outcome, not tried again by every build
KEY_CHARS = re.compile(r'[A-Za-z0-9._~+/=-]+')   # what an API key is made of; anything else (a newline from a two-line file) is not sent
LOGO_SIZE = 1200   # a logo's longest side at most, in pixels (sips -Z, given only for a larger image: -Z also enlarges a smaller one)
PNG_MAGIC = b'\x89PNG\r\n\x1a\n'
LOGO_STYLES = ('official', 'white')   # SteamGridDB's logo styles in the order taken, then any other (black, custom)


class FetchError(Exception):
    def __init__(self, msg, status=None, ssl_error=False):
        super().__init__(msg); self.status = status; self.ssl_error = ssl_error


class Fetched(NamedTuple):
    status: int   # 200, or 304 for a conditional request whose file did not change
    body: bytes   # b'' when written to dest, and for a 304
    headers: dict   # lower-case names


# ---- the network: every request goes through fetch() ----

class _Redirect(urllib.request.HTTPRedirectHandler):   # a redirect keeps the Authorization header only on the same host, and never leaves https
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != 'https': return None
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).netloc != urllib.parse.urlsplit(req.full_url).netloc: new.remove_header('Authorization')
        return new


_OPENER = urllib.request.build_opener(_Redirect)


def _open(req, timeout):
    return _OPENER.open(req, timeout=timeout)


def run(argv, **kw):   # sips and curl (tests replace it)
    return subprocess.run(argv, **kw)


def _copy(r, f, limit, deadline):   # the response into f (a file) or into memory, at most limit bytes, done by deadline (time.monotonic())
    n, parts = 0, []
    while True:
        b = r.read(1 << 20)
        if not b: break
        n += len(b)
        if n > limit: raise FetchError(f'the answer is larger than {limit >> 20} MB')
        if time.monotonic() > deadline: raise FetchError('the answer took too long')
        if f is None: parts.append(b)
        else: f.write(b)
    return b''.join(parts)


def _urllib(url, h, timeout, dest, limit):
    req = urllib.request.Request(url, headers=h); deadline = time.monotonic() + timeout * DEADLINE
    try:
        with _open(req, timeout) as r:
            status, hdrs = r.status, {k.lower(): v for k, v in r.headers.items()}
            if dest is None: return Fetched(status, _copy(r, None, limit, deadline), hdrs)
            with open(dest, 'wb') as f: _copy(r, f, limit, deadline)
            return Fetched(status, b'', hdrs)
    except urllib.error.HTTPError as e:
        e.close()
        if e.code == 304: return Fetched(304, b'', {k.lower(): v for k, v in (e.headers or {}).items()})
        raise FetchError(f'HTTP {e.code}{" " + e.reason if isinstance(e.reason, str) and e.reason else ""}', status=e.code) from None
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLCertVerificationError): raise FetchError(f'certificate: {e.reason}', ssl_error=True) from None
        raise FetchError(str(e.reason)) from None
    except ssl.SSLCertVerificationError as e: raise FetchError(f'certificate: {e}', ssl_error=True) from None
    except (TimeoutError, OSError, http.client.HTTPException, ValueError) as e: raise FetchError(f'{type(e).__name__}: {e}' if str(e) else type(e).__name__) from None


def _curl(url, h, timeout, dest, limit):
    # Python from python.org may have no CA certificates; /usr/bin/curl uses the system's. The headers (the key among them) go on stdin (-H @-), never in argv.
    if not Path(CURL).is_file(): raise FetchError('certificate check failed, and there is no /usr/bin/curl to try instead')
    with tempfile.TemporaryDirectory(prefix='game_art.') as t:
        out, head = (Path(dest) if dest is not None else Path(t) / 'body'), Path(t) / 'headers'
        argv = [CURL, '-sS', '-L', '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', str(min(timeout, 30)), '--speed-limit', '1', '--speed-time', str(timeout),
                '--max-time', str(timeout * DEADLINE), '--max-filesize', str(limit), '-H', '@-', '-D', str(head), '-o', str(out), '-w', '%{http_code}', url]
        try: r = run(argv, input=''.join(f'{k}: {v}\n' for k, v in h.items()).encode(), capture_output=True, timeout=timeout * DEADLINE + 30)
        except (OSError, subprocess.TimeoutExpired) as e: raise FetchError(f'curl: {type(e).__name__}') from None
        if r.returncode:
            err = (r.stderr or b'').decode(errors='replace').strip().splitlines()
            raise FetchError(f'curl: {err[-1] if err else "exit " + str(r.returncode)}')
        code = (r.stdout or b'').decode(errors='replace').strip()[-3:]
        status = int(code) if code.isdigit() else 0
        hdrs = {}
        if head.is_file():   # the last block: the answer after any redirect
            blocks = [b for b in head.read_text(errors='replace').replace('\r\n', '\n').split('\n\n') if b.strip()]
            for line in (blocks[-1].splitlines()[1:] if blocks else []):
                k, sep, v = line.partition(':')
                if sep: hdrs[k.strip().lower()] = v.strip()
        if status == 304: return Fetched(304, b'', hdrs)
        if not 200 <= status < 300: raise FetchError(f'HTTP {status}', status=status)
        if out.is_file() and out.stat().st_size > limit: raise FetchError(f'the answer is larger than {limit >> 20} MB')   # before reading it (curl stops at --max-filesize, an old one only when the size is announced)
        if dest is not None: return Fetched(status, b'', hdrs)
        return Fetched(status, out.read_bytes() if out.is_file() else b'', hdrs)


def fetch(url, *, headers=None, timeout=30, dest=None, conditional=None, limit=None, user_agent: str | None = USER_AGENT):
    """GET an https URL: the body (in Fetched.body, or written to dest), or FetchError (with .status for an HTTP error). conditional = {'etag', 'last_modified'} of an earlier answer: Fetched.status
    is then 304 when nothing changed. limit: the most bytes taken (MAX_BODY in memory, MAX_FILE to dest); the whole request takes at most DEADLINE x timeout. Uses urllib with the User-Agent
    user_agent (nxnative-build for titledb and SteamGridDB's API; None for an image, which gets urllib's or curl's own), and /usr/bin/curl when the certificate check fails (a python.org Python without CA certificates)."""
    if not url.startswith('https://'): raise FetchError('not an https URL')
    h = {**({'User-Agent': user_agent} if user_agent else {}), **(headers or {})}
    limit = limit or (MAX_BODY if dest is None else MAX_FILE)
    if conditional:
        if conditional.get('etag'): h['If-None-Match'] = conditional['etag']
        if conditional.get('last_modified'): h['If-Modified-Since'] = conditional['last_modified']
    try: return _urllib(url, h, timeout, dest, limit)
    except FetchError as e:
        if not e.ssl_error: raise
    return _curl(url, h, timeout, dest, limit)


# ---- files ----

def _read_json(p):
    try: return json.loads(Path(p).read_text())
    except (OSError, ValueError): return None


def _write_json(p, obj):   # atomically: a build reading it never sees half a file
    p = Path(p); tmp = p.with_name(f'{p.name}.{os.getpid()}.tmp')
    try:
        tmp.write_text(json.dumps(obj, indent=1, ensure_ascii=False) + '\n'); os.replace(tmp, p)
    finally: tmp.unlink(missing_ok=True)


def _clean_parts(d, pattern):   # .part files a killed build left behind (their names hold its pid, so nothing else replaces them); one still being written is newer than STALE_PART
    try:
        for f in Path(d).glob(pattern):
            try:
                if time.time() - f.stat().st_mtime > STALE_PART: f.unlink()
            except OSError: pass
    except OSError: pass


def _now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def _longest(src):   # the longest side of an image in pixels (sips -g), or 0 when sips cannot tell
    try: r = run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(src)], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired): return 0
    return 0 if r.returncode else max((int(n) for n in re.findall(r'pixel(?:Width|Height):\s*(\d+)', r.stdout or '')), default=0)


def _sips(src, dst, say, fmt, size, magic, what):   # src → dst in the format fmt, longest side at most size, checked by its first bytes; False, with a say line starting with what, when sips cannot
    dst = Path(dst); tmp = dst.with_name(f'{dst.stem}.{os.getpid()}.part{dst.suffix}')
    n = _longest(src)   # sips -Z makes a smaller image larger too (a 600 px logo would be resampled to 1200, softer and 4 times the size): -Z only when the image is larger, or its size is unknown
    try:
        try: r = run(['sips', '-s', 'format', fmt, *(['-Z', str(size)] if not n or n > size else []), str(src), '--out', str(tmp)], capture_output=True, text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as e:
            say(f'{what}: sips cannot run ({type(e).__name__}: {e})'); return False
        head = b''
        if tmp.is_file():
            with open(tmp, 'rb') as f: head = f.read(len(magic))
        if r.returncode or head != magic:
            why = ((r.stderr or '') + (r.stdout or '')).strip().splitlines()
            say(f'{what}: sips cannot convert {Path(src).name} to a {fmt.upper()} ({why[-1] if why else "exit " + str(r.returncode)})'); return False
        os.replace(tmp, dst); return True
    finally: tmp.unlink(missing_ok=True)


def convert(src, dst, say):
    """src (a JPEG, PNG, WebP... of any size) → dst, a JPEG whose longest side is at most 1920 (sips). False, with a say line, when sips cannot."""
    return _sips(src, dst, say, 'jpeg', 1920, b'\xff\xd8', 'launcher art')


def convert_logo(src, dst, say):
    """src (a PNG or WebP with transparency, of any size) → dst, a PNG keeping its alpha whose longest side is at most LOGO_SIZE (sips). False, with a say line, when sips cannot."""
    return _sips(src, dst, say, 'png', LOGO_SIZE, PNG_MAGIC, 'launcher logo')


# ---- titledb ----

def titledb_dir():
    return CACHE_ROOT / 'titledb'


def build_index(data):
    """US.en.json ({nsuId: entry}) → {TITLE ID: the entry's FIELDS and first 6 screenshots}. Entries without a 16-hex "id" (null for some) are left out; of two with one title ID the one with a banner wins."""
    if isinstance(data, dict): entries = data.values()
    elif isinstance(data, list): entries = data
    else: raise ValueError('not a JSON object')
    out = {}
    for e in entries:
        if not isinstance(e, dict): continue
        tid = e.get('id')
        if not isinstance(tid, str) or not re.fullmatch(r'[0-9A-Fa-f]{16}', tid): continue
        tid = tid.upper()
        slim = {k: e.get(k) for k in FIELDS}
        shots = e.get('screenshots')
        slim['screenshots'] = [s for s in shots if isinstance(s, str)][:6] if isinstance(shots, list) else []
        old = out.get(tid)
        if old is None or (not old.get('bannerUrl') and slim.get('bannerUrl')): out[tid] = slim
    return out


def lookup(index, title_id):
    """The index entry of a title ID (an int), or None. A multi-program game's program (the application's ID + its index, 0-15) finds the application's entry."""
    if not isinstance(index, dict): return None
    for t in dict.fromkeys((title_id, title_id & ~0xF)):
        e = index.get(f'{t:016X}')
        if isinstance(e, dict): return e
    return None


def _state():   # the index's facts (checked, date, etag, last_modified), {} when there is no index; no network
    d = titledb_dir(); st = _read_json(d / 'state.json')
    return st if isinstance(st, dict) and (d / 'index.json').is_file() else {}


def stale(now=None):
    st = _state(); now = time.time() if now is None else now
    checked = st.get('checked')
    return not st or not isinstance(checked, (int, float)) or now - checked > MAX_AGE


def _refresh(st, say):
    d = titledb_dir(); part = d / f'US.en.json.{os.getpid()}.part'
    cond = {'etag': st.get('etag'), 'last_modified': st.get('last_modified')} if st else None
    say(f'titledb: checking the title list for changes (last checked {time.strftime("%Y-%m-%d", time.localtime(st["checked"]))})' if st and isinstance(st.get('checked'), (int, float))
        else f'titledb: downloading the title list (about 90 MB, once; kept as a small index in {d})')
    _clean_parts(d, 'US.en.json.*.part')
    try:
        d.mkdir(parents=True, exist_ok=True)
        r = fetch(TITLEDB_URL, timeout=TITLEDB_TIMEOUT, dest=part, conditional=cond)
        if r.status == 304:
            if not st: raise ValueError('HTTP 304 without an index to keep')
            _write_json(d / 'state.json', dict(st, checked=time.time())); say('titledb: unchanged'); return True
        with open(part, 'rb') as f: index = build_index(json.load(f))
        if not index: raise ValueError('no entry has a title ID')
        _write_json(d / 'index.json', index)
        _write_json(d / 'state.json', {'checked': time.time(), 'date': datetime.now(timezone.utc).isoformat(timespec='microseconds'), 'etag': r.headers.get('etag'), 'last_modified': r.headers.get('last-modified'), 'titles': len(index)})
        say(f'titledb: {len(index):,} titles indexed ({d / "index.json"})'); return True
    except FetchError as e: why = f'cannot download the title list ({e})'
    except (ValueError, MemoryError) as e: why = f'the title list is not what titledb writes ({type(e).__name__}: {str(e)[:200]})'
    except OSError as e: why = f'{type(e).__name__}: {e}'
    finally: part.unlink(missing_ok=True)
    say(f'titledb: {why}' + (f'; using the index of {st.get("date")}' if st else ''))
    return False


def titledb(say):
    """The titledb index (downloaded or checked when it is missing or older than 14 days), its date and whether that went well: (index or None, date or None, ok)."""
    ok = True
    if stale(): ok = _refresh(_state(), say)
    st = _state()
    if not st: return None, None, ok
    index = _read_json(titledb_dir() / 'index.json')
    if not isinstance(index, dict):
        say(f'titledb: {titledb_dir() / "index.json"} is damaged; it is downloaded again by the next build')
        (titledb_dir() / 'state.json').unlink(missing_ok=True); return None, None, False
    return index, st.get('date'), ok


def _text(v):
    return v.strip() or None if isinstance(v, str) else None


def release_date(v):   # titledb's 20191031 (an int, sometimes a string) → '2019-10-31'; None when it is not a date
    s = str(v) if isinstance(v, int) and not isinstance(v, bool) else v.strip() if isinstance(v, str) else ''
    m = re.fullmatch(r'(\d{4})-?(\d{2})-?(\d{2})', s)
    if not m: return None
    try: return date(*map(int, m.groups())).isoformat()
    except ValueError: return None


def about_of(entry, name):
    return {'name': _text(entry.get('name')) or name, 'intro': _text(entry.get('intro')), 'description': _text(entry.get('description')), 'publisher': _text(entry.get('publisher')),
            'releaseDate': release_date(entry.get('releaseDate')), 'source': 'titledb'}


# ---- SteamGridDB ----

def clean_name(name):   # the search term: the name without ™ ® © and doubled spaces
    return ' '.join(MARKS.sub(' ', name or '').split())


def _game_id(g):
    v = g.get('id')
    if isinstance(v, int) and not isinstance(v, bool): return v
    return int(v) if isinstance(v, str) and v.isdigit() else None


def choose_game(data, term):
    """Of SteamGridDB's search results: the one named as the game (ignoring case and ™ ® ©), else the first verified one, else the first."""
    games = [g for g in data if isinstance(g, dict) and _game_id(g) is not None] if isinstance(data, list) else []
    want = clean_name(term).casefold()
    return (next((g for g in games if clean_name(g.get('name') if isinstance(g.get('name'), str) else '').casefold() == want), None)
            or next((g for g in games if g.get('verified') is True), None) or (games[0] if games else None))


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def choose_hero(data):
    """Of a game's SteamGridDB heroes, without the nsfw and humor ones: at least 1920 wide first, the widest, then the highest score."""
    ok = [h for h in data if isinstance(h, dict) and isinstance(h.get('url'), str) and h['url'].startswith('https://') and not h.get('nsfw') and not h.get('humor')
          and (not isinstance(h.get('mime'), str) or h['mime'].startswith('image/'))] if isinstance(data, list) else []
    return max(ok, key=lambda h: (_num(h.get('width')) >= 1920, _num(h.get('width')), _num(h.get('score'))), default=None)


def choose_logo(data):
    """Of a game's SteamGridDB logos, without the nsfw and humor ones: style official first, then white, then any; a PNG before a WebP; then the highest score, then the widest."""
    ok = [g for g in data if isinstance(g, dict) and isinstance(g.get('url'), str) and g['url'].startswith('https://') and not g.get('nsfw') and not g.get('humor')
          and (not isinstance(g.get('mime'), str) or g['mime'].startswith('image/'))] if isinstance(data, list) else []
    def style(g): return LOGO_STYLES.index(g['style']) if isinstance(g.get('style'), str) and g['style'] in LOGO_STYLES else len(LOGO_STYLES)
    return max(ok, key=lambda g: (-style(g), g.get('mime') == 'image/png', _num(g.get('score')), _num(g.get('width'))), default=None)


def _api(path, key):   # (data, None) or (None, why); 'failed' in why marks an error to try again next build
    try: r = fetch(f'{STEAMGRIDDB_API}/{path}', headers={'Authorization': f'Bearer {key}'})
    except FetchError as e:
        if e.status == 401: return None, 'failed: the key was refused (HTTP 401), check STEAMGRIDDB_KEY'
        if e.status == 404: return [], None
        return None, f'failed: {e}'
    try: j = json.loads(r.body)
    except ValueError: return None, 'failed: its answer is not JSON'
    if not isinstance(j, dict) or j.get('success') is not True: return None, 'failed: it answered success false'
    return (j.get('data') if isinstance(j.get('data'), list) else []), None


def steamgriddb(name, key, *, heroes=True, logos=True) -> dict[str, Any]:
    """SteamGridDB's game named name, looked up once, and the hero and logo it would give (choose_hero, choose_logo; nothing downloaded). The logos are asked for only when heroes is False (the player's
    art) or the game has a hero: a logo never goes over a titledb banner. → {'hero', 'logo': the entries or None, 'hero_why', 'logo_why': why there is none, 'failed': an API error, tried again next build}"""
    out: dict[str, Any] = {'hero': None, 'logo': None, 'hero_why': None, 'logo_why': None, 'failed': False}
    term = clean_name(name)
    if not term: return dict(out, hero_why='no game name to search for', logo_why='no game name to search for')
    data, why = _api(f'search/autocomplete/{urllib.parse.quote(term, safe="")}', key)
    if why: return dict(out, hero_why=why, logo_why=why, failed=True)
    game = choose_game(data, term)
    if game is None: return dict(out, hero_why=f'no game named {term!r}', logo_why=f'no game named {term!r}')
    label, gid = game.get('name') or term, _game_id(game)
    if heroes:
        data, why = _api(f'heroes/game/{gid}', key)
        if why: out.update(hero_why=why, failed=True)
        else: out['hero'] = choose_hero(data); out['hero_why'] = None if out['hero'] else f'no hero image for {label!r}'
    if logos and (out['hero'] or not heroes):
        data, why = _api(f'logos/game/{gid}', key)
        if why: out.update(logo_why=why, failed=True)
        else: out['logo'] = choose_logo(data); out['logo_why'] = None if out['logo'] else f'no logo for {label!r}'
    elif logos: out['logo_why'] = 'no hero to show it over'
    return out


def _download(url, art_dir, say, what, logo=False):
    """An image → art_dir/art.jpg (logo: art_dir/logo.png): 'ok', 'gone' (HTTP 403/404/410: the URL is dead, which no later build changes) or 'failed' (tried again by the next build). No key header,
    no nxnative-build User-Agent (the image host learns which game this is from the URL; it need not learn the tool), at most MAX_BODY bytes."""
    part, tag = Path(art_dir) / f'download.{os.getpid()}.part', 'launcher logo' if logo else 'launcher art'
    try:
        try: fetch(url, dest=part, limit=MAX_BODY, user_agent=None)
        except FetchError as e:
            if e.status in GONE: say(f'{tag}: the {what} is gone ({e})'); return 'gone'
            say(f'{tag}: cannot download the {what} ({e})'); return 'failed'
        if not part.is_file() or part.stat().st_size == 0:
            say(f'{tag}: the {what} is empty'); return 'failed'
        if logo: return 'ok' if convert_logo(part, Path(art_dir) / 'logo.png', say) else 'failed'
        return 'ok' if convert(part, Path(art_dir) / 'art.jpg', say) else 'failed'
    finally: part.unlink(missing_ok=True)


# ---- the art folder ----

def _stamp(p):
    try: s = Path(p).stat()
    except OSError: return None
    return {'path': str(p), 'size': s.st_size, 'mtime_ns': s.st_mtime_ns}


def scrub(text, key):   # the key out of a text, also as Python quotes it in an error message (repr of the str or of its bytes: a newline as \\n)
    text = str(text)
    if key:
        for k in (key, repr(key)[1:-1], repr(key.encode())[2:-1]): text = text.replace(k, '<key>')
    return text


def _scrubbed(say, key):   # the key never reaches a say line, whatever an error message holds
    if not key: return say
    return lambda m: say(scrub(m, key))


def _online_art(entry, have_index, tid, name, key, art_dir, say, has_art, has_logo, keep_pair=False):
    """The online art and logo; has_art / has_logo: the player gave one (--art / --logo), which is not looked for. With a key, SteamGridDB first: its hero and logo as a pair (the logo downloaded first,
    as without it the titledb banner, which has the logo painted in, is the better art); else titledb's banner without a logo; else SteamGridDB's hero alone. A SteamGridDB logo goes over a hero or the
    player's art, never over a banner. keep_pair: the folder has the SteamGridDB pair an earlier build downloaded, which a SteamGridDB failure this time (an API error, a failed download) does not
    replace with the banner: no art is returned, not ok, and the caller keeps the pair. ((source, url) of the art or None, the same of the logo, facts for art.json, ok); with no art, facts['why'] says why (the caller says it)."""
    rel, lrel = f'{Path(art_dir).name}/art.jpg', f'{Path(art_dir).name}/logo.png'
    facts: dict = {'banner': False, 'steamgriddb': None, 'logo': None, 'why': None}
    why, ok, art, logo = [], True, None, None
    sg = steamgriddb(name, key, heroes=not has_art, logos=not has_logo) if key and not (has_art and has_logo) else None
    if sg: ok = not sg['failed']
    if has_logo: facts['logo'] = 'given'
    elif not key: facts['logo'] = 'skipped'
    elif sg and sg['logo']:
        got = _download(sg['logo']['url'], art_dir, say, 'SteamGridDB logo', logo=True)
        facts['logo'] = 'found' if got == 'ok' else got
        if got == 'ok': logo = ('steamgriddb', sg['logo']['url'])
        ok = ok and got != 'failed'
    elif sg: facts['logo'] = 'failed' if sg['logo_why'] and sg['logo_why'].startswith('failed') else 'none'
    if has_art:
        if logo: say(f'launcher logo: SteamGridDB logo for {name} ({lrel})')
        facts['steamgriddb'] = None if key else 'skipped'
        return None, logo, facts, ok
    hero = sg['hero'] if sg else None
    hero_why = sg['hero_why'] if sg else None
    if hero and (logo or has_logo):   # the textless hero with the logo: the titledb banner is not tried
        url, hero = hero['url'], None
        got = _download(url, art_dir, say, 'SteamGridDB hero')
        if got == 'ok':
            facts['steamgriddb'] = 'found'; art = ('steamgriddb', url)
            say(f'launcher art: SteamGridDB hero (textless, with the logo) for {name} ({rel})')
        else: ok = ok and got != 'failed'; hero_why = 'its hero image is gone' if got == 'gone' else 'the hero image failed'
    sg_why = next((w for w in (hero_why, sg['logo_why'] if sg else None, 'the logo failed' if facts['logo'] == 'failed' else None)
                   if isinstance(w, str) and (w.startswith('failed') or w.endswith('failed'))), None)   # SteamGridDB failed this time (tried again next build), not a final answer such as no logo
    if art is None and keep_pair and sg_why:   # a failure takes nothing away: the earlier pair stays (the caller keeps it) rather than the banner, which would drop the logo until SteamGridDB answers again
        facts.update(steamgriddb='failed', why=scrub(f'SteamGridDB: {sg_why}', key))
        if logo: say(f'launcher logo: SteamGridDB logo for {name} ({lrel})')
        return None, logo, facts, False
    if art is None:
        banner = entry.get('bannerUrl') if entry else None
        if isinstance(banner, str) and banner.startswith('https://'):
            facts['banner'] = True
            got = _download(banner, art_dir, say, 'titledb banner')
            if got == 'ok':
                art = ('titledb', banner); say(f'launcher art: titledb banner for {name} ({rel})')
            elif got == 'gone': why.append(f'titledb\'s banner for {tid} is gone')   # final: the next build with this index does not try it again
            else: ok = False; why.append('the titledb banner failed')
        elif not have_index: why.append('titledb unavailable')
        elif entry: why.append(f'titledb has no banner for {tid}')
        else: why.append(f'titledb does not list {tid}')
    if art is None and hero:
        got = _download(hero['url'], art_dir, say, 'SteamGridDB hero')
        if got == 'ok':
            facts['steamgriddb'] = 'found'; art = ('steamgriddb', hero['url']); say(f'launcher art: SteamGridDB hero for {name} ({rel})')
        else: ok = ok and got != 'failed'; hero_why = 'its hero image is gone' if got == 'gone' else 'the hero image failed'
    if not key:
        facts['steamgriddb'] = 'skipped'
        if art is None: why.append('SteamGridDB: no key, set STEAMGRIDDB_KEY')
    elif art is None or art[0] != 'steamgriddb':
        facts['steamgriddb'] = 'failed' if hero_why and (hero_why.startswith('failed') or hero_why == 'the hero image failed') else 'none'
        if art is None: why.append(f'SteamGridDB: {hero_why}')
    if logo and (art is None or art[0] == 'titledb'): logo = None   # never over a titledb banner (two logos), nor alone: the art fell back
    if logo: say(f'launcher logo: SteamGridDB logo for {name} ({lrel})')
    if art is None: facts['why'] = scrub('; '.join(why), key)   # art.json keeps it: never the key, whatever an error message held
    return art, logo, facts, ok


def _settle(title_id, name, art_dir, given, given_logo, online, key, say):
    tid = f'{title_id:016X}'
    art, logo, about = art_dir / 'art.jpg', art_dir / 'logo.png', art_dir / 'about.json'
    rel, lrel = f'{art_dir.name}/art.jpg', f'{art_dir.name}/logo.png'
    art_dir.mkdir(parents=True, exist_ok=True)
    _clean_parts(art_dir, '*.part*')
    prev = _read_json(art_dir / 'art.json')
    if not isinstance(prev, dict) or prev.get('title_id') != tid: prev = {}
    was: dict = prev['inputs'] if isinstance(prev.get('inputs'), dict) else {}
    plogo: dict = prev['logo'] if isinstance(prev.get('logo'), dict) else {}
    inputs: dict = dict(was)
    got, fetched, about_out, lgot = None, None, None, None   # got, lgot: (source, url) of this build's art and logo
    if given is not None:
        stamp = _stamp(given)
        if stamp is None: say(f'launcher art: no such file {given} (--art / ART)')
        elif was.get('given') == stamp and prev.get('source') == 'given' and art.is_file():
            got, fetched = ('given', None), prev.get('fetched'); say(f'launcher art: {given} ({rel}, as the last build made it)')
        elif convert(given, art, say):
            got, fetched = ('given', None), _now(); say(f'launcher art: {given} ({rel})')
        if got: inputs.update(given=stamp, looked=False)
    if not got: inputs['given'] = None
    lstamp = _stamp(given_logo) if given_logo is not None else None
    if given_logo is not None:
        if lstamp is None: say(f'launcher logo: no such file {given_logo} (--logo / LOGO)')
        elif was.get('logo_given') == lstamp and plogo.get('source') == 'given' and logo.is_file():
            lgot = ('given', None); say(f'launcher logo: {given_logo} ({lrel}, as the last build made it)')
        elif convert_logo(given_logo, logo, say):
            lgot = ('given', None); say(f'launcher logo: {given_logo} ({lrel})')
    inputs['logo_given'] = lstamp if lgot else None
    asked = {'art': got is not None, 'logo': lgot is not None, 'key': bool(key)}   # what decided the online lookup: another answer to any of them looks again (a key newly set, an option dropped)

    def earlier_logo(art_source):   # the SteamGridDB logo an earlier build downloaded, while it goes with this art: a SteamGridDB hero or the player's, never a titledb banner
        ok = plogo.get('source') == 'steamgriddb' and logo.is_file() and art_source in ('given', 'steamgriddb')
        return ('steamgriddb', plogo.get('url')) if ok else None

    if not online:
        if got is None and prev.get('source') in ONLINE and art.is_file():
            got, fetched = (prev['source'], prev.get('url')), prev.get('fetched')
            say(f'launcher art: the {"titledb banner" if got[0] == "titledb" else "SteamGridDB hero"} an earlier build downloaded ({rel}); ART_ONLINE is off, nothing is downloaded')
        elif got is None: say('launcher art: none (ART_ONLINE is off, nothing is downloaded); the launcher blurs the icon')
        if lgot is None and (lgot := earlier_logo(got[0] if got else None)): say(f'launcher logo: the SteamGridDB logo an earlier build downloaded ({lrel}); ART_ONLINE is off, nothing is downloaded')
        if was.get('listed') and about.is_file():
            about_out = about; say('About this game: from titledb (an earlier build; ART_ONLINE is off)')
    else:
        done = (was.get('online') is True and was.get('complete') is True and prev.get('name') == name   # the last online lookup for this game went through
                and (plogo.get('source') != 'steamgriddb' or logo.is_file()))
        settled = (done and was.get('asked') == asked   # and asked what this build asks: its answer stands
                   and not (lgot is None and plogo.get('source') == 'given'))   # unless logo.png is a --logo an earlier build (offline, say) was given and this one is not: SteamGridDB's is looked up again
        about_settled = done and (not was.get('listed') or about.is_file())
        if got is None and settled and prev.get('source') in ONLINE and art.is_file():
            got, fetched = (prev['source'], prev.get('url')), prev.get('fetched')
            say(f'launcher art: {"titledb banner" if got[0] == "titledb" else "SteamGridDB hero"} for {name} ({rel}, as an earlier build downloaded it)')
        if lgot is None and settled and (lgot := earlier_logo(got[0] if got else None)): say(f'launcher logo: SteamGridDB logo for {name} ({lrel}, as an earlier build downloaded it)')
        none_before = got is None and settled and prev.get('source') is None and was.get('looked') is True
        logo_lookup = got is not None and got[0] == 'given' and lgot is None and bool(key) and not settled   # the player's art with SteamGridDB's logo, not looked up yet
        need_index = not about_settled or logo_lookup or (got is None and (not none_before or stale()))
        index, index_date, ok = (titledb(say) if need_index else (None, was.get('titledb'), True))
        entry = lookup(index, title_id)
        if got is None and none_before and index_date == was.get('titledb'):   # nothing new since the last build found no art: the same index, the same options and key
            say(f'launcher art: none online, as the last build found ({was.get("why") or "nothing"}); the launcher blurs the icon')
        elif got is None or logo_lookup:
            looked_art = got is None
            keep_pair = looked_art and lgot is None and prev.get('source') == 'steamgriddb' and plogo.get('source') == 'steamgriddb' and art.is_file() and logo.is_file()
            a, lg, facts, art_ok = _online_art(entry, index is not None, tid, name, key, art_dir, say, has_art=not looked_art, has_logo=lgot is not None, keep_pair=keep_pair)
            ok = ok and art_ok; lgot = lgot or lg
            if looked_art:
                got = a; fetched = _now() if got else None
                inputs.update(facts, looked=True)
            else: inputs['logo'] = facts['logo']
            if looked_art and got is None and not ok and prev.get('source') in ONLINE and art.is_file():   # a failure (the network is down) takes nothing away: the art an earlier build downloaded stays, and the next build looks again
                got, fetched = (prev['source'], prev.get('url')), prev.get('fetched')
                say(f'launcher art: none online this time ({facts["why"]}); keeping the {"titledb banner" if got[0] == "titledb" else "SteamGridDB hero"} an earlier build downloaded ({rel})')
            elif looked_art and got is None: say(f'launcher art: none online ({facts["why"]}); the launcher blurs the icon')
            if lgot is None and not ok and (lgot := earlier_logo(got[0] if got else None)): say(f'launcher logo: none online this time; keeping the SteamGridDB logo an earlier build downloaded ({lrel})')
        if need_index:
            if index is not None and entry is not None:
                try: _write_json(about, about_of(entry, name)); about_out = about; say('About this game: from titledb')
                except OSError as e: say(f'About this game: cannot write {about} ({e})'); ok = False
            elif index is not None: about.unlink(missing_ok=True)
            elif was.get('listed') and about.is_file(): about_out = about; say('About this game: from titledb (an earlier build; titledb unavailable now)')
            if index is not None: inputs.update(listed=entry is not None, titledb=index_date)
            inputs.update(online=True, complete=ok and index is not None)
        elif was.get('listed') and about.is_file():
            about_out = about; say('About this game: from titledb (as an earlier build wrote it)')
        inputs['asked'] = asked   # on every online build, even one that looked nothing up (--logo given over --art): the next build that asks otherwise (--logo dropped, a key set again) looks again
    if lgot and lgot[0] == 'given' and got and got[0] == 'titledb': say('launcher logo: the titledb banner already shows the game\'s logo; --logo is shown over it')
    if got is None: art.unlink(missing_ok=True)
    if lgot is None: logo.unlink(missing_ok=True)
    rec = {'source': got[0] if got else None, 'url': got[1] if got else None, 'logo': {'source': lgot[0] if lgot else None, 'url': lgot[1] if lgot else None},
           'title_id': tid, 'name': name, 'fetched': fetched or _now(), 'inputs': inputs}
    try: _write_json(art_dir / 'art.json', rec)
    except OSError as e: say(f'launcher art: cannot write {art_dir / "art.json"} ({e}); the next build looks again')
    return {'art': art if got else None, 'source': got[0] if got else None, 'url': got[1] if got else None, 'logo': logo if lgot else None, 'about': about_out}


def settle(title_id: int, name: str, art_dir: Path, *, given: Path | None, online: bool, key: str, say: Callable[[str], None], given_logo: Path | None = None) -> dict:
    """The launcher's art and logo for the application title_id (an int; a multi-program game's program 0) named name, in art_dir (<build folder>/art/): given (--art / ART) or, when online, titledb's
    banner or SteamGridDB's hero (with key; with its logo, as a pair, when it has one); the logo given_logo (--logo / LOGO), else SteamGridDB's over a SteamGridDB hero or the given art; about.json from
    titledb. Reuses what an earlier build settled with the same inputs, without the network. Never raises: a failure is a say line.
    → {'art': art.jpg or None, 'source': 'given' | 'titledb' | 'steamgriddb' | None, 'url': the image URL or None, 'logo': logo.png or None, 'about': about.json or None}"""
    key = (key or '').strip()
    say = _scrubbed(say, key)
    if key and not KEY_CHARS.fullmatch(key):   # never sent: http.client would quote it whole in an error message
        say('launcher art: SteamGridDB skipped: STEAMGRIDDB_KEY has characters an API key does not (a space or a second line?); set it to the key alone'); key = ''
    try: return _settle(title_id, name or '', Path(art_dir), Path(given) if given else None, Path(given_logo) if given_logo else None, online, key, say)
    except Exception as e:   # the art is never worth a failed build
        say(f'launcher art: skipped ({type(e).__name__}: {e})')
        return {'art': None, 'source': None, 'url': None, 'logo': None, 'about': None}


def main():
    ap = argparse.ArgumentParser(description='Settle one game\'s launcher art folder (art.jpg, logo.png, art.json, about.json).')
    ap.add_argument('title_id'); ap.add_argument('name'); ap.add_argument('art_dir', type=Path)
    ap.add_argument('--art', type=Path, help='an image of yours instead of the online art')
    ap.add_argument('--logo', type=Path, help='a logo of yours (the game\'s title wordmark, a PNG or WebP with transparency) instead of SteamGridDB\'s')
    ap.add_argument('--offline', action='store_true', help='no network: only what the folder already has')
    a = ap.parse_args()
    r = settle(int(a.title_id, 16), a.name, a.art_dir, given=a.art, given_logo=a.logo, online=not a.offline, key=os.environ.get('STEAMGRIDDB_KEY', ''), say=print)
    print(json.dumps({k: str(v) if isinstance(v, Path) else v for k, v in r.items()}))


if __name__ == '__main__':
    sys.exit(main())
