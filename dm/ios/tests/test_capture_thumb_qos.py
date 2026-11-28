"""A screenshot's notice thumbnail at utility QoS (DmCapture.m capture_thumb_qos, DM_CAPTURE_THUMB_QOS): the screenshot path dispatches at that QoS, and the function, compiled on
its own from the source, answers QOS_CLASS_UTILITY by default and QOS_CLASS_USER_INITIATED with the switch at 0."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[i:k + 1]
    raise AssertionError(header)


class CaptureThumbQos(unittest.TestCase):
    def setUp(self):
        self.src = (REPO / 'dm/ios/Sources/DmCapture.m').read_text(encoding='utf-8')

    def test_screenshot_uses_it(self):
        shot = body(self.src, 'void dm_capture_screenshot(UIView *over)')
        self.assertIn('dispatch_get_global_queue(capture_thumb_qos(), 0)', shot)
        self.assertNotIn('QOS_CLASS_USER_INITIATED', shot)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS toolchain')
    def test_switch(self):
        fn = body(self.src, 'static qos_class_t capture_thumb_qos(void)')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp); c = tmp / 'qos.c'; exe = tmp / 'qos'
            c.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <dispatch/dispatch.h>\n' + fn +
                         '\nint main(void) { qos_class_t q = capture_thumb_qos(); puts(q == QOS_CLASS_UTILITY ? "utility" : q == QOS_CLASS_USER_INITIATED ? "user-initiated" : "other"); return 0; }\n')
            r = subprocess.run(['xcrun', 'clang', '-o', str(exe), str(c)], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr)
            env = {k: v for k, v in os.environ.items() if k != 'DM_CAPTURE_THUMB_QOS'}
            self.assertEqual(subprocess.run([str(exe)], capture_output=True, text=True, env=env).stdout.strip(), 'utility')
            self.assertEqual(subprocess.run([str(exe)], capture_output=True, text=True, env={**env, 'DM_CAPTURE_THUMB_QOS': '1'}).stdout.strip(), 'utility')
            self.assertEqual(subprocess.run([str(exe)], capture_output=True, text=True, env={**env, 'DM_CAPTURE_THUMB_QOS': '0'}).stdout.strip(), 'user-initiated')


if __name__ == '__main__':
    unittest.main()
