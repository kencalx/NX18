"""Saved diagnostics are filtered only for the opt-in player IPA."""
import pathlib
import re
import subprocess
import tempfile
import unittest


class PlayerEnvironment(unittest.TestCase):
    def test_overlays_and_player_options_survive(self):
        header = pathlib.Path(__file__).resolve().parents[2] / 'ios/Sources/player_env.h'
        source = r'''
#include <assert.h>
#include "player_env.h"
int main(void) {
 const char *drop[]={"DM_NVN_CPUPROF","DM_NVN_TSV","DM_NVN_PASSDUMP_ALL",
   "DM_NVN_GEOMETRY_PACK","DM_NVN_SHMAP","DM_NVN_ZBLOCK","DM_NVN_ENC_THREAD_PROBE","DM_CTL",
   "DM_TEST_UP_LOST","MTL_DEBUG_LAYER","MTL_SHADER_VALIDATION","DM_MSL_DIR",
   "DM_NVN_PROF","DM_NVN_TSV_CALLS","DM_NVN_WAITS_X","DM_NVN_WAIT","DM_PROBE","DM_DETCLOCK"};
 const char *keep[]={"DM_SHOW_FPS","DM_METAL_HUD","MTL_HUD_ENABLED",
   "DM_FPS_TARGET","DM_DYNAMIC_RESOLUTION","DM_OPMODE","DM_RENDER_SCALE","DM_LANG","DM_RT",
   "DM_TOUCH_HAPTICS","DM_RUMBLE","DM_SAVE","DM_ROMFS","DM_NVN_ENC_THREAD","DM_DEPTH_BOUNDS",
   "DM_NVN_WAITS","DM_SLOWFRAME","DM_REPLAY_RT","DM_REPLAY_SPARES","DM_FPS_HOLD_BACKOFF","DM_FPS_RESUME","DM_MOVIE_RESTART","DM_FIELD_LOG","DM_FRAME_WG"};
 for(unsigned i=0;i<sizeof drop/sizeof *drop;i++)assert(dm_player_diagnostic_key(drop[i]));
 for(unsigned i=0;i<sizeof keep/sizeof *keep;i++)assert(!dm_player_diagnostic_key(keep[i]));
 // the whole line: DM_SLOWFRAME kept only with a value that is not empty or zeros (slow_on takes any value as on)
 assert(dm_player_env_dropped("DM_SLOWFRAME","0")&&dm_player_env_dropped("DM_SLOWFRAME","")&&dm_player_env_dropped("DM_SLOWFRAME","00"));
 assert(!dm_player_env_dropped("DM_SLOWFRAME","1")&&!dm_player_env_dropped("DM_SLOWFRAME","10"));
 assert(!dm_player_env_dropped("DM_NVN_WAITS","0")&&!dm_player_env_dropped("DM_REPLAY_RT","0")&&!dm_player_env_dropped("DM_REPLAY_SPARES","0"));   // the off side of an A/B is kept
 assert(!dm_player_env_dropped("DM_FRAME_WG","1")&&!dm_player_env_dropped("DM_FRAME_WG","0"));   // a test arm no filter names: it reaches a player build
 assert(dm_player_env_dropped("DM_NVN_PROF","1")&&!dm_player_env_dropped("DM_SHOW_FPS","0"));
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = pathlib.Path(tmp) / 'test.c'
            exe = pathlib.Path(tmp) / 'test'
            c.write_text(source)
            subprocess.run(['cc', '-Wall', '-Werror', '-I', str(header.parent), str(c), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_kept_switches_are_documented_and_not_launcher_rows(self):   # an env.txt line the player build keeps: in docs/env_switches.tsv and the development guide's list, and no launcher row (main.m drops those too)
        repo = pathlib.Path(__file__).resolve().parents[3]
        header = (repo / 'dm/ios/Sources/player_env.h').read_text()
        kept = re.findall(r'"(DM_[A-Z0-9_]+)"', header[header.index('dm_player_kept_keys'):header.index('dm_player_diagnostic_key')])
        self.assertEqual(sorted(kept), sorted(['DM_NVN_WAITS', 'DM_SLOWFRAME', 'DM_REPLAY_RT', 'DM_REPLAY_SPARES', 'DM_FPS_HOLD_BACKOFF', 'DM_FPS_RESUME', 'DM_MOVIE_RESTART', 'DM_FIELD_LOG']))
        switches = {l.split('\t')[0] for l in (repo / 'docs/env_switches.tsv').read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')}
        rows = {l.split('\t')[0] for l in (repo / 'dm/games/settings.tsv').read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')}
        guide = (repo / 'docs/development.md').read_text(encoding='utf-8')
        for k in kept:
            self.assertIn(k, switches, k); self.assertNotIn(k, rows, k); self.assertIn(f'`{k}`', guide, k)
