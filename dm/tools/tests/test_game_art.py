"""The launcher's key art, logo and "About this game" text (scripts/game_art.py): titledb's index and lookup, its cache and conditional refresh, SteamGridDB's choices (hero, logo, the pair),
the art/ folder (art.json, logo.png, about.json, reuse without the network, offline mode), failures as say lines, and the SteamGridDB key kept out of every line, file and argv. No test touches the network:
fetch() is replaced, and so is what it calls. Run: python3 -m unittest dm/tools/tests/test_game_art.py"""
import importlib.util
import json
import os
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import zlib
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('game_art', REPO / 'scripts/game_art.py')
assert spec and spec.loader
ga = importlib.util.module_from_spec(spec); spec.loader.exec_module(ga)
REAL_FETCH = ga.fetch   # Base replaces it; the Fetch tests put it back

LM3 = 0x0100DCA0064A6000
SW2 = 0x0400486024DEC000   # a Switch 2 game titledb does not list
KEY = 'sgdb-secret-0123456789abcdef'
BANNER = 'https://img.example/lm3-banner.jpg'
HERO = 'https://cdn2.steamgriddb.example/hero/lm3.png'
LOGO = 'https://cdn2.steamgriddb.example/logo/lm3.png'
JPEG = b'\xff\xd8\xff\xe0fake jpeg'
PNG = b'\x89PNG\r\n\x1a\nfake png'


def titledb(banner: str | None = BANNER, extra=None):   # a tiny US.en.json, keyed by nsuId as titledb's is
    d = {
        '70010000012345': {'id': '0100dca0064a6000', 'name': "Luigi's Mansion™ 3", 'bannerUrl': banner, 'screenshots': [f'https://img.example/s{i}.jpg' for i in range(8)],
                           'description': 'Ghosts.', 'intro': 'Hotel trouble.', 'publisher': 'Nintendo', 'releaseDate': 20191031, 'size': 7064320000, 'rating': 10},
        '70010000000001': {'id': None, 'name': 'A bundle without a title ID'},
        '70010000000002': {'id': '0100AAAA00000000', 'name': 'First', 'bannerUrl': None},
        '70010000000003': {'id': '0100AAAA00000000', 'name': 'Second', 'bannerUrl': None},
        '70010000000004': {'id': '0100BBBB00000000', 'name': 'No banner', 'bannerUrl': None},
        '70010000000005': {'id': '0100BBBB00000000', 'name': 'With banner', 'bannerUrl': 'https://img.example/b.jpg'},
        '70010000000006': 'not an entry',
        '70010000000007': {'id': 'nothex', 'name': 'Broken'},
    }
    d.update(extra or {})
    return json.dumps(d).encode()


def search(*games): return json.dumps({'success': True, 'data': list(games)}).encode()


class Net:
    """fetch() for the tests: routes URL → bytes, a Fetched or a FetchError; every call is recorded. A URL without a route fails the test."""
    def __init__(self, routes=None):
        self.routes, self.calls = dict(routes or {}), []

    def __call__(self, url, *, headers=None, timeout=30, dest=None, conditional=None, limit=None, user_agent=ga.USER_AGENT):
        self.calls.append({'url': url, 'headers': dict(headers or {}), 'timeout': timeout, 'dest': dest, 'conditional': conditional, 'limit': limit, 'user_agent': user_agent})
        if url not in self.routes: raise AssertionError(f'unexpected request {url}')
        r = self.routes[url]
        if isinstance(r, Exception): raise r
        if isinstance(r, bytes): r = ga.Fetched(200, r, {})
        assert isinstance(r, ga.Fetched)
        if dest is not None and r.status == 200:
            Path(dest).write_bytes(r.body); r = ga.Fetched(200, b'', r.headers)
        return r

    def urls(self): return [c['url'] for c in self.calls]


def no_network(*a, **k): raise AssertionError('a test reached the network')


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='game_art_test.'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.argv, self.sips_fails, self.sips_fails_png, self.sips_size = [], False, False, (4000, 1000)   # sips_size: what sips -g says of any image (larger than both limits, so -Z is given)
        for name, v in (('CACHE_ROOT', self.tmp / 'cache'), ('_open', no_network), ('run', self.fake_run), ('fetch', no_network)):
            p = mock.patch.object(ga, name, v); p.start(); self.addCleanup(p.stop)
        self.art_dir = self.tmp / 'build/art'
        self.lines, self.sizes = [], []

    def fake_run(self, argv, **kw):   # sips -g tells sips_size; sips -s writes a JPEG or a PNG (-s format png, a logo); anything else is a test's own fake
        if argv[:2] == ['sips', '-g']: self.sizes.append([str(a) for a in argv]); return subprocess.CompletedProcess(argv, 0, f'{argv[-1]}\n  pixelWidth: {self.sips_size[0]}\n  pixelHeight: {self.sips_size[1]}\n', '')
        self.argv.append([str(a) for a in argv])
        if argv[0] == 'sips':
            if self.sips_fails or (self.sips_fails_png and argv[3] == 'png'): return subprocess.CompletedProcess(argv, 1, '', 'Error: Cannot open file')
            Path(argv[argv.index('--out') + 1]).write_bytes(PNG if argv[3] == 'png' else JPEG)
            return subprocess.CompletedProcess(argv, 0, '', '')
        raise AssertionError(f'unexpected command {argv}')

    def net(self, routes):
        n = Net(routes); p = mock.patch.object(ga, 'fetch', n); p.start(); self.addCleanup(p.stop)
        return n

    def settle(self, net, tid=LM3, name="Luigi's Mansion 3", given=None, online=True, key='', logo=None):
        self.lines = []
        with mock.patch.object(ga, 'fetch', net):
            return ga.settle(tid, name, self.art_dir, given=given, given_logo=logo, online=online, key=key, say=self.lines.append)

    def age_index(self, days=15):
        st = self.tmp / 'cache/titledb/state.json'
        s = json.loads(st.read_text()); s['checked'] = time.time() - days * 86400; st.write_text(json.dumps(s))

    def assert_no_key(self):
        for line in self.lines: self.assertNotIn(KEY, line)
        for argv in self.argv + self.sizes: self.assertNotIn(KEY, ' '.join(argv))
        for f in self.art_dir.rglob('*'):
            if f.is_file(): self.assertNotIn(KEY.encode(), f.read_bytes(), f)
        for f in (self.tmp / 'cache').rglob('*'):
            if f.is_file(): self.assertNotIn(KEY.encode(), f.read_bytes(), f)
        self.assertFalse(KEY in json.dumps(dict(os.environ)), 'nor the environment, under any name')


class Index(Base):
    def test_build(self):
        idx = ga.build_index(json.loads(titledb()))
        self.assertEqual(sorted(idx), ['0100AAAA00000000', '0100BBBB00000000', '0100DCA0064A6000'], 'null, missing and non-hex IDs are left out; IDs are upper case')
        e = idx['0100DCA0064A6000']
        self.assertEqual(set(e), {'name', 'bannerUrl', 'screenshots', 'description', 'intro', 'publisher', 'releaseDate'})
        self.assertEqual(len(e['screenshots']), 6)
        self.assertEqual(e['releaseDate'], 20191031)
        self.assertEqual(idx['0100AAAA00000000']['name'], 'First', 'of two without a banner, the first')
        self.assertEqual(idx['0100BBBB00000000']['name'], 'With banner', 'the one with a banner wins')
        with self.assertRaises(ValueError): ga.build_index('not a dict')

    def test_lookup(self):
        idx = ga.build_index(json.loads(titledb()))
        self.assertEqual(ga.lookup(idx, LM3)['publisher'], 'Nintendo', 'an int title ID finds the upper-case key of a lower-case "id"')
        self.assertEqual(ga.lookup(idx, LM3 + 1)['publisher'], 'Nintendo', 'a multi-program game\'s program finds its application')
        self.assertIsNone(ga.lookup(idx, LM3 | 0x800), 'an update ID is not the application')
        self.assertIsNone(ga.lookup(idx, SW2))
        self.assertIsNone(ga.lookup(None, LM3))

    def test_about(self):
        about = ga.about_of({'name': ' Name ', 'intro': '', 'description': 7, 'publisher': 'P', 'releaseDate': 20191031}, 'fallback')
        self.assertEqual(about, {'name': 'Name', 'intro': None, 'description': None, 'publisher': 'P', 'releaseDate': '2019-10-31', 'source': 'titledb'})
        self.assertEqual(ga.about_of({}, 'fallback')['name'], 'fallback')
        for v, want in ((20191031, '2019-10-31'), ('20200320', '2020-03-20'), ('2020-03-20', '2020-03-20'), (20191340, None), (None, None), (True, None), (2019, None)):
            self.assertEqual(ga.release_date(v), want, v)


class Cache(Base):
    def test_download_once(self):
        n = self.net({ga.TITLEDB_URL: ga.Fetched(200, titledb(), {'etag': '"v1"', 'last-modified': 'Sat, 07 Nov 2026 10:00:00 GMT'})})
        idx, date, ok = ga.titledb(self.lines.append)
        self.assertTrue(ok); self.assertIn('0100DCA0064A6000', idx); self.assertTrue(date)
        self.assertEqual(n.calls[0]['timeout'], 300); self.assertIsNone(n.calls[0]['conditional'], 'no index yet: a whole download')
        d = self.tmp / 'cache/titledb'
        self.assertEqual(sorted(p.name for p in d.iterdir()), ['index.json', 'state.json'], 'the 90 MB list is deleted after indexing')
        st = json.loads((d / 'state.json').read_text())
        self.assertEqual((st['etag'], st['last_modified'], st['titles']), ('"v1"', 'Sat, 07 Nov 2026 10:00:00 GMT', 3))
        self.assertTrue(any(line.startswith('titledb: downloading the title list') for line in self.lines))
        ga.titledb(self.lines.append)
        self.assertEqual(len(n.calls), 1, 'a fresh index is not checked again')

    def test_conditional(self):
        self.net({ga.TITLEDB_URL: ga.Fetched(200, titledb(), {'etag': '"v1"', 'last-modified': 'Sat, 07 Nov 2026 10:00:00 GMT'})})
        _, date, _ = ga.titledb(self.lines.append)
        self.age_index()
        n = self.net({ga.TITLEDB_URL: ga.Fetched(304, b'', {})})
        idx, date2, ok = ga.titledb(self.lines.append)
        self.assertEqual(n.calls[0]['conditional'], {'etag': '"v1"', 'last_modified': 'Sat, 07 Nov 2026 10:00:00 GMT'})
        self.assertTrue(ok); self.assertEqual(date2, date, 'a 304 keeps the index and its date'); self.assertIn('0100DCA0064A6000', idx)
        self.assertFalse(ga.stale(), 'and touches the time')
        self.age_index()
        self.net({ga.TITLEDB_URL: ga.Fetched(200, titledb(extra={'1': {'id': '0100CCCC00000000'}}), {'etag': '"v2"'})})
        idx, date3, _ = ga.titledb(self.lines.append)
        self.assertNotEqual(date3, date); self.assertIn('0100CCCC00000000', idx)

    def test_failures(self):
        self.net({ga.TITLEDB_URL: ga.FetchError('timed out')})
        self.assertEqual(ga.titledb(self.lines.append), (None, None, False))
        self.assertEqual(self.lines[-1], 'titledb: cannot download the title list (timed out)')
        self.net({ga.TITLEDB_URL: b'{"broken'})
        self.assertEqual(ga.titledb(self.lines.append), (None, None, False))
        self.assertTrue(self.lines[-1].startswith('titledb: the title list is not what titledb writes'))
        self.assertEqual(list((self.tmp / 'cache/titledb').iterdir()), [], 'no part file left behind')
        self.net({ga.TITLEDB_URL: titledb()})
        _, date, _ = ga.titledb(self.lines.append)
        self.age_index()
        self.net({ga.TITLEDB_URL: ga.FetchError('HTTP 503', status=503)})
        idx, date2, ok = ga.titledb(self.lines.append)
        self.assertFalse(ok); self.assertEqual(date2, date); self.assertIn('0100DCA0064A6000', idx, 'an old index still serves')
        self.assertTrue(self.lines[-1].endswith(f'; using the index of {date}'))


class Fetch(Base):
    def setUp(self):
        super().setUp()
        p = mock.patch.object(ga, 'fetch', REAL_FETCH); p.start(); self.addCleanup(p.stop)

    def opener(self, fn):
        p = mock.patch.object(ga, '_open', fn); p.start(); self.addCleanup(p.stop)

    def test_headers(self):
        seen = []

        class R:
            status = 200; headers = {'ETag': '"x"'}
            def __init__(self): self.left = [b'{"a"', b': 1}', b'']
            def read(self, n): return self.left.pop(0)
            def __enter__(self): return self
            def __exit__(self, *a): return False

        def open_(req, timeout): seen.append((req, timeout)); return R()
        self.opener(open_)
        r = ga.fetch('https://api.example/x', headers={'Authorization': 'Bearer ' + KEY}, conditional={'etag': '"x"', 'last_modified': 'Mon'})
        self.assertEqual(r, ga.Fetched(200, b'{"a": 1}', {'etag': '"x"'}))
        req, timeout = seen[0]
        self.assertEqual(timeout, 30)
        self.assertEqual((req.get_header('User-agent'), req.get_header('If-none-match'), req.get_header('If-modified-since')), ('nxnative-build', '"x"', 'Mon'))
        dest = self.tmp / 'out'
        self.assertEqual(ga.fetch('https://api.example/x', dest=dest, timeout=300).body, b'')
        self.assertEqual(dest.read_bytes(), b'{"a": 1}'); self.assertEqual(seen[1][1], 300)

    def test_errors(self):
        def http(code):
            def open_(req, timeout): raise urllib.error.HTTPError(req.full_url, code, 'Unauthorized' if code == 401 else 'Not Modified', {}, None)   # type: ignore[arg-type]
            return open_
        self.opener(http(304))
        self.assertEqual(ga.fetch('https://x.example/').status, 304)
        self.opener(http(401))
        with self.assertRaises(ga.FetchError) as e: ga.fetch('https://x.example/', headers={'Authorization': 'Bearer ' + KEY})
        self.assertEqual(e.exception.status, 401); self.assertNotIn(KEY, str(e.exception))
        def down(req, timeout): raise urllib.error.URLError(TimeoutError('timed out'))
        self.opener(down)
        with self.assertRaises(ga.FetchError): ga.fetch('https://x.example/')
        with self.assertRaises(ga.FetchError): ga.fetch('http://x.example/')

    def test_curl_fallback(self):
        def bad_cert(req, timeout): raise urllib.error.URLError(ssl.SSLCertVerificationError(1, 'certificate verify failed'))
        self.opener(bad_cert)
        stdin = []

        def curl(argv, **kw):
            self.argv.append([str(a) for a in argv]); stdin.append(kw['input'].decode())
            Path(argv[argv.index('-o') + 1]).write_bytes(b'{"success": true}')
            Path(argv[argv.index('-D') + 1]).write_text('HTTP/2 301\r\nlocation: x\r\n\r\nHTTP/2 200\r\nETag: "e"\r\n\r\n')
            return subprocess.CompletedProcess(argv, 0, b'200', b'')
        for name, v in (('run', curl), ('CURL', sys.executable)):
            p = mock.patch.object(ga, name, v); p.start(); self.addCleanup(p.stop)
        r = ga.fetch('https://www.steamgriddb.com/api/v2/search/autocomplete/x', headers={'Authorization': 'Bearer ' + KEY})
        self.assertEqual(r, ga.Fetched(200, b'{"success": true}', {'etag': '"e"'}))
        self.assertIn('Authorization: Bearer ' + KEY, stdin[0]); self.assertIn('User-Agent: nxnative-build', stdin[0])
        self.assertIn('@-', self.argv[0]); self.assertNotIn(KEY, ' '.join(self.argv[0]), 'the key goes on stdin, never in argv')

    def test_image_request(self):   # an image: no nxnative-build User-Agent, at most MAX_BODY; a trickling answer stops at the deadline
        seen = []

        class R:
            status = 200; headers = {}
            def __init__(self, chunks): self.left = list(chunks)
            def read(self, n): return self.left.pop(0) if self.left else b''
            def __enter__(self): return self
            def __exit__(self, *a): return False

        self.opener(lambda req, timeout: seen.append(req) or R([b'x', b'']))
        ga.fetch('https://img.example/b.jpg', dest=self.tmp / 'img', user_agent=None)
        self.assertIsNone(seen[0].get_header('User-agent'), 'urllib\'s own, not nxnative-build')
        self.opener(lambda req, timeout: R([b'x' * 10, b'x' * 10, b'']))
        with self.assertRaises(ga.FetchError) as e: ga.fetch('https://img.example/b.jpg', dest=self.tmp / 'img', limit=15)
        self.assertIn('larger than', str(e.exception))
        clock = iter([0.0, 1.0, 400.0, 401.0])
        self.opener(lambda req, timeout: R([b'x', b'x', b'x', b'']))
        with mock.patch.object(ga.time, 'monotonic', lambda: next(clock)), self.assertRaises(ga.FetchError) as e: ga.fetch('https://img.example/b.jpg', timeout=30)
        self.assertEqual(str(e.exception), 'the answer took too long')

    def test_curl_limits(self):   # curl gets --max-filesize; an API answer over the limit is refused before it is read into memory
        def bad_cert(req, timeout): raise urllib.error.URLError(ssl.SSLCertVerificationError(1, 'certificate verify failed'))
        self.opener(bad_cert)
        stdin = []

        def curl(argv, **kw):
            self.argv.append([str(a) for a in argv]); stdin.append(kw['input'].decode())
            Path(argv[argv.index('-o') + 1]).write_bytes(b'x' * 64)
            return subprocess.CompletedProcess(argv, 0, b'200', b'')
        for name, v in (('run', curl), ('CURL', sys.executable)):
            p = mock.patch.object(ga, name, v); p.start(); self.addCleanup(p.stop)
        with self.assertRaises(ga.FetchError) as e: ga.fetch('https://www.steamgriddb.com/api/v2/x', limit=32)
        self.assertIn('larger than', str(e.exception))
        argv = self.argv[-1]; self.assertEqual(argv[argv.index('--max-filesize') + 1], '32')
        ga.fetch('https://img.example/b.jpg', dest=self.tmp / 'img', limit=ga.MAX_BODY, user_agent=None)
        argv = self.argv[-1]; self.assertEqual(argv[argv.index('--max-filesize') + 1], str(ga.MAX_BODY))
        self.assertNotIn('nxnative-build', stdin[-1], 'an image request does not name the tool')
        ga.fetch(ga.TITLEDB_URL, dest=self.tmp / 'list', timeout=300)
        argv = self.argv[-1]; self.assertEqual(argv[argv.index('--max-filesize') + 1], str(ga.MAX_FILE))

    def test_redirect(self):
        h = ga._Redirect()
        req = urllib.request.Request('https://www.steamgriddb.com/api/v2/x', headers={'Authorization': 'Bearer ' + KEY})
        other = h.redirect_request(req, None, 302, 'Found', {}, 'https://cdn.example/x')
        self.assertIsNotNone(other); self.assertFalse(other.has_header('Authorization'), 'not sent to another host')
        same = h.redirect_request(req, None, 302, 'Found', {}, 'https://www.steamgriddb.com/api/v2/y')
        self.assertTrue(same.has_header('Authorization'))
        self.assertIsNone(h.redirect_request(req, None, 302, 'Found', {}, 'http://www.steamgriddb.com/api/v2/y'), 'never down to http')



class SteamGridDBChoice(unittest.TestCase):
    def test_game(self):
        games = [{'id': 1, 'name': 'Luigi\'s Mansion', 'verified': False}, {'id': 2, 'name': 'Something', 'verified': True}, {'id': 3, 'name': 'LUIGI\'S MANSION® 3', 'verified': False}]
        self.assertEqual(ga.choose_game(games, 'Luigi\'s Mansion™ 3')['id'], 3, 'the exact name, ignoring case and marks')
        self.assertEqual(ga.choose_game(games[:2], 'Luigi\'s Mansion 3')['id'], 2, 'else the first verified')
        self.assertEqual(ga.choose_game([games[0], {'name': 'no id'}], 'x')['id'], 1, 'else the first')
        self.assertIsNone(ga.choose_game([], 'x')); self.assertIsNone(ga.choose_game(None, 'x')); self.assertIsNone(ga.choose_game([{'id': True}], 'x'))
        self.assertEqual(ga.clean_name('Luigi\'s Mansion™  3©'), 'Luigi\'s Mansion 3')

    def test_hero(self):
        h = lambda url, w, score=0, **k: dict(url=f'https://h.example/{url}', width=w, height=w // 3, score=score, **k)
        heroes = [h('small', 1600, 50), h('nsfw', 3840, 99, nsfw=True), h('humor', 3840, 99, humor=True), h('a', 1920, 5), h('b', 3840, 1), h('c', 3840, 7), h('d', 3000, 99)]
        self.assertTrue(ga.choose_hero(heroes)['url'].endswith('/c'), 'nsfw and humor dropped; the widest of those at least 1920, then the score')
        self.assertTrue(ga.choose_hero([h('small', 1600, 50), h('smaller', 1280, 99)])['url'].endswith('/small'))
        self.assertIsNone(ga.choose_hero([{'url': 'http://h.example/x', 'width': 4000}, {'width': 4000}, 'x', h('n', 4000, nsfw=True)]))
        self.assertIsNone(ga.choose_hero({'not': 'a list'}))

    def test_logo(self):   # nsfw and humor dropped; style official, then white, then any; a PNG before a WebP; then the score, then the width
        g = lambda url, style, mime='image/png', score=0, w=800, **k: dict(url=f'https://l.example/{url}', style=style, mime=mime, score=score, width=w, height=w // 4, **k)
        logos = [g('custom', 'custom', score=99, w=2000), g('nsfw', 'official', score=99, nsfw=True), g('humor', 'official', score=99, humor=True), g('white', 'white', score=50),
                 g('webp', 'official', 'image/webp', score=99), g('off-low', 'official', score=1, w=3000), g('off-high', 'official', score=5, w=600), g('off-wide', 'official', score=5, w=900)]
        self.assertTrue(ga.choose_logo(logos)['url'].endswith('/off-wide'), 'official, a PNG, the highest score, then the widest')
        self.assertTrue(ga.choose_logo(logos[:4])['url'].endswith('/white'), 'no official one: white')
        self.assertTrue(ga.choose_logo([logos[0], g('black', 'black', score=3)])['url'].endswith('/custom'), 'neither: any, by score')
        self.assertTrue(ga.choose_logo([logos[4], g('white-png', 'white')])['url'].endswith('/webp'), 'the style before the format')
        self.assertTrue(ga.choose_logo([logos[4], g('off-png', 'official')])['url'].endswith('/off-png'), 'a PNG before a WebP')
        self.assertIsNone(ga.choose_logo([{'url': 'http://l.example/x', 'style': 'official'}, {'style': 'official'}, 'x', logos[1], g('svg', 'official', 'text/html')]))
        self.assertIsNone(ga.choose_logo(None))


class Settle(Base):
    def lm3_net(self, banner=BANNER, **more):
        return Net({ga.TITLEDB_URL: ga.Fetched(200, titledb(banner), {'etag': '"v1"'}), BANNER: b'banner bytes', **more})

    def test_titledb_banner(self):
        net = self.lm3_net()
        r = self.settle(net)
        art = self.art_dir / 'art.jpg'
        self.assertEqual(r, {'art': art, 'source': 'titledb', 'url': BANNER, 'logo': None, 'about': self.art_dir / 'about.json'})
        self.assertEqual(art.read_bytes(), JPEG)
        self.assertEqual(self.argv[-1][:6], ['sips', '-s', 'format', 'jpeg', '-Z', '1920'])
        self.assertIn("launcher art: titledb banner for Luigi's Mansion 3 (art/art.jpg)", self.lines)
        self.assertIn('About this game: from titledb', self.lines)
        rec = json.loads((self.art_dir / 'art.json').read_text())
        self.assertEqual((rec['source'], rec['url'], rec['title_id'], rec['name']), ('titledb', BANNER, '0100DCA0064A6000', "Luigi's Mansion 3"))
        self.assertTrue(rec['fetched'])
        about = json.loads((self.art_dir / 'about.json').read_text())
        self.assertEqual(about, {'name': "Luigi's Mansion™ 3", 'intro': 'Hotel trouble.', 'description': 'Ghosts.', 'publisher': 'Nintendo', 'releaseDate': '2019-10-31', 'source': 'titledb'})
        self.assertEqual(net.calls[1]['headers'], {}, 'no key header on an image')
        self.assertEqual((net.calls[0]['user_agent'], net.calls[1]['user_agent'], net.calls[1]['limit']), (ga.USER_AGENT, None, ga.MAX_BODY), 'the image host is not told the tool; an image is at most MAX_BODY')
        self.assertEqual(sorted(p.name for p in self.art_dir.iterdir()), ['about.json', 'art.jpg', 'art.json'], 'no download left behind')

    def test_reuse_without_network(self):
        r = self.settle(self.lm3_net())
        self.argv.clear()
        r2 = self.settle(Net())   # any request fails the test
        self.assertEqual(r2, r); self.assertEqual(self.argv, [], 'nor sips again')
        self.assertIn("launcher art: titledb banner for Luigi's Mansion 3 (art/art.jpg, as an earlier build downloaded it)", self.lines)
        self.assertIn('About this game: from titledb (as an earlier build wrote it)', self.lines)

    def test_offline(self):
        r = self.settle(Net(), online=False)
        self.assertEqual(r, {'art': None, 'source': None, 'url': None, 'logo': None, 'about': None})
        self.assertEqual(self.lines, ['launcher art: none (ART_ONLINE is off, nothing is downloaded); the launcher blurs the icon'])
        self.assertFalse(ga.CACHE_ROOT.exists(), 'not even the cache is touched')
        r = self.settle(self.lm3_net())
        net = Net()
        self.assertEqual(self.settle(net, online=False), r, 'art an earlier online build fetched is still used')
        self.assertEqual(net.calls, [])
        self.assertIn('ART_ONLINE is off', self.lines[0]); self.assertIn('titledb banner', self.lines[0])
        self.assertIn('About this game: from titledb (an earlier build; ART_ONLINE is off)', self.lines)

    def test_no_key(self):
        net = Net({ga.TITLEDB_URL: titledb()})
        r = self.settle(net, tid=SW2, name='Donkey Kong Bananza')
        self.assertEqual(r, {'art': None, 'source': None, 'url': None, 'logo': None, 'about': None})
        self.assertIn('launcher art: none online (titledb does not list 0400486024DEC000; SteamGridDB: no key, set STEAMGRIDDB_KEY); the launcher blurs the icon', self.lines)
        self.assertFalse((self.art_dir / 'about.json').exists())
        net = Net()
        self.settle(net, tid=SW2, name='Donkey Kong Bananza')
        self.assertEqual(net.calls, [], 'the same inputs: the same answer, without the network')
        self.assertIn('launcher art: none online, as the last build found', self.lines[0])
        # a key now: SteamGridDB is asked
        api = ga.STEAMGRIDDB_API
        net = Net({f'{api}/search/autocomplete/Donkey%20Kong%20Bananza': search({'id': 77, 'name': 'Donkey Kong Bananza', 'verified': True}),
                   f'{api}/heroes/game/77': search({'url': HERO, 'width': 3840, 'score': 3}), f'{api}/logos/game/77': search(), HERO: b'png'})
        r = self.settle(net, tid=SW2, name='Donkey Kong Bananza', key=KEY)
        self.assertEqual((r['source'], r['url']), ('steamgriddb', HERO))
        self.assertIn('launcher art: SteamGridDB hero for Donkey Kong Bananza (art/art.jpg)', self.lines)
        self.assert_no_key()

    def test_steamgriddb(self):
        api = ga.STEAMGRIDDB_API
        term = urllib.parse.quote("Luigi's Mansion 3", safe='')
        heroes = [{'url': 'https://h.example/nsfw.png', 'width': 3840, 'score': 99, 'nsfw': True}, {'url': HERO, 'width': 1920, 'score': 4, 'nsfw': False, 'humor': False, 'mime': 'image/png'}]
        net = Net({ga.TITLEDB_URL: titledb(banner=None), f'{api}/search/autocomplete/{term}': search({'id': 5, 'name': 'Luigi\'s Mansion'}, {'id': 6, 'name': 'Luigi\'s Mansion 3'}),
                   f'{api}/heroes/game/6': search(*heroes), f'{api}/logos/game/6': search(), HERO: b'png'})
        r = self.settle(net, name="Luigi's Mansion™ 3", key=KEY)
        self.assertEqual(r, {'art': self.art_dir / 'art.jpg', 'source': 'steamgriddb', 'url': HERO, 'logo': None, 'about': self.art_dir / 'about.json'})
        for c in net.calls:
            self.assertEqual(c['headers'].get('Authorization'), 'Bearer ' + KEY if c['url'].startswith(api) else None, c['url'])
            self.assertNotIn(KEY, c['url'])
        self.assertEqual(json.loads((self.art_dir / 'art.json').read_text())['source'], 'steamgriddb')
        self.assert_no_key()

    def test_401(self):
        api = ga.STEAMGRIDDB_API
        net = Net({ga.TITLEDB_URL: titledb(), f'{api}/search/autocomplete/Donkey%20Kong%20Bananza': ga.FetchError('HTTP 401 Unauthorized', status=401)})
        r = self.settle(net, tid=SW2, name='Donkey Kong Bananza', key=KEY)
        self.assertIsNone(r['art'])
        line = next(line for line in self.lines if line.startswith('launcher art: none online'))
        self.assertIn('the key was refused (HTTP 401), check STEAMGRIDDB_KEY', line)
        self.assert_no_key()
        self.settle(net, tid=SW2, name='Donkey Kong Bananza', key=KEY)
        self.assertEqual(net.urls().count(f'{api}/search/autocomplete/Donkey%20Kong%20Bananza'), 2, 'a failed lookup is tried again by the next build')

    def test_key_never_said(self):
        api = ga.STEAMGRIDDB_API
        net = Net({ga.TITLEDB_URL: titledb(), f'{api}/search/autocomplete/Game': ga.FetchError(f'server echoed Bearer {KEY}')})
        self.settle(net, tid=SW2, name='Game', key=KEY)
        self.assertTrue(any('<key>' in line for line in self.lines))
        self.assert_no_key()

    def test_steamgriddb_answers(self):
        api = ga.STEAMGRIDDB_API
        for answer, why in ((b'not json', 'its answer is not JSON'), (json.dumps({'success': False, 'errors': ['x']}).encode(), 'success false'),
                            (search(), "no game named 'Game'"), (json.dumps({'success': True}).encode(), "no game named 'Game'")):
            shutil.rmtree(self.art_dir, ignore_errors=True)
            self.settle(Net({ga.TITLEDB_URL: titledb(), f'{api}/search/autocomplete/Game': answer}), tid=SW2, name='Game', key=KEY)
            self.assertIn(why, self.lines[-1])
        shutil.rmtree(self.art_dir)
        self.settle(Net({ga.TITLEDB_URL: titledb(), f'{api}/search/autocomplete/Game': search({'id': 9, 'name': 'Game'}), f'{api}/heroes/game/9': ga.FetchError('HTTP 404', status=404)}),
                    tid=SW2, name='Game', key=KEY)
        self.assertIn("SteamGridDB: no hero image for 'Game'", self.lines[-1])

    def test_index_refresh(self):
        self.settle(Net({ga.TITLEDB_URL: titledb(banner=None)}))
        self.assertIn("titledb has no banner for 0100DCA0064A6000", self.lines[-2])
        self.assertTrue((self.art_dir / 'about.json').is_file(), 'listed: the text, whatever the art')
        self.age_index()
        net = Net({ga.TITLEDB_URL: ga.Fetched(304, b'', {})})
        self.assertIsNone(self.settle(net)['art'])
        self.assertEqual(net.urls(), [ga.TITLEDB_URL], 'an unchanged index: no new lookup')
        self.age_index()
        r = self.settle(self.lm3_net())
        self.assertEqual(r['source'], 'titledb', 'a refreshed index with a banner now: downloaded')

    def test_given(self):
        img = self.tmp / 'mine.png'; img.write_bytes(b'png')
        net = Net({ga.TITLEDB_URL: titledb()})
        r = self.settle(net, given=img)
        self.assertEqual(r, {'art': self.art_dir / 'art.jpg', 'source': 'given', 'url': None, 'logo': None, 'about': self.art_dir / 'about.json'})
        self.assertEqual(net.urls(), [ga.TITLEDB_URL], 'online: titledb only for the text; no banner download')
        self.assertIn(str(img), self.argv[-1])
        self.assertIn(f'launcher art: {img} (art/art.jpg)', self.lines)
        rec = json.loads((self.art_dir / 'art.json').read_text())
        self.assertEqual((rec['source'], rec['url'], rec['inputs']['given']['path']), ('given', None, str(img)))
        self.argv.clear(); self.sizes.clear()
        self.assertEqual(self.settle(Net(), given=img), r); self.assertEqual((self.argv, self.sizes), ([], []), 'the same image: reused')
        img.write_bytes(b'png, changed')
        self.settle(Net(), given=img, online=False)
        self.assertEqual(len(self.argv), 1, 'a changed image is converted again')
        self.assertEqual(len(self.sizes), 1)
        r = self.settle(self.lm3_net())
        self.assertEqual(r['source'], 'titledb', 'without --art again: the online art')

    def test_failures(self):
        net = Net({ga.TITLEDB_URL: ga.FetchError('<urlopen error [Errno 8] nodename nor servname provided>')})
        self.assertEqual(self.settle(net), {'art': None, 'source': None, 'url': None, 'logo': None, 'about': None})
        self.assertIn('titledb: cannot download the title list (<urlopen error [Errno 8] nodename nor servname provided>)', self.lines)
        self.assertIn('launcher art: none online (titledb unavailable; SteamGridDB: no key, set STEAMGRIDDB_KEY); the launcher blurs the icon', self.lines)
        net = self.lm3_net(**{BANNER: ga.FetchError('timed out')})
        self.assertIsNone(self.settle(net)['art'])
        self.assertIn('launcher art: cannot download the titledb banner (timed out)', self.lines)
        self.assertEqual(self.settle(Net({BANNER: b'banner'}))['source'], 'titledb', 'a failed download is tried again; the index is not')
        shutil.rmtree(self.art_dir); self.sips_fails = True
        self.assertIsNone(self.settle(Net({BANNER: b'not an image'}))['art'])
        self.assertIn('launcher art: sips cannot convert', ' '.join(self.lines))
        self.assertFalse(list(self.art_dir.glob('*.part*')))
        with mock.patch.object(ga, '_settle', side_effect=RuntimeError('boom')):
            self.assertEqual(self.settle(Net()), {'art': None, 'source': None, 'url': None, 'logo': None, 'about': None})
        self.assertEqual(self.lines, ['launcher art: skipped (RuntimeError: boom)'])

    def test_failed_retry_keeps_the_art(self):   # an incomplete lookup is tried again; when that fails too (no network), the art an earlier build downloaded stays
        api = ga.STEAMGRIDDB_API
        term = urllib.parse.quote("Luigi's Mansion 3", safe='')
        net = self.lm3_net(**{BANNER: ga.FetchError('HTTP 503', status=503), f'{api}/search/autocomplete/{term}': search({'id': 6, 'name': "Luigi's Mansion 3"}),
                              f'{api}/heroes/game/6': search({'url': HERO, 'width': 3840}), f'{api}/logos/game/6': search(), HERO: b'png'})
        r = self.settle(net, key=KEY)
        self.assertEqual(r['source'], 'steamgriddb')
        self.assertFalse(json.loads((self.art_dir / 'art.json').read_text())['inputs']['complete'], 'the banner failed: not settled')
        down = ga.FetchError('<urlopen error [Errno 8] nodename nor servname provided>')
        net = Net({BANNER: down, f'{api}/search/autocomplete/{term}': down})
        r2 = self.settle(net, key=KEY)
        self.assertEqual(r2, r, 'the hero stays')
        self.assertEqual((self.art_dir / 'art.jpg').read_bytes(), JPEG)
        self.assertTrue(any(line.startswith('launcher art: none online this time (') and line.endswith('keeping the SteamGridDB hero an earlier build downloaded (art/art.jpg)') for line in self.lines), self.lines)
        self.assertFalse(any('blurs the icon' in line for line in self.lines))
        rec = json.loads((self.art_dir / 'art.json').read_text())
        self.assertEqual((rec['source'], rec['url'], rec['inputs']['complete']), ('steamgriddb', HERO, False), 'and the next build looks again')
        self.assert_no_key()

    def test_gone_banner(self):   # a banner URL that answers 404 is a final answer: the next build reuses the outcome without the network
        api = ga.STEAMGRIDDB_API
        term = urllib.parse.quote("Luigi's Mansion 3", safe='')
        net = self.lm3_net(**{BANNER: ga.FetchError('HTTP 404 Not Found', status=404), f'{api}/search/autocomplete/{term}': search({'id': 6, 'name': "Luigi's Mansion 3"}),
                              f'{api}/heroes/game/6': search({'url': HERO, 'width': 3840}), f'{api}/logos/game/6': ga.FetchError('HTTP 404', status=404), HERO: b'png'})
        r = self.settle(net, key=KEY)
        self.assertEqual(r['source'], 'steamgriddb')
        self.assertIn('launcher art: the titledb banner is gone (HTTP 404 Not Found)', self.lines)
        self.assertTrue(json.loads((self.art_dir / 'art.json').read_text())['inputs']['complete'])
        net = Net()
        self.assertEqual(self.settle(net, key=KEY), r); self.assertEqual(net.calls, [], 'no request: the same inputs')
        shutil.rmtree(self.art_dir)
        self.settle(self.lm3_net(**{BANNER: ga.FetchError('HTTP 410', status=410)}))   # no key: none, settled
        self.assertIn("titledb's banner for 0100DCA0064A6000 is gone", self.lines[-2] + self.lines[-1])
        net = Net()
        self.assertIsNone(self.settle(net)['art']); self.assertEqual(net.calls, [])

    def test_key_with_a_newline(self):   # http.client would quote such a key whole (\n and all) in its error: it is not sent, and no line or file holds a part of it
        bad = 'SEKRETpart1\nSEKRETpart2'
        net = Net({ga.TITLEDB_URL: titledb()})
        self.settle(net, tid=SW2, name='Game', key=bad)
        self.assertIn('launcher art: SteamGridDB skipped: STEAMGRIDDB_KEY has characters an API key does not (a space or a second line?); set it to the key alone', self.lines)
        self.assertEqual(net.urls(), [ga.TITLEDB_URL], 'SteamGridDB is not asked')
        for line in self.lines: self.assertNotIn('SEKRET', line)
        for f in self.art_dir.rglob('*'): self.assertNotIn(b'SEKRET', f.read_bytes())
        self.assertEqual(ga.scrub("Invalid header value b'Bearer SEKRETpart1\\nSEKRETpart2'", bad), "Invalid header value b'Bearer <key>'")
        self.assertEqual(ga.scrub('x', ''), 'x')

    def test_stale_part_files(self):   # .part files a killed build left: deleted once they are older than STALE_PART; a fresh one (another build's download) is left alone
        d = self.tmp / 'cache/titledb'; d.mkdir(parents=True); self.art_dir.mkdir(parents=True)
        old, new, art_old = d / 'US.en.json.11111.part', d / 'US.en.json.22222.part', self.art_dir / 'download.33333.part'
        for f in (old, new, art_old): f.write_bytes(b'x')
        t = time.time() - ga.STALE_PART - 60
        for f in (old, art_old): os.utime(f, (t, t))
        self.settle(Net({ga.TITLEDB_URL: titledb(banner=None)}))
        self.assertFalse(old.exists()); self.assertFalse(art_old.exists()); self.assertTrue(new.exists())

    def test_other_game_in_folder(self):
        self.settle(self.lm3_net())
        net = Net({ga.TITLEDB_URL: titledb()})
        r = self.settle(net, tid=0x0100AAAA00000000, name='First')
        self.assertIsNone(r['art']); self.assertEqual(r['about'], self.art_dir / 'about.json')
        self.assertFalse((self.art_dir / 'art.jpg').exists(), 'another title ID: the old art is not taken')
        self.assertEqual(json.loads(r['about'].read_text())['name'], 'First')


class Logo(Base):
    """The game's logo (logo.png): SteamGridDB's with its hero as a pair, the titledb banner without one, the player's --logo, reuse and offline, failures as one line"""
    api = ga.STEAMGRIDDB_API
    term = urllib.parse.quote("Luigi's Mansion 3", safe='')

    def sgdb(self, logos=(), heroes=None, banner: str | None = BANNER, **more):   # titledb with LM3's banner, SteamGridDB's game 6 with a hero and the logos given
        heroes = [{'url': HERO, 'width': 3840, 'score': 2}] if heroes is None else heroes
        return Net({ga.TITLEDB_URL: ga.Fetched(200, titledb(banner), {'etag': '"v1"'}), BANNER: b'banner bytes', HERO: b'hero png', LOGO: b'logo png',
                    f'{self.api}/search/autocomplete/{self.term}': search({'id': 6, 'name': "Luigi's Mansion 3"}), f'{self.api}/heroes/game/6': search(*heroes),
                    f'{self.api}/logos/game/6': search(*logos), **more})

    official = {'url': LOGO, 'style': 'official', 'mime': 'image/png', 'width': 1600, 'height': 400, 'score': 3}

    def rec(self): return json.loads((self.art_dir / 'art.json').read_text())

    def fresh(self):   # a new build folder and an empty titledb cache, for a test's next case
        for d in (self.art_dir, self.tmp / 'cache'): shutil.rmtree(d, ignore_errors=True)

    def test_pair(self):   # rule 2: SteamGridDB has a hero and a logo: the textless hero is the art and the logo goes over it; the titledb banner (logo painted in) is not downloaded
        net = self.sgdb([self.official])
        r = self.settle(net, key=KEY)
        logo = self.art_dir / 'logo.png'
        self.assertEqual(r, {'art': self.art_dir / 'art.jpg', 'source': 'steamgriddb', 'url': HERO, 'logo': logo, 'about': self.art_dir / 'about.json'})
        self.assertNotIn(BANNER, net.urls())
        self.assertEqual(net.urls().count(f'{self.api}/search/autocomplete/{self.term}'), 1, 'the game is looked up once')
        self.assertEqual(logo.read_bytes(), PNG); self.assertEqual((self.art_dir / 'art.jpg').read_bytes(), JPEG)
        self.assertIn(['sips', '-s', 'format', 'png', '-Z', '1200'], [a[:6] for a in self.argv])
        self.assertIn("launcher art: SteamGridDB hero (textless, with the logo) for Luigi's Mansion 3 (art/art.jpg)", self.lines)
        self.assertIn("launcher logo: SteamGridDB logo for Luigi's Mansion 3 (art/logo.png)", self.lines)
        call = next(c for c in net.calls if c['url'] == LOGO)
        self.assertEqual((call['headers'], call['user_agent'], call['limit']), ({}, None, ga.MAX_BODY), 'the logo is an image: no key, no tool name')
        self.assertEqual(self.rec()['logo'], {'source': 'steamgriddb', 'url': LOGO})
        self.assertEqual(sorted(p.name for p in self.art_dir.iterdir()), ['about.json', 'art.jpg', 'art.json', 'logo.png'])
        self.assert_no_key()
        self.argv.clear()
        self.assertEqual(self.settle(Net(), key=KEY), r, 'reused without the network'); self.assertEqual(self.argv, [])
        self.assertIn("launcher logo: SteamGridDB logo for Luigi's Mansion 3 (art/logo.png, as an earlier build downloaded it)", self.lines)
        self.assertEqual(self.settle(Net(), key=KEY, online=False), r, 'offline: the logo an earlier build downloaded, as the art')
        self.assertIn('launcher logo: the SteamGridDB logo an earlier build downloaded (art/logo.png); ART_ONLINE is off, nothing is downloaded', self.lines)
        self.assert_no_key()

    def test_no_logo_keeps_the_banner(self):   # rule 2: a hero without a logo: the titledb banner, which shows the logo, and the name text is not needed; the hero is not downloaded
        net = self.sgdb([{'url': LOGO, 'style': 'official', 'nsfw': True}])
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('titledb', None))
        self.assertNotIn(HERO, net.urls()); self.assertNotIn(LOGO, net.urls())
        self.assertFalse((self.art_dir / 'logo.png').exists())
        self.assertEqual(self.rec()['logo'], {'source': None, 'url': None})
        net = self.sgdb([self.official], banner=None); self.fresh()   # no banner: the pair
        self.assertEqual(self.settle(net, key=KEY)['logo'], self.art_dir / 'logo.png')
        net = self.sgdb(banner=None); self.fresh()   # no banner and no logo: the hero alone, the name text stays
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', None))
        self.assertIn("launcher art: SteamGridDB hero for Luigi's Mansion 3 (art/art.jpg)", self.lines)
        net = self.sgdb([self.official], heroes=[]); self.fresh()   # no hero: no logo is asked for (it never goes over the banner)
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('titledb', None)); self.assertNotIn(f'{self.api}/logos/game/6', net.urls())

    def test_failed_logo_keeps_the_banner(self):   # a logo that fails to download or convert: one line, no logo, the titledb banner; never two logos, never a failed build
        net = self.sgdb([self.official], **{LOGO: ga.FetchError('HTTP 503', status=503)})
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['url'], r['logo']), ('titledb', BANNER, None))
        self.assertEqual([ln for ln in self.lines if ln.startswith('launcher logo')], ['launcher logo: cannot download the SteamGridDB logo (HTTP 503)'])
        self.assertNotIn(HERO, net.urls()); self.assertFalse((self.art_dir / 'logo.png').exists())
        self.assertFalse(self.rec()['inputs']['complete'], 'tried again by the next build')
        r = self.settle(self.sgdb([self.official]), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png'), 'the next build gets the pair')
        shutil.rmtree(self.art_dir); self.sips_fails_png = True   # sips cannot make a PNG of it
        r = self.settle(self.sgdb([self.official]), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('titledb', None))
        self.assertEqual(len([ln for ln in self.lines if ln.startswith('launcher logo: sips cannot convert')]), 1, self.lines)
        self.assertFalse(list(self.art_dir.glob('*.part*'))); self.assertFalse((self.art_dir / 'logo.png').exists())
        shutil.rmtree(self.art_dir); self.sips_fails_png = False   # the logo, then the hero fails: the banner, and the logo is dropped
        r = self.settle(self.sgdb([self.official], **{HERO: ga.FetchError('HTTP 503', status=503)}), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('titledb', None)); self.assertFalse((self.art_dir / 'logo.png').exists())
        self.assert_no_key()

    def test_given_logo(self):   # rule 4: --logo without a key goes over whatever art is settled, with a line when that is a titledb banner
        mine = self.tmp / 'mine.webp'; mine.write_bytes(b'webp')
        r = self.settle(self.sgdb(), logo=mine)
        self.assertEqual((r['source'], r['logo']), ('titledb', self.art_dir / 'logo.png'))
        self.assertIn(f'launcher logo: {mine} (art/logo.png)', self.lines)
        self.assertIn("launcher logo: the titledb banner already shows the game's logo; --logo is shown over it", self.lines)
        self.assertIn(['sips', '-s', 'format', 'png', '-Z', '1200', str(mine)], [a[:7] for a in self.argv])
        rec = self.rec(); self.assertEqual((rec['logo'], rec['inputs']['logo_given']['path']), ({'source': 'given', 'url': None}, str(mine)))
        self.argv.clear()
        self.assertEqual(self.settle(Net(), logo=mine), r); self.assertEqual(self.argv, [], 'the same file: reused')
        self.assertIn(f'launcher logo: {mine} (art/logo.png, as the last build made it)', self.lines)
        self.assertEqual(self.settle(Net(), logo=mine, online=False)['logo'], self.art_dir / 'logo.png', 'offline too')
        r = self.settle(self.sgdb())
        self.assertIsNone(r['logo']); self.assertFalse((self.art_dir / 'logo.png').exists(), 'without --logo: not wanted')
        self.settle(Net(), logo=self.tmp / 'missing.png', online=False)
        self.assertIn(f'launcher logo: no such file {self.tmp / "missing.png"} (--logo / LOGO)', self.lines)
        shutil.rmtree(self.art_dir)   # with a key: SteamGridDB's textless hero over the banner, and its logos are not asked for
        net = self.sgdb([self.official])
        r = self.settle(net, key=KEY, logo=mine)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png'))
        self.assertNotIn(f'{self.api}/logos/game/6', net.urls()); self.assertNotIn(BANNER, net.urls())
        self.assertFalse(any('already shows' in ln for ln in self.lines))
        self.assert_no_key()

    def test_given_art_takes_the_steamgriddb_logo(self):   # rule 1: the player's art; the logo is --logo, else SteamGridDB's with a key (its heroes are not asked for)
        img = self.tmp / 'art.png'; img.write_bytes(b'png')
        net = self.sgdb([self.official])
        r = self.settle(net, given=img, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('given', self.art_dir / 'logo.png'))
        self.assertNotIn(f'{self.api}/heroes/game/6', net.urls()); self.assertNotIn(BANNER, net.urls())
        self.assertEqual(self.settle(Net(), given=img, key=KEY), r, 'reused without the network')
        self.assertEqual(self.settle(Net(), given=img, key=KEY, online=False), r, 'offline too')
        r = self.settle(Net({ga.TITLEDB_URL: titledb()}), given=img)   # no key: no SteamGridDB logo, the name text
        self.assertIsNone(r['logo']); self.assertFalse((self.art_dir / 'logo.png').exists())
        self.assert_no_key()

    def test_key_newly_set(self):   # a build without a key settled the titledb banner; a key set since looks again, for the pair
        self.settle(self.sgdb())
        self.assertIsNone(self.settle(Net())['logo'], 'no key: as before, without the network')
        net = self.sgdb([self.official])
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png'))
        self.assertIn(f'{self.api}/search/autocomplete/{self.term}', net.urls())
        self.assertEqual(self.rec()['inputs']['asked'], {'art': False, 'logo': False, 'key': True}, 'what decided it: never the key itself')
        self.assert_no_key()

    def test_failed_lookup_keeps_the_pair(self):   # a lookup that did not go through (titledb down) is tried again; the network down then, the art and logo an earlier build downloaded stay
        down = ga.FetchError('<urlopen error [Errno 8] nodename nor servname provided>')
        r = self.settle(self.sgdb([self.official], **{ga.TITLEDB_URL: down}), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png')); self.assertFalse(self.rec()['inputs']['complete'])
        r = self.settle(Net({ga.TITLEDB_URL: down, f'{self.api}/search/autocomplete/{self.term}': down, BANNER: down}), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png'))
        self.assertIn('launcher logo: none online this time; keeping the SteamGridDB logo an earlier build downloaded (art/logo.png)', self.lines)
        self.assert_no_key()

    def test_failed_steamgriddb_keeps_the_pair(self):   # an incomplete pair (titledb was down) is looked up again; SteamGridDB failing then (HTTP 500, a logo download) keeps the pair, not the banner
        down = ga.FetchError('<urlopen error [Errno 8] nodename nor servname provided>')
        pair = dict(self.settle(self.sgdb([self.official], **{ga.TITLEDB_URL: down}), key=KEY), about=self.art_dir / 'about.json')   # titledb answers in the builds below: the About text too
        self.assertEqual((pair['source'], pair['logo']), ('steamgriddb', self.art_dir / 'logo.png')); self.assertFalse(self.rec()['inputs']['complete'])
        for why, more in (('failed: HTTP 500', {f'{self.api}/search/autocomplete/{self.term}': ga.FetchError('HTTP 500', status=500)}),
                          ('the logo failed', {LOGO: ga.FetchError('timed out')}), ('the hero image failed', {HERO: ga.FetchError('timed out')})):
            with self.subTest(why=why):
                net = self.sgdb([self.official], **more)
                self.assertEqual(self.settle(net, key=KEY), pair)
                self.assertNotIn(BANNER, net.urls(), 'the banner is not taken over the pair')
                self.assertIn(f'launcher art: none online this time (SteamGridDB: {why}); keeping the SteamGridDB hero an earlier build downloaded (art/art.jpg)', self.lines)
                self.assertTrue((self.art_dir / 'logo.png').is_file())
                rec = self.rec(); self.assertEqual((rec['source'], rec['logo']['source'], rec['inputs']['complete']), ('steamgriddb', 'steamgriddb', False), 'and the next build looks again')
        self.assertEqual(self.settle(self.sgdb([self.official]), key=KEY), pair)
        self.assertTrue(self.rec()['inputs']['complete'], 'SteamGridDB answers again: settled')
        self.fresh()   # no earlier pair: SteamGridDB failing is the banner, as before
        r = self.settle(self.sgdb([self.official], **{f'{self.api}/search/autocomplete/{self.term}': ga.FetchError('HTTP 500', status=500)}), key=KEY)
        self.assertEqual((r['source'], r['logo']), ('titledb', None))
        self.assert_no_key()

    def test_logo_toggled_over_given_art(self):   # --art with a key: --logo given, then dropped, looks SteamGridDB's logo up again (also after a build without the key, or an offline one with --logo)
        img, mine = self.tmp / 'art.png', self.tmp / 'mine.png'; img.write_bytes(b'png'); mine.write_bytes(b'png')
        sg = self.settle(self.sgdb([self.official]), given=img, key=KEY)
        self.assertEqual(self.rec()['logo'], {'source': 'steamgriddb', 'url': LOGO})
        net = Net()
        self.assertEqual(self.settle(net, given=img, key=KEY, logo=mine)['logo'], self.art_dir / 'logo.png'); self.assertEqual(net.calls, [])
        self.assertEqual(self.rec()['logo']['source'], 'given')
        net = self.sgdb([self.official])
        self.assertEqual(self.settle(net, given=img, key=KEY), sg, '--logo dropped: SteamGridDB\'s logo again')
        self.assertIn(f'{self.api}/logos/game/6', net.urls()); self.assertEqual(self.rec()['logo'], {'source': 'steamgriddb', 'url': LOGO})
        self.assertIsNone(self.settle(Net(), given=img)['logo'], 'no key: no SteamGridDB logo')
        net = self.sgdb([self.official])
        self.assertEqual(self.settle(net, given=img, key=KEY), sg, 'the key again: looked up again'); self.assertIn(f'{self.api}/logos/game/6', net.urls())
        self.settle(Net(), given=img, key=KEY, logo=mine, online=False)
        self.assertEqual(self.rec()['logo']['source'], 'given')
        net = self.sgdb([self.official])
        self.assertEqual(self.settle(net, given=img, key=KEY), sg, 'after an offline build with --logo too'); self.assertIn(f'{self.api}/logos/game/6', net.urls())
        net = Net()
        self.assertEqual(self.settle(net, given=img, key=KEY), sg); self.assertEqual(net.calls, [], 'then settled: no request')
        self.settle(Net(), key=KEY, logo=mine, online=False)   # no --art either: the pair is looked up again
        net = self.sgdb([self.official])
        r = self.settle(net, key=KEY)
        self.assertEqual((r['source'], r['logo']), ('steamgriddb', self.art_dir / 'logo.png')); self.assertEqual(self.rec()['logo'], {'source': 'steamgriddb', 'url': LOGO})
        self.assert_no_key()

    def test_smaller_image_not_enlarged(self):   # sips -Z enlarges too: an image smaller than the limit is converted without it, a larger one (or one sips cannot measure) with it
        self.sips_size = (600, 200)
        self.settle(self.sgdb([self.official]), key=KEY)
        conv = [a for a in self.argv if a[:2] == ['sips', '-s']]
        self.assertEqual(len(conv), 2); self.assertFalse(any('-Z' in a for a in conv), conv)
        self.assertEqual([a[-1] for a in self.sizes], [a[-3] for a in conv], 'each image is measured first')
        self.fresh(); self.argv.clear(); self.sips_size = (1600, 400)   # larger than a logo's limit, smaller than the art's
        self.settle(self.sgdb([self.official]), key=KEY)
        self.assertEqual([a[3:6] for a in self.argv if a[:2] == ['sips', '-s']], [['png', '-Z', '1200'], ['jpeg', str(self.tmp / 'build/art') + f'/download.{os.getpid()}.part', '--out']])


def png(w, h, alpha=False):   # a tiny RGB (or RGBA, half transparent) PNG, without an imaging package
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    raw = b''.join(b'\0' + (b'\x80\x40\x20\x80' if alpha else b'\x80\x40\x20') * w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6 if alpha else 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def webp(w, h, rgba):   # a lossless (VP8L) WebP of one color with alpha, without an encoder: one symbol per prefix code, so the pixels take no bits
    bits = []
    def put(v, n): bits.extend((v >> i) & 1 for i in range(n))
    put(w - 1, 14); put(h - 1, 14); put(1, 1); put(0, 3)   # size, alpha used, version 0
    put(0, 1); put(0, 1); put(0, 1)   # no transform, no color cache, no meta prefix codes
    r, g, b, a = rgba
    for sym in (g, r, b, a, 0):   # green, red, blue, alpha, distance: each a simple code of one 8-bit symbol
        put(1, 1); put(0, 1); put(1, 1); put(sym, 8)
    bits += [0] * (-len(bits) % 8)
    data = b'\x2f' + bytes(sum(bits[i + j] << j for j in range(8)) for i in range(0, len(bits), 8))
    chunk = b'VP8L' + struct.pack('<I', len(data)) + data + b'\0' * (len(data) % 2)
    return b'RIFF' + struct.pack('<I', 4 + len(chunk)) + b'WEBP' + chunk


class ChildEnv(unittest.TestCase):   # sips and curl run without the key in their environment, though the caller's has it (STEAMGRIDDB_KEY, how the build is given one)
    def test_run_leaves_the_key_out(self):
        with mock.patch.dict(os.environ, {'STEAMGRIDDB_KEY': KEY, 'GAME_ART_TEST_MARK': '1'}):
            r = ga.run([sys.executable, '-c', 'import json, os; print(json.dumps(dict(os.environ)))'], capture_output=True, text=True, check=True)
            self.assertIn('STEAMGRIDDB_KEY', os.environ, 'the caller\'s environment is left as it is')
        env = json.loads(r.stdout)
        self.assertFalse(KEY in r.stdout); self.assertFalse('STEAMGRIDDB_KEY' in env); self.assertEqual(env.get('GAME_ART_TEST_MARK'), '1')
        self.assertEqual(ga.child_env({'STEAMGRIDDB_KEY': KEY, 'PATH': '/usr/bin'}), {'PATH': '/usr/bin'})


@unittest.skipUnless(shutil.which('sips'), 'sips is macOS\'s')
class RealSips(unittest.TestCase):
    def test_convert(self):
        with tempfile.TemporaryDirectory() as t:
            src, dst, lines = Path(t) / 'a.png', Path(t) / 'art.jpg', []
            src.write_bytes(png(40, 20))
            self.assertTrue(ga.convert(src, dst, lines.append), lines)
            self.assertEqual(dst.read_bytes()[:2], b'\xff\xd8')
            bad = Path(t) / 'bad.png'; bad.write_bytes(b'not an image')
            self.assertFalse(ga.convert(bad, Path(t) / 'b.jpg', lines.append))
            self.assertTrue(lines and lines[-1].startswith('launcher art: sips cannot convert bad.png'), lines)
            self.assertEqual(sorted(p.name for p in Path(t).iterdir()), ['a.png', 'art.jpg', 'bad.png'])

    def test_convert_logo(self):   # a PNG with alpha stays a PNG with alpha (color type 6), longest side at most 1200
        with tempfile.TemporaryDirectory() as t:
            src, dst, lines = Path(t) / 'logo.webp.png', Path(t) / 'logo.png', []
            src.write_bytes(png(1600, 40, alpha=True))
            self.assertTrue(ga.convert_logo(src, dst, lines.append), lines)
            data = dst.read_bytes()
            self.assertEqual(data[:8], ga.PNG_MAGIC)
            w, h, _, color = struct.unpack('>IIBB', data[16:26])
            self.assertEqual((w, h, color), (1200, 30, 6))
            bad = Path(t) / 'bad.png'; bad.write_bytes(b'not an image')
            self.assertFalse(ga.convert_logo(bad, Path(t) / 'b.png', lines.append))
            self.assertTrue(lines and lines[-1].startswith('launcher logo: sips cannot convert bad.png to a PNG'), lines)

    def test_smaller_not_enlarged(self):   # sips -Z enlarges a smaller image too: a 100 x 40 logo and a 640 x 360 art stay their size
        with tempfile.TemporaryDirectory() as t:
            lines = []
            (Path(t) / 'small.png').write_bytes(png(100, 40, alpha=True))
            self.assertTrue(ga.convert_logo(Path(t) / 'small.png', Path(t) / 'logo.png', lines.append), lines)
            self.assertEqual(struct.unpack('>IIBB', (Path(t) / 'logo.png').read_bytes()[16:26]), (100, 40, 8, 6))
            (Path(t) / 'art.png').write_bytes(png(640, 360))
            self.assertTrue(ga.convert(Path(t) / 'art.png', Path(t) / 'art.jpg', lines.append), lines)
            self.assertEqual(ga._longest(Path(t) / 'art.jpg'), 640)

    def test_convert_webp_logo(self):   # SteamGridDB serves WebP logos too: a lossless WebP with alpha becomes a PNG with alpha (color type 6), its size kept
        with tempfile.TemporaryDirectory() as t:
            src, dst, lines = Path(t) / 'logo.webp', Path(t) / 'logo.png', []
            src.write_bytes(webp(300, 100, (255, 255, 255, 128)))
            if ga._longest(src) != 300: self.skipTest('this sips cannot read WebP')
            self.assertTrue(ga.convert_logo(src, dst, lines.append), lines)
            data = dst.read_bytes()
            self.assertEqual(data[:8], ga.PNG_MAGIC)
            self.assertEqual(struct.unpack('>IIBB', data[16:26]), (300, 100, 8, 6))


if __name__ == '__main__':
    unittest.main()
