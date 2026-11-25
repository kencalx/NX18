"""DM_NVN_PREDICT=0 must turn the pipeline prediction off on every path that runs it.

Mario Kart World on an iPhone draws new pipelines with stand-ins (hybrid pipelines); the
replay on that path ignored the switch and cost the submit thread 70-220 ms in a frame.
"""
import pathlib
import re
import unittest

SRC = pathlib.Path(__file__).resolve().parents[1] / "nvn" / "nvn_mtl.m"


class PredictSwitch(unittest.TestCase):
    def setUp(self):
        self.src = SRC.read_text()

    def test_every_replay_call_checks_the_switch(self):
        calls = [m for m in re.finditer(r"pso_predict_rest\(\);", self.src)]
        guarded = 0
        for m in calls:
            line = self.src[self.src.rfind("\n", 0, m.start()) + 1:self.src.find("\n", m.end())]
            if line.lstrip().startswith("static void pso_predict_rest"):
                continue  # the definition
            prev = self.src[max(0, m.start() - 400):m.start()]
            self.assertIn("predict_on()", line + prev,
                          "pso_predict_rest() runs without checking DM_NVN_PREDICT: " + line.strip())
            guarded += 1
        self.assertGreaterEqual(guarded, 2)

    def test_switch_read_in_one_place(self):
        self.assertEqual(self.src.count('getenv("DM_NVN_PREDICT")'), 1)

    def test_hybrid_skips_attachment_guesses(self):
        self.assertIn("if (hy && i >= na) continue;", self.src)


if __name__ == "__main__":
    unittest.main()
