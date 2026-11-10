"""Depth-only pairs in the pipeline archive made offline (dm/gfx/tools/pso_offline.py): a pair with no pixel key is a depth-only program's, and its base takes the host's empty fragment
(dm_nop of dm/gfx/msl/nop_frag.metal), as the host's pso_desc4 and pre_desc give it (Metal 4 needs a fragment function whenever rasterization is on). That library is compiled
with the build as the host compiles it (host_msl.py: the platform's SDK, the host's minimum OS), and the archive's key takes its function hashes, not its bytes, which each compile
changes. Without such pairs nothing is compiled and no archive's key changes. The last test compiles the library for real and compares its function hash with the host's own
(the header dm/host/gen/msl-<sdk>/host_msl_gen.h), when Xcode and that header are there."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('pso_offline', REPO / 'dm/gfx/tools/pso_offline.py')
assert spec and spec.loader
po = importlib.util.module_from_spec(spec); spec.loader.exec_module(po)
CHAIN = '0123456789ab'


def tag(name, data): return name + struct.pack('<H', len(data)) + data


def metallib(funcs, salt=b'', code=b''):
    """A .metallib header: the function list (per function NAME, a HASH of its name and code, ENDT) and the public metadata (CNST for a function with constants); funcs: [(name, has
    constants)]. salt: bytes after the header, as the identifier a real compile writes differs each time"""
    fl = struct.pack('<I', len(funcs))
    for name, _ in funcs:
        body = tag(b'NAME', name.encode() + b'\0') + tag(b'TYPE', b'\1') + tag(b'HASH', (name.encode() + code).ljust(32, b'#')) + b'ENDT'
        fl += struct.pack('<I', 4 + len(body)) + body
    pm = b''
    for _, const in funcs:
        body = (tag(b'CNST', b'\x01\x00c\x00\x35\xff\xff\x00') if const else b'') + b'ENDT'
        pm += struct.pack('<I', len(body)) + body
    fo = 0x58; po_ = fo + len(fl)
    head = b'MTLB' + b'\0' * 0x14 + struct.pack('<QQQQ', fo, len(fl), po_, len(pm))
    head += b'\0' * (fo - len(head))
    return head + fl + pm + salt + b'BC\xc0\xde'


def host_header_lib(sdk, name):
    """The bytes of the host library name in the host's generated header for sdk, or None"""
    h = REPO / 'dm/host/gen' / f'msl-{sdk}' / 'host_msl_gen.h'
    if not h.is_file(): return None
    m = re.search(rf'k_host_msl_lib_{name}\[\] = \{{([0-9,]+)\}};', h.read_text())
    return bytes(int(x) for x in m.group(1).split(',')) if m else None


class Plan(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp()) / f'b-{CHAIN}'; self.d.mkdir(); self.addCleanup(shutil.rmtree, self.d.parent)

    def shader(self, key, j, libs):
        (self.d / f'{key}_b.json').write_text(json.dumps(dict({'chain': CHAIN, 'entry': 'main0'}, **j)))
        for suf, funcs in libs.items(): (self.d / f'{key}{suf}.metallib').write_bytes(metallib(funcs))

    def test_read_pairs_keeps_an_empty_pixel_key(self):   # pre_parse: "v<TAB>" is the pair (v, "")
        self.assertEqual(po.read_pairs(b'# h\nv\t\nv\tf\nv\t\n'), [('v', ''), ('v', 'f')])

    def test_depth_only_bases(self):
        vz = [('main0', False), ('main0_z', False)]
        self.shader('pull', {'entry_z': 'main0_z', 'pull': {'entry': 'main0'}, 'vertex_inputs': [{'location': 0}]}, {'_b': vz, '_bp': vz})
        self.shader('plain', {'entry_z': 'main0_z', 'vertex_inputs': []}, {'_b': vz})
        self.shader('inputs', {'vertex_inputs': [{'location': 0}]}, {'_b': vz})
        self.shader('layer', {'pull': {}, 'layer_out': True}, {'_b': vz, '_bp': vz})
        self.shader('const', {}, {'_b': [('main0', True)]})
        self.shader('mesh', {'mesh_stage': {'kind': 'ms'}}, {'_b': vz})
        self.shader('fs', {}, {'_b': [('main0', False)]})
        pairs = [('pull', ''), ('plain', ''), ('inputs', ''), ('layer', ''), ('const', ''), ('mesh', ''), ('gone', ''), ('pull', 'fs'), ('pull', '')]
        bases, rest, left = po.plan(self.d, CHAIN, pairs, False)
        self.assertEqual(bases, [('pull_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY), ('plain_b', 'main0', po.NOP_LIB, po.NOP_ENTRY), ('pull_bp', 'main0', 'fs_b', 'main0')])
        self.assertEqual(rest, [('const', '')])   # a vertex function with constants: left to the device, as other pairs
        self.assertEqual({k: v for k, v in left.items() if v}, {'reflection': 1, 'mesh': 1, 'stage inputs': 1, 'layer': 1})
        bases, _, _ = po.plan(self.d, CHAIN, [('pull', ''), ('plain', '')], True)   # near = 0: the entry_z entries
        self.assertEqual(bases, [('pull_bp', 'main0_z', po.NOP_LIB, po.NOP_ENTRY), ('plain_b', 'main0_z', po.NOP_LIB, po.NOP_ENTRY)])

    def test_script_names_the_compiled_host_library(self):
        nop = self.d.parent / 'host' / f'{po.NOP_LIB}.metallib'; nop.parent.mkdir(); nop.write_bytes(metallib([(po.NOP_ENTRY, False)]))
        with mock.patch.dict(po.HOST_LIBS, {po.NOP_LIB: str(nop)}, clear=True):
            j = po.script(self.d, [('v_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY)])
            real = po.real_libraries(self.d, [('v_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY)], self.d.parent / 'work')
        self.assertEqual({l['label']: l['path'] for l in j['libraries']}, {'v_bp': str(self.d.resolve() / 'v_bp.metallib'), po.NOP_LIB: str(nop.resolve())})
        p = j['pipeline_descriptors']['render_pipeline_descriptors'][0]
        self.assertEqual((p['vertex_function_descriptor'], p['fragment_function_descriptor']), ('fnd:v_bp.main0', f'fnd:{po.NOP_LIB}.{po.NOP_ENTRY}'))
        self.assertTrue(all(v == 'Unspecialized' for a in p['color_attachments'] for v in a.values()))   # the base's colour state stays open, as for any other pair
        self.assertEqual(real, self.d)   # a library folder is taken in place


class HostLibrary(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t); self.calls = []
        self.addCleanup(po.HOST_LIBS.clear)

    def fake_run(self, cmd, **kw):
        cmd = [str(c) for c in cmd]; self.calls.append(cmd)
        Path(cmd[cmd.index('-o') + 1]).write_bytes(metallib([(po.NOP_ENTRY, False)], os.urandom(16)))
        return subprocess.CompletedProcess(cmd, 0, '', '')

    def test_compiled_as_the_host_compiles_it(self):   # host_msl.py's command: the platform's SDK, the host's minimum (MSL_MIN_<sdk> of dm/host/Makefile) and its language
        self.assertIn(f"STD = '{po.HOST_MSL_STD}'", (REPO / 'dm/gfx/tools/host_msl.py').read_text())
        mk = (REPO / 'dm/host/Makefile').read_text()
        self.assertRegex(mk, r'(?m)^MSL_MIN_macosx\s*=\s*\$\(MACOS_MIN\)')   # host_msl_min reads MACOS_MIN for the Mac because the Makefile does
        ios, mac = re.search(r'(?m)^MSL_MIN_iphoneos\s*=\s*(\S+)', mk), re.search(r'(?m)^MACOS_MIN\s*:?=\s*(\S+)', (REPO / 'dm/mac/min_os.mk').read_text())
        assert ios and mac; ios, mac = ios.group(1), mac.group(1)
        base = [('v_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY)]
        with mock.patch.object(po.subprocess, 'run', self.fake_run):
            po.host_libraries(base, 'ios', self.t)
            po.host_libraries(base, 'macos', self.t)
        out, src = str(self.t / 'host' / f'{po.NOP_LIB}.metallib'), str(REPO / 'dm/gfx/msl/nop_frag.metal')
        self.assertEqual(self.calls, [['xcrun', '-sdk', 'iphoneos', 'metal', f'-mios-version-min={ios}', '-std=metal4.1', '-o', out, src],
                                      ['xcrun', '-sdk', 'macosx', 'metal', f'-mmacosx-version-min={mac}', '-std=metal4.1', '-o', out, src]])
        self.assertEqual(po.HOST_LIBS, {po.NOP_LIB: out})

    def test_none_without_depth_only_pairs(self):
        with mock.patch.object(po.subprocess, 'run', self.fake_run): po.host_libraries([('v_bp', 'main0', 'f_b', 'main0')], 'ios', self.t)
        self.assertEqual((self.calls, po.HOST_LIBS), ([], {}))

    def test_a_failed_compile_stops(self):
        with mock.patch.object(po.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'no toolchain')), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as e: po.host_libraries([('v_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY)], 'ios', self.t)
        self.assertIn('no toolchain', str(e.exception.code))

    def real_hash(self, platform, sdk):
        host = host_header_lib(sdk, 'nop_frag')
        if host is None: self.skipTest(f'no host header for {sdk} (make -C dm/host host_msl MSL_SDK={sdk})')
        if subprocess.run(['xcrun', '-sdk', sdk, 'metal', '--version'], capture_output=True).returncode: self.skipTest('no Metal compiler')
        po.host_libraries([('v_bp', 'main0', po.NOP_LIB, po.NOP_ENTRY)], platform, self.t)
        (self.t / 'host.metallib').write_bytes(host)
        self.assertEqual(po.functions(po.HOST_LIBS[po.NOP_LIB], hashes=True), po.functions(self.t / 'host.metallib', hashes=True),
                         f'the offline empty fragment must be the function the host loads ({sdk}): rebuild the host header if the toolchain or minimum changed')

    @unittest.skipUnless(shutil.which('xcrun'), 'needs Xcode')
    def test_same_function_as_the_hosts_mac(self): self.real_hash('macos', 'macosx')

    @unittest.skipUnless(shutil.which('xcrun'), 'needs Xcode')
    def test_same_function_as_the_hosts_ios(self): self.real_hash('ios', 'iphoneos')


class Build(unittest.TestCase):
    """main with depth-only pairs: the host library is compiled, the bases name it, and the archive is reused while its function hash holds"""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.t); self.addCleanup(po.HOST_LIBS.clear)
        self.lib = self.t / f'b-{CHAIN}'; self.lib.mkdir()
        for k, j, funcs in (('v', {'pull': {}}, [('main0', False)]), ('f', {}, [('main0', False)])):
            (self.lib / f'{k}_b.json').write_text(json.dumps(dict({'chain': CHAIN, 'entry': 'main0'}, **j)))
            (self.lib / f'{k}_b.metallib').write_bytes(metallib(funcs))
        (self.lib / 'v_bp.metallib').write_bytes(metallib([('main0', False)]))
        self.prof = self.t / 'games/0100000000001000'; self.prof.mkdir(parents=True)
        (self.prof / 'game.tsv').write_text('title_id\t0100000000001000\nname\tTest\n')
        self.out, self.work, self.calls, self.code = self.t / 'out', self.t / 'work', [], b''

    def fake_run(self, cmd, **kw):
        cmd = [str(c) for c in cmd]
        if '-version' in cmd: return subprocess.CompletedProcess(cmd, 0, 'AIR-TT 1.0\n', '')
        self.calls.append(cmd)
        o = Path(cmd[cmd.index('-o') + 1])
        if 'metal-tt' in cmd: o.write_bytes(b'archive')
        else: o.write_bytes(metallib([(po.NOP_ENTRY, False)], os.urandom(16), self.code))
        return subprocess.CompletedProcess(cmd, 0, '', '')

    def main(self, pairs):
        (self.prof / 'shader_pairs.tsv').write_text(pairs)
        args = ['--game', '0100000000001000', '--msl', str(self.lib), '--out', str(self.out), '--work', str(self.work), '--no-compute', '--no-mesh']
        with mock.patch.object(po.subprocess, 'run', self.fake_run), mock.patch.dict(os.environ, DM_GAMES_DIR=str(self.prof.parent)), contextlib.redirect_stdout(io.StringIO()):
            return po.main(args)

    def tt(self): return [c for c in self.calls if 'metal-tt' in c]

    def test_depth_only_pair_builds_with_the_empty_fragment_and_reuses(self):
        self.assertEqual(self.main('v\tf\nv\t\n'), 0)
        self.assertEqual(len(self.tt()), 1)
        script = json.loads(Path(self.tt()[0][8]).read_text())
        self.assertEqual([p['fragment_function_descriptor'] for p in script['pipeline_descriptors']['render_pipeline_descriptors']], ['fnd:f_b.main0', f'fnd:{po.NOP_LIB}.{po.NOP_ENTRY}'])
        self.assertIn('bases\t2\n', (self.out / 'archive.tsv').read_text())
        self.assertEqual(self.main('v\tf\nv\t\n'), 0)   # compiled again, with another identifier, the same function: reused
        self.assertEqual(len(self.tt()), 1)
        self.code = b'@27.4'   # another compiler or minimum: another function hash, built again
        self.assertEqual(self.main('v\tf\nv\t\n'), 0)
        self.assertEqual(len(self.tt()), 2)

    def test_no_depth_only_pair_compiles_no_host_library(self):   # every archive made before keeps its key
        self.assertEqual(self.main('v\tf\n'), 0)
        self.assertEqual([c for c in self.calls if 'metal-tt' not in c], [])
        script = json.loads(Path(self.tt()[0][8]).read_text())
        self.assertEqual([l['label'] for l in script['libraries']], ['v_bp', 'f_b'])


if __name__ == '__main__':
    unittest.main()
