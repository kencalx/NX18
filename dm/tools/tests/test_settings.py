"""Offer the resolution control only when the rewritten build supports it, and the game's upscaler choice only to games whose shader map holds their own upscaler (an NDSR pack's network: game.py upscaler_keys)."""
from pathlib import Path
import sys,tempfile,unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'games'))
import settings

class ResolutionSetting(unittest.TestCase):
    def test_verified_rewrite_required(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            p=Path(tmp)/'main.fixups.tsv'
            for header,supported in [('# BUILD_ID\t3c10ec35c5ef4c3686b4053afb0e58e7\n',False),
                                     ('# DYNAMIC_RESOLUTION\t1\n',True),('',False)]:
                p.write_text(header)
                rows=settings.build('010056B015FE8000',tmp,'unused')['settings']
                dr=[s for s in rows if s['env']=='DM_DYNAMIC_RESOLUTION']
                self.assertEqual(bool(dr),supported)
                if dr:self.assertEqual((dr[0]['kind'],dr[0]['default']),('toggle','1'))   # on by default: Balanced is 60 fps with dynamic resolution (owner, 2026-11-21)
                fps=next(s for s in rows if s['env']=='DM_FPS_TARGET')
                self.assertEqual(fps['default'],'60')
                self.assertEqual(fps['options'],[['30','30 fps'],['60','60 fps']])

class FrameRateOption(unittest.TestCase):
    def test_120_only_on_the_mac_for_a_game_checked_at_that_speed(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            (Path(tmp)/'main.fixups.tsv').write_text('')
            for gid,platform,has in [('04007EF01F8AE000','mac',True),('04007EF01F8AE000','ios',False),('010056B015FE8000','mac',False)]:   # Fortune's Weave (fps_max 120), NieR:Automata (none)
                with patch.dict(settings.os.environ,{'SETTINGS_PLATFORM':platform}):
                    fps=next(s for s in settings.build(gid,tmp,'unused')['settings'] if s['env']=='DM_FPS_TARGET')
                self.assertEqual(fps['default'],'60',gid)
                self.assertEqual(fps['options'],[['30','30 fps'],['60','60 fps']]+([['120','120 fps']] if has else []),(gid,platform))

class UpscalerSetting(unittest.TestCase):
    def test_only_for_games_naming_their_upscaler(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            (Path(tmp)/'main.fixups.tsv').write_text('')
            for gid,shown in [('040074A01BF12000',True),('040077201BE50000',True),('010056B015FE8000',False)]:   # Donkey Kong Bananza (agl's NDSR pack), Kirby Air Riders (the pack under its own name), NieR:Automata (none)
                up=[s for s in settings.build(gid,tmp,'unused')['settings'] if s['env']=='DM_UPSCALER']
                self.assertEqual(bool(up),shown,gid)
                if up:self.assertEqual((up[0]['default'],up[0]['options']),('metalfx',[['game',"Game's own"],['metalfx','MetalFX']]))   # iPhone and iPad: MetalFX by default (2026-11-15 round)

    def test_mac_keeps_the_games_own(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']),patch.dict('os.environ',{'SETTINGS_PLATFORM':'mac'}):
            (Path(tmp)/'main.fixups.tsv').write_text('')
            up=[s for s in settings.build('040074A01BF12000',tmp,'unused')['settings'] if s['env']=='DM_UPSCALER']
            self.assertEqual(up[0]['default'],'game')

class LowPowerSetting(unittest.TestCase):
    def test_off_by_default_automatic_at_30_on_ios_where_the_host_paces_the_game(self):   # hle_nvn.c thermal_capped: Low Power Mode holds 30 fps only when the player turns this on
        with tempfile.TemporaryDirectory() as tmp,patch.object(settings.nacp,'languages',return_value=['en-US']):
            (Path(tmp)/'main.fixups.tsv').write_text('')
            for gid,platform,shown in [('0100DCA0064A6000','ios',True),('0100F2C0115B6000','ios',True),('04007EF01F8AE000','ios',True),   # Luigi's Mansion 3 (engine limiter), Tears of the Kingdom (frame step), Fortune's Weave (target it steps by)
                                       ('0100DCA0064A6000','mac',False),('01005CA01580E000','ios',False)]:   # the Mac reports no Low Power Mode; Persona 5 Royal's own present interval is not the host's pace
                with patch.dict(settings.os.environ,{'SETTINGS_PLATFORM':platform}):
                    lp=[s for s in settings.build(gid,tmp,'unused')['settings'] if s['env']=='DM_LOW_POWER_CAP']
                self.assertEqual(bool(lp),shown,(gid,platform))
                if lp:
                    r=lp[0]
                    self.assertEqual((r['kind'],r['section'],r['label'],r['default'],r['on'],r['off']),('toggle','Game','Low Power Mode at 30 fps','0','1','0'))
                    self.assertEqual(r['note'],'When iOS Low Power Mode is on, the game runs at 30 fps to save battery.')
                    self.assertNotIn('preset',r)   # no preset value: at 30 fps (the Battery preset) the row is greyed and shown on, automatic
                    self.assertIn('DM_FPS_TARGET=30',str(r.get('inactive')))

if __name__=='__main__':unittest.main()
