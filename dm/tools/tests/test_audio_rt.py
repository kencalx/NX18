"""The real-time safety marks on the AudioUnit render callback (dm/host/rt_safe.h, dm/host/hle_audio.c) and the lint that checks them (dm/tools/lint_c.py, .clang-tidy):
au_render, pull_device and pull carry RT_NONBLOCKING, which is clang's `nonblocking` only where the compiler has it; every call they make that the analysis cannot prove
safe is marked RT_ACCEPTED with its reason, and only the three known ones are; lint-c compiles hle_audio.c alone with -Wfunction-effects and keeps its findings.

What this cannot run: clang's function effect analysis itself, which the lint-c job runs with LLVM's clang-tidy on the macOS SDK (no finding, so none in the baseline)."""
from pathlib import Path
import re
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import lint_c  # noqa: E402

RT = ('static OSStatus au_render(void *ctx, AudioUnitRenderActionFlags *f, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *bl)',
      'static void pull_device(aout *a, uint8_t *dst, uint64_t bytes)', 'static void pull(aout *a, uint8_t *dst, uint64_t n)')


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


def accepted(src):
    """Each RT_ACCEPTED("reason" "...", statements) in src as (reason, statements)"""
    out = []
    for m in re.finditer(r'RT_ACCEPTED\(', src):
        i, depth = m.end(), 1
        for k in range(i, len(src)):
            depth += {'(': 1, ')': -1}.get(src[k], 0)
            if not depth: break
        arg = src[i:k]
        lits = re.match(r'\s*((?:"(?:[^"\\]|\\.)*"\s*)+),', arg)
        assert lits, arg   # the reason: string literals, then the statements
        reason = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', lits.group(1)))
        out.append((reason, arg[lits.end():]))
    return out


class RenderCallback(unittest.TestCase):
    def setUp(self):
        self.audio = read('dm/host/hle_audio.c'); self.rt = read('dm/host/rt_safe.h')

    def test_the_macro_is_the_attribute_only_where_the_compiler_has_it(self):
        self.assertIn('#ifndef RT_NONBLOCKING\n#if defined(__has_attribute)\n#if __has_attribute(nonblocking)\n#define RT_NONBLOCKING __attribute__((nonblocking))\n#endif\n#endif\n#endif\n'
                      '#ifndef RT_NONBLOCKING\n#define RT_NONBLOCKING\n#endif\n', self.rt)
        acc = self.rt[self.rt.index('#define RT_ACCEPTED(why, ...)'):]
        for part in ('_Pragma("clang diagnostic push")', '_Pragma("clang diagnostic ignored \\"-Wfunction-effects\\"")', '_Pragma("clang diagnostic pop")',
                     '_Static_assert(sizeof("" why) > 1'):   # clang's documented exemption, and a reason that must be a non-empty string literal
            self.assertIn(part, acc)

    def test_the_three_functions_are_marked(self):
        self.assertIn('#include "rt_safe.h"', self.audio)
        for header in RT:
            with self.subTest(header=header):
                self.assertIn(header + ' RT_NONBLOCKING {', self.audio)
        self.assertEqual(self.audio.count(' RT_NONBLOCKING {'), 3)
        self.assertIn('pull_device(a, bl->mBuffers[0].mData, bl->mBuffers[0].mDataByteSize);', body(self.audio, RT[0]))
        self.assertIn('pull(a, dst, bytes); return;', body(self.audio, RT[1]))

    def test_only_the_known_calls_are_accepted_each_with_a_reason(self):
        found = [(r, ' '.join(re.sub(r'//[^\n]*', '', s).split())) for h in RT for r, s in accepted(body(self.audio, h))]
        self.assertEqual([s for _, s in found], ['die("AudioOut released queue overflow");',
                                                 'if (a->event) notify_release(a); if (a->rel_sem) dispatch_semaphore_signal(a->rel_sem);'])
        for reason, _ in found: self.assertGreater(len(reason), 80, reason)
        self.assertEqual(self.audio.count('RT_ACCEPTED('), 2)   # none outside the callback's functions either
        self.assertIn('dispatch_semaphore_signal(a->notify_sem);', body(self.audio, 'static void notify_release(aout *a) {'))   # all notify_release does

    def test_lint_c_checks_hle_audio_c_with_function_effects(self):
        self.assertEqual(lint_c.DIAG_FLAGS, {'dm/host/hle_audio.c': ('-Wfunction-effects',)})
        self.assertIn('clang-diagnostic-function-effects', lint_c.KEPT_DIAGS)
        checks = re.findall(r'^  - (\S+)', read('.clang-tidy'), re.M)
        for c in lint_c.KEPT_DIAGS: self.assertIn(c, checks)   # clang-tidy drops a compiler warning its checks do not name
        self.assertNotIn('dm/host/hle_audio.c\tclang-diagnostic-function-effects', read('dm/tools/lint_c_baseline.tsv'))   # none: any finding fails


if __name__ == '__main__':
    unittest.main()
