"""The launcher's settings (dm/games/settings.tsv through dm/games/settings.py): rows by graphics API and profile, single-screen sections, toggle values and the strict format;
the meta column's optional fields, and the written list against docs/launcher.schema.json, the contract front ends read."""
import importlib.util
import json
import os
import re
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('launcher_settings', ROOT / 'dm/games/settings.py')
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

BOTW, WONDER, DQ11S = '01007EF00011E000', '010015100B514000', '01006C300E9F0000'
PERFORMANCE_NVN = ['DM_PRESENT_SNAP', 'DM_PSO_PREBUILD', 'DM_NVN_ENC_THREAD', 'DM_FPS_HOLD', 'DM_METAL_HUD']
FRAME_STEP = ('FPS_STATE_OFF',)   # main's rewriter table of a build with a frame step state page (patch_nso.py): Hold frames when late reads it


def build(gid, api, platform=None, fixups=(), mods=()):
    """The settings rows, by variable, of the game's list; fixups are the keys of main's rewriter table (main.fixups.tsv), mods the switchable mods' roles (mods.tsv)"""
    env = {'GFXAPI': api, **({'SETTINGS_PLATFORM': platform} if platform else {})}
    with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, env):
        if not platform: os.environ.pop('SETTINGS_PLATFORM', None)
        if fixups: (Path(tmp) / 'main.fixups.tsv').write_text(''.join(f'# {k}\t1\n' for k in fixups))
        if mods: (Path(tmp) / 'mods.tsv').write_text('# header\n' + ''.join(f'{r}\tsome mod\t3\n' for r in mods))
        return {s['env']: s for s in settings.build(gid, tmp, Path(tmp) / 'control.nacp')['settings']}


def build_table(text, gid=BOTW, fixups=()):   # a list from a settings table of the test's own, for the format's checks
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'settings.tsv').write_text('# header\n' + text, encoding='utf-8')
        if fixups: (Path(tmp) / 'main.fixups.tsv').write_text(''.join(f'# {k}\t1\n' for k in fixups))
        with patch.object(settings, 'HERE', Path(tmp)), patch.object(settings.nacp, 'languages', return_value=['en-US']):
            return {s['env']: s for s in settings.build(gid, tmp, Path(tmp) / 'control.nacp')['settings']}


def row(var, kind='toggle', values='-', default='0', meta='', shown='always'):
    return '\t'.join((var, kind, values, default, shown, 'Game', var, '', meta)) + '\n'


def rows_with_languages(listed):   # the settings rows, by variable, of a game whose control data lists these languages
    with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=listed), patch.dict(os.environ, {'GFXAPI': 'nvn', 'DM_LANG': 'en-US'}):
        return {s['env']: s for s in settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')['settings']}


class LauncherSettingsTests(unittest.TestCase):
    def test_game_language_row_offers_the_games_own_or_every_language_when_unknown(self):
        self.assertNotIn('DM_LANG', rows_with_languages(['ja']))   # one language: nothing to pick
        s = rows_with_languages(['en-US', 'ja'])['DM_LANG']
        self.assertEqual((s['options'], s['note']), ([['en-US', 'American English'], ['ja', 'Japanese']], ''))
        s = rows_with_languages([])['DM_LANG']   # no control data: a dump, a NUP without a NACP
        self.assertEqual(s['options'], [list(l) for l in settings.nacp.LANGUAGES])
        self.assertEqual((s['default'], s['note']), ('en-US', settings.UNKNOWN_LANGUAGES))

    def test_upscaling_is_opt_in_for_every_graphics_api(self):
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000')]:
            with self.subTest(api=api):
                s = build(gid, api)['DM_PRESENT_UPSCALE']
                self.assertEqual((s['kind'], s['section'], s['default']), ('choice', 'Game', 'off'))
                self.assertEqual(s['options'], [['off', 'Standard'], ['metalfx', 'MetalFX']])

    def test_sharpening_for_every_graphics_api_and_platform_with_the_profile_default(self):   # a Game row the in-game menu also offers (front_ios.m dm_setting_live)
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000')]:
            for platform in ('ios', 'mac'):
                with self.subTest(api=api, platform=platform):
                    s = build(gid, api, platform)['DM_PRESENT_SHARPEN']
                    self.assertEqual((s['kind'], s['section'], s['default'], s['label']), ('choice', 'Game', '0', 'Sharpening'))   # no profile sets present_sharpen yet: Off
                    self.assertEqual(s['options'], [['0', 'Off'], ['1', 'Low'], ['2', 'Medium'], ['3', 'High']])
                    self.assertIn('MetalFX', s['note'])
        rows = list(build(BOTW, 'nvn'))
        self.assertEqual(rows.index('DM_PRESENT_SHARPEN'), rows.index('DM_PRESENT_UPSCALE') + 1)   # beside Upscaling
        real = settings.game.header_one   # a profile's present_sharpen is the row's default
        with patch.object(settings.game, 'header_one', lambda g: real(g).replace('#define DM_GAME_PRESENT_SHARPEN 0', '#define DM_GAME_PRESENT_SHARPEN 2')):
            self.assertEqual(build(BOTW, 'nvn')['DM_PRESENT_SHARPEN']['default'], '2')

    def test_anti_aliasing_for_every_graphics_api_and_platform_with_the_profile_default(self):   # a Game row the in-game menu also offers (front_ios.m dm_setting_live)
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000')]:
            for platform in ('ios', 'mac'):
                with self.subTest(api=api, platform=platform):
                    s = build(gid, api, platform)['DM_POST_AA']
                    self.assertEqual((s['kind'], s['section'], s['default'], s['label']), ('choice', 'Game', 'off', 'Anti-aliasing'))   # no profile sets post_aa: Off
                    self.assertEqual(s['options'], [['off', 'Off'], ['edge', 'Edge smoothing'], ['edge-sharp', 'Edge smoothing (sharp)']])
                    self.assertIn('HUD', s['note'])
        rows = list(build(BOTW, 'nvn'))
        self.assertEqual(rows.index('DM_POST_AA'), rows.index('DM_PRESENT_SHARPEN') + 1)   # beside Upscaling and Sharpening
        real = settings.game.header_one   # a profile's post_aa is the row's default
        with patch.object(settings.game, 'header_one', lambda g: real(g).replace('#define DM_GAME_POST_AA "off"', '#define DM_GAME_POST_AA "edge"')):
            self.assertEqual(build(BOTW, 'nvn')['DM_POST_AA']['default'], 'edge')

    def test_frame_buffering_by_graphics_api(self):
        for api, gid in [('nvn', BOTW), ('vulkan', '0100535012974000'), ('gl', '010014E00DB56000'), ('', BOTW)]:
            with self.subTest(api=api):
                rows = build(gid, api)
                self.assertEqual('DM_PRESENT_SNAP' in rows, api == 'nvn')
                if api == 'nvn':
                    s = rows['DM_PRESENT_SNAP']
                    self.assertEqual((s['kind'], s['section'], s['default']), ('toggle', 'Performance', '1'))   # Breath of the Wild's profile: present_snap on
                    self.assertIn('latency', s['note'])

    def test_sections_keep_the_profile_defaults(self):
        botw, wonder = build(BOTW, 'nvn', fixups=FRAME_STEP), build(WONDER, 'nvn')
        self.assertEqual([e for e, s in botw.items() if s['section'] == 'Performance'], PERFORMANCE_NVN)
        self.assertNotIn('DM_PSO_MTL4', botw)   # retired: every pipeline is built through MTL4Compiler, nothing to choose
        self.assertNotIn('needs', botw['DM_PSO_PREBUILD'])   # the prebuild is always there to turn off
        self.assertEqual(wonder['DM_PRESENT_SNAP']['default'], '0')
        self.assertEqual((botw['DM_PSO_PREBUILD']['default'], botw['DM_NVN_ENC_THREAD']['default'], botw['DM_METAL_HUD']['default']), ('1', '1', '0'))   # the host's iOS defaults
        self.assertEqual(list(dict.fromkeys(s['section'] for s in botw.values())), ['Game', 'Controls', 'Performance'])
        self.assertNotIn('DM_FPS_HOLD', wonder)   # no frame step, as the Frame rate row
        self.assertIn('first start', botw['DM_PSO_PREBUILD']['note'])   # it runs once in the prepare step, before the first frame

    def test_hold_frames_takes_on_and_off(self):   # the host reads DM_FPS_HOLD as on / off (hle_nvn.c), not 1 / 0
        s = build(BOTW, 'nvn', fixups=FRAME_STEP)['DM_FPS_HOLD']
        self.assertEqual((s['on'], s['off'], s['default']), ('on', 'off', 'on'))
        s = build(BOTW, 'nvn')['DM_SHOW_FPS']
        self.assertEqual((s['on'], s['off']), ('1', '0'))

    def test_iphone_switches_only_on_the_iphone(self):   # the frame-rate counter and touch feedback are the iOS front end's (front_ios.m, DmGamepad.m)
        ios, mac = build(BOTW, 'nvn'), build(BOTW, 'nvn', 'mac')
        self.assertEqual(build(BOTW, 'nvn', 'ios').keys(), ios.keys())   # ios when unset
        self.assertEqual(set(ios) - set(mac), {'DM_SHOW_FPS', 'DM_TOUCH_HAPTICS', 'DM_TOUCH_SIZE', 'DM_TOUCH_OPACITY', 'DM_PICTURE_FIT'})
        self.assertIn('DM_RUMBLE', mac); self.assertIn('DM_METAL_HUD', mac)
        self.assertEqual(set(mac) - set(ios), {'DM_FULLSCREEN', 'DM_SW2'})   # the Mac window's Display mode (front_mac.m reads 1 or 0); Switch 2 controllers (pad_switch2_apple.m, wired on the Mac only)
        s = mac['DM_FULLSCREEN']
        self.assertEqual((s['kind'], s['default'], s['options'], s['level']), ('choice', '0', [['0', 'Window'], ['1', 'Fullscreen']], 'basic'))

    def test_touch_control_size_and_opacity_default_to_the_look_they_always_had(self):   # DmGamepad.m: 1 and 1 are the controls' size and colours before the rows existed
        rows = build(BOTW, 'nvn')
        size, opacity = rows['DM_TOUCH_SIZE'], rows['DM_TOUCH_OPACITY']
        self.assertEqual((size['kind'], size['section'], size['default'], size['options']), ('choice', 'Controls', '1', [['0.7', 'Small'], ['0.85', 'Medium'], ['1', 'Large']]))
        self.assertEqual((opacity['kind'], opacity['section'], opacity['default']), ('choice', 'Controls', '1'))
        self.assertEqual([o[1] for o in opacity['options']], ['Faint', 'Light', 'Normal', 'Strong'])
        self.assertTrue(all(0.5 <= float(o[0]) <= 1 for o in size['options']) and all(0.1 <= float(o[0]) <= 2 for o in opacity['options']), 'within the ranges DmGamepad.m takes')
        envs = list(rows)
        self.assertEqual(envs[envs.index('DM_TOUCH_SIZE'):envs.index('DM_TOUCH_SIZE') + 3], ['DM_TOUCH_SIZE', 'DM_TOUCH_OPACITY', 'DM_TOUCH_HAPTICS'])

    def test_hold_frames_only_where_the_frame_step_state_page_is(self):
        """hle_nvn.c fstep_hold is its only reader, and only a build with the frame step's state page (patch_nso.py FPS_STATE_OFF) has the step: Dragon Quest XI S
        has a frame rate cap (fps_target 60) but no frame step, so the row would do nothing there"""
        dq = build(DQ11S, 'nvn')
        self.assertIn('DM_FPS_TARGET', dq); self.assertNotIn('DM_FPS_HOLD', dq)
        s = build(BOTW, 'nvn', fixups=FRAME_STEP)['DM_FPS_HOLD']
        self.assertEqual(s['inactive'], [{'when': ['DM_FPS_TARGET=30/120'], 'why': 'Only matters at 60 fps'}])   # at 30 and 120 fps the hold is fixed (hle_nvn.c fstep_tick kmax)
        self.assertNotIn('DM_FPS_HOLD', build(BOTW, 'nvn'))

    def test_rumble_sub_rows_need_rumble_and_cutoff_greys_at_no_strength(self):
        rows = build(BOTW, 'nvn')
        self.assertEqual((rows['DM_RUMBLE_GAIN']['needs'], rows['DM_RUMBLE_MIN']['needs']), ('DM_RUMBLE=1', 'DM_RUMBLE=1'))
        self.assertEqual(rows['DM_RUMBLE_MIN']['inactive'], [{'when': ['DM_RUMBLE_GAIN=0'], 'why': 'Rumble strength is 0 %'}])   # the strength multiplies every output (haptics_apple.m)
        for env in ('DM_RUMBLE', 'DM_RUMBLE_GAIN'):
            self.assertEqual(rows[env]['hint'], [{'when': ['haptics:none', 'controller:none'], 'why': 'Rumble needs a controller on this device'}])

    def test_metalfx_with_stretch_is_a_hint_where_stretch_changes_the_shape(self):
        """Stretch (and Ultrawide, which stretches) keeps MetalFX out (nvn_mtl.m fx_why) unless the game presents a crop smaller than its window texture, which no profile key
        tells apart (Breath of the Wild's handheld picture, Super Mario Odyssey's dynamic resolution; not the render scale, which shrinks only the 3D views inside a full crop):
        so MetalFX stays selectable everywhere with a hint, and the in-game menu says what the present did. The Stretch hint holds only where Stretch changes the picture's
        shape: a game with Picture shape on Match screen renders the window's own shape where the window is taller than 16:9 (an iPad, front_ios.m startGame)"""
        stretch = ['DM_PICTURE_FIT=stretch', 'tv:none']   # with a TV connected the picture is shown there whole, and MetalFX runs (front_ios.m)
        ultrawide = {'option': 'metalfx', 'when': ['DM_MOD_ULTRAWIDE=1', 'screen>=1.85', 'tv:none'], 'why': 'With Ultrawide, only when the game draws a smaller picture'}
        why = 'With Stretch, only when the game draws a smaller picture'
        nofx = {'option': 'metalfx', 'when': ['mfx:none'], 'why': 'This device has no MetalFX scaler'}
        for gid, fixups in ((WONDER, ()), (WONDER, ('DYNAMIC_RESOLUTION',)), ('0100F2C0115B6000', ('RENDER_SCALE',))):   # no Picture shape row: the 16:9 picture
            with self.subTest(gid=gid, fixups=fixups):
                s = build(gid, 'nvn', fixups=fixups, mods=['ultrawide'])['DM_PRESENT_UPSCALE']
                self.assertEqual(s['inactive'], [nofx], 'nothing greys MetalFX but a device without the scaler')
                self.assertEqual(s['hint'], [ultrawide, {'option': 'metalfx', 'when': stretch, 'why': why}])
        s = build(BOTW, 'nvn', fixups=('RENDER_SCALE',), mods=['ultrawide'])['DM_PRESENT_UPSCALE']   # Picture shape: Stretch stretches a shape other than the window's
        self.assertEqual(s['hint'], [ultrawide, {'option': 'metalfx', 'when': stretch + ['DM_SCREEN_ASPECT!=auto'], 'why': why},
                                     {'option': 'metalfx', 'when': stretch + ['DM_SCREEN_ASPECT=auto', 'window>=1.77'], 'why': why}])
        self.assertEqual(build(WONDER, 'nvn')['DM_PRESENT_UPSCALE']['hint'], [{'option': 'metalfx', 'when': stretch, 'why': why}], 'no Ultrawide row without the mod: no rule on it')
        mac = build(WONDER, 'nvn', 'mac')['DM_PRESENT_UPSCALE']   # no Picture row on the Mac: nothing stretches there
        self.assertEqual((mac['inactive'], mac.get('hint')), ([nofx], None))

    def test_ultrawide_greys_picture_and_picture_shape(self):   # front_ios.m: on a screen of 1.85:1 or more, Ultrawide stretches the picture and keeps it 16:9
        rows = build(BOTW, 'nvn', mods=['ultrawide'])
        self.assertEqual(rows['DM_PICTURE_FIT']['inactive'], [{'when': ['DM_MOD_ULTRAWIDE=1', 'screen>=1.85'], 'why': 'Ultrawide always stretches the picture'}])
        self.assertEqual(rows['DM_SCREEN_ASPECT']['inactive'], [{'when': ['DM_MOD_ULTRAWIDE=1', 'screen>=1.85'], 'why': 'Ultrawide keeps the 16:9 picture'}])
        self.assertEqual(rows['DM_SCREEN_ASPECT']['hint'], [{'option': 'auto', 'when': ['window>=1.77'], 'why': '16:9 on this screen'}])
        self.assertNotIn('inactive', build(BOTW, 'nvn')['DM_PICTURE_FIT'], 'without the mod nothing greys Picture')
        mac = build(BOTW, 'nvn', 'mac', mods=['ultrawide'])['DM_SCREEN_ASPECT']
        self.assertFalse({'inactive', 'hint'} & set(mac), 'the Mac has neither Ultrawide nor Match screen')

    def test_rows_that_never_work_on_a_device_are_hidden_there(self):
        rows = build(BOTW, 'nvn', mods=['ultrawide'])
        self.assertEqual(rows['DM_MOD_ULTRAWIDE']['hide'], [{'when': ['device:ipad']}])   # front_ios.m leaves the mod off below 1.85:1, every iPad
        self.assertEqual(rows['DM_MOD_ULTRAWIDE']['inactive'], [{'when': ['screen<1.85'], 'why': "This screen isn't wider than 16:9"}])
        self.assertEqual(rows['DM_TOUCH_HAPTICS']['hide'], [{'when': ['haptics:none']}])   # DmGamepad.m plays touch feedback on the device's haptic engine only

    def test_device_and_environment_rules(self):
        rows, mac = build(BOTW, 'nvn'), build('0100F2C0115B6000', 'nvn', 'mac')
        self.assertEqual(rows['DM_PAD_PRESS_TO_JOIN']['inactive'], [{'when': ['DM_PAD_MERGE=1'], 'why': 'All controllers are player 1 (env.txt)'}])
        capture = [{'when': ['DM_GPU_CAPTURE=*'], 'why': 'Off while GPU capture is on'}, {'when': ['capture:on'], 'why': 'Off while GPU capture is on'}]
        self.assertEqual(rows['DM_PSO_PREBUILD']['inactive'], capture)   # the capture profile opens no archive: the prebuild has none to build into
        self.assertNotIn('inactive', mac['DM_SW2'], 'the packer writes the Bluetooth key with every list (pack_app.py info_plist): nothing to grey')
        self.assertEqual(rows['DM_SHOW_FPS']['hint'], [{'when': ['DM_METAL_HUD=1'], 'why': 'The Performance HUD shows the frame rate too'}])
        self.assertNotIn('inactive', rows['DM_FPS_TARGET'], 'the 120 fps rule goes only where the option is offered')
        with patch.object(settings.game, 'header_one', lambda g, real=settings.game.header_one: real(g).replace('#define DM_GAME_FPS_MAX 60', '#define DM_GAME_FPS_MAX 120')):
            s = build(BOTW, 'nvn', 'mac')['DM_FPS_TARGET']
        self.assertEqual(s['inactive'], [{'option': '120', 'when': ['hz<120'], 'why': "This display can't show 120 Hz"}])

    def test_rules_resolve_pack_terms_and_write_aliases(self):
        text = (row('DM_PRESENT_UPSCALE', 'choice', 'off=Standard,metalfx=MetalFX', 'off') + row('DM_X', meta='hint=DM_PRESENT_UPSCALE=metalfx~a|DM_PRESENT_UPSCALE!=off~b')
                + row('DM_Y', meta='inactive=DM_X=1&fixups:K/L~c|DM_X=1&!fixups:K~d|DM_X=1&gfxapi:nvn~e|DM_X=1&DM_GAME_FPS_TARGET==60~f') + row('DM_Z', meta='hint=DM_NOT_HERE=1~g', shown='always')
                + row('DM_NOT_HERE', shown='fixups:NEVER'))
        with patch.dict(os.environ, {'GFXAPI': 'gl'}):
            rows = build_table(text, fixups=('L',))
        self.assertEqual(rows['DM_X']['hint'], [{'when': ['DM_PRESENT_UPSCALE=metalfx/1'], 'why': 'a'}, {'when': ['DM_PRESENT_UPSCALE!=off/0'], 'why': 'b'}])   # nvn_upscale_pick.h up_parse's spellings
        self.assertEqual(rows['DM_Y']['inactive'], [{'when': ['DM_X=1'], 'why': 'c'}, {'when': ['DM_X=1'], 'why': 'd'}, {'when': ['DM_X=1'], 'why': 'f'}])   # e: not packed for NVN
        self.assertNotIn('hint', rows['DM_Z'], 'a rule on a setting this game does not list can never hold')

    def test_rules_are_strict(self):
        base = row('DM_A', 'choice', 'a=A,b=B', 'a') + row('DM_R', 'range', '0:1:0.1', '0')
        for meta, why in [('inactive=DM_NOPE=1~x', 'no row sets'), ('inactive=DM_A=c~x', 'never takes'), ('inactive=DM_R=2~x', 'never takes'), ('inactive=DM_R=lots~x', 'not a number'),
                          ('inactive=c:DM_A=a~x', 'option'), ('inactive=DM_A=a', 'does not match'), ('inactive=DM_A=a~', 'does not match'), ('inactive=DM_A=a~' + 'x' * 61, 'longer than'),
                          ('inactive=DM_A=a;inactive=DM_A=b~x', 'does not match'), ('hint=size>3~x', 'unknown hint term'), ('hide=DM_A=a', 'device terms'), ('hide=fixups:K', 'device term'),
                          ('inactive=fixups:K~x', 'only pack-time'), ('inactive=DM_GAME_FPS_TARGET=60~x', 'with =='), ('inactive=DM_A=*~x', 'never takes'),
                          ('inactive=DM_GPU_CAPTURE=1~x', 'only as set'), ('inactive=DM_PAD_MERGE=2~x', 'never takes'), ('hide=a:device:ipad', 'whole row')]:
            with self.subTest(meta=meta), self.assertRaises(SystemExit) as e:
                build_table(base + row('DM_X', 'choice', 'a=A,b=B', 'a', meta=meta))
            self.assertIn(why, str(e.exception))
        with self.assertRaises(SystemExit) as e:   # a range has no options to grey
            build_table(base + row('DM_X', 'range', '0:1:0.1', '0', meta='inactive=0:DM_A=a~x'))
        self.assertIn('option', str(e.exception))
        ok = build_table(base + row('DM_X', 'choice', 'a=A,b=B', 'a', meta='inactive=b:DM_A=b&device:iphone/ipad~x|DM_R=0.5~y;hint=DM_PAD_MERGE=1~z;hide=device:mac&hz>=120'))['DM_X']
        self.assertEqual((ok['inactive'], ok['hint'], ok['hide']), ([{'option': 'b', 'when': ['DM_A=b', 'device:iphone/ipad'], 'why': 'x'}, {'when': ['DM_R=0.5'], 'why': 'y'}],
                                                                   [{'when': ['DM_PAD_MERGE=1'], 'why': 'z'}], [{'when': ['device:mac', 'hz>=120']}]))

    def test_greying_cycles_are_refused(self):   # two rows that grey each other could both stay greyed with no way out for the player
        for text in (row('DM_A', meta='inactive=DM_B=1~x') + row('DM_B', meta='inactive=DM_A=0~y'),
                     row('DM_A', meta='inactive=DM_B=1~x') + row('DM_B', meta='inactive=DM_C=1~y') + row('DM_C', meta='inactive=DM_A=1~z', shown='fixups:NEVER'),
                     row('DM_A', 'choice', 'a=A,b=B', 'a', meta='inactive=b:DM_A=a~x')):
            with self.subTest(text=text), self.assertRaisesRegex(SystemExit, 'cycle'):
                build_table(text)
        build_table(row('DM_A', meta='inactive=DM_B=1~x') + row('DM_B', meta='hint=DM_A=0~y'))   # a hint greys nothing
        self.assertIsNone(settings.greying_cycle({v: settings.rules('inactive', m, n, v, table) for n, (v, m, table) in enumerate(real_inactive(), 1)}), 'the real table')

    def test_dynamic_resolution_and_render_scale_together_need_a_rule(self):   # loader.c dm_fps_state_apply: below 100 % the render scale fixes the size
        with self.assertRaisesRegex(SystemExit, 'both Dynamic resolution and Render scale'):
            build(BOTW, 'nvn', fixups=('DYNAMIC_RESOLUTION', 'RENDER_SCALE'))
        text = row('DM_DYNAMIC_RESOLUTION', shown='fixups:DYNAMIC_RESOLUTION') + row('DM_RENDER_SCALE', 'range', '0.5:1.0:0.05', '1.0', shown='fixups:RENDER_SCALE')
        with self.assertRaisesRegex(SystemExit, 'both Dynamic resolution and Render scale'):
            build_table(text, fixups=('DYNAMIC_RESOLUTION', 'RENDER_SCALE'))
        ruled = row('DM_DYNAMIC_RESOLUTION', meta='inactive=DM_RENDER_SCALE!=1~Off below 100 % render scale', shown='fixups:DYNAMIC_RESOLUTION') + text.split('\n', 1)[1]
        self.assertIn('inactive', build_table(ruled, fixups=('DYNAMIC_RESOLUTION', 'RENDER_SCALE'))['DM_DYNAMIC_RESOLUTION'])

    def test_switchable_mods_only_with_the_mods_packed(self):   # mods.tsv beside the rewritten modules (build_ipa_from_nsp.py build_variants)
        def rows(roles, platform):
            with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': 'nvn', 'SETTINGS_PLATFORM': platform}):
                if roles: (Path(tmp) / 'mods.tsv').write_text('# header\n' + ''.join(f'{r}\tsome mod\t3\n' for r in roles))
                return {s['env'] for s in settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')['settings']}
        self.assertFalse({'DM_MOD_FPS', 'DM_MOD_ULTRAWIDE'} & rows([], 'ios'))
        self.assertTrue({'DM_MOD_FPS', 'DM_MOD_ULTRAWIDE'} <= rows(['fps', 'ultrawide'], 'ios'))
        mac = rows(['fps', 'ultrawide'], 'mac')
        self.assertIn('DM_MOD_FPS', mac); self.assertNotIn('DM_MOD_ULTRAWIDE', mac, 'Ultrawide stretches the picture, which only the iPhone and iPad front end does')

    def test_frame_rate_as_the_present_interval(self):   # present_interval_choice: Persona 5 Royal's 30 / 60 (DM_PRESENT_INTERVAL game / display)
        p5r = build('01005CA01580E000', 'nvn')['DM_PRESENT_INTERVAL']
        self.assertEqual((p5r['label'], p5r['default'], p5r['options']), ('Frame rate', 'game', [['game', '30 fps'], ['display', '60 fps']]))
        self.assertNotIn('DM_PRESENT_INTERVAL', build(BOTW, 'nvn'), 'a game without the profile key keeps its own interval')
        # The row starts at 30 fps (game): a profile that also sets present_interval display would have the launcher's default override its tested 60, so it is refused
        with tempfile.TemporaryDirectory() as tmp:
            src = ROOT / 'dm/games/01005CA01580E000'; d = Path(tmp) / src.name; d.mkdir()
            (d / 'game.tsv').write_text((src / 'game.tsv').read_text(encoding='utf-8') + 'present_interval\tdisplay\n', encoding='utf-8')
            with self.assertRaisesRegex(SystemExit, 'leave present_interval at game'): settings.game.header_one(settings.game.Game(d))

    def test_defaults_follow_each_platform_host(self):
        # The <ios>|<mac> default form: nvn_rec.h rec_on is on on iOS and follows the profile on the Mac (DM_NVN_ENC_THREAD 1|DM_GAME_ENC_THREAD). A retired pso_mtl4 off in the
        # profile changes nothing: no row reads it
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / WONDER; d.mkdir()   # Wonder's profile with pso_mtl4 off
            (d / 'game.tsv').write_text((ROOT / 'dm/games' / WONDER / 'game.tsv').read_text(encoding='utf-8') + 'pso_mtl4\toff\n', encoding='utf-8')
            off = settings.game.Game(d)
            for gid, prof in ((BOTW, None), (WONDER, None), (WONDER, off)):
                with self.subTest(game=gid, pso_mtl4='off' if prof else 'default'), patch.object(settings.game, 'load', side_effect=lambda i, prof=prof, real=settings.game.load: prof or real(i)):
                    ios, mac = build(gid, 'nvn', 'ios'), build(gid, 'nvn', 'mac')
                    self.assertEqual((ios['DM_NVN_ENC_THREAD']['default'], mac['DM_NVN_ENC_THREAD']['default']), ('1', '0'))
                    self.assertNotIn('DM_PSO_MTL4', ios); self.assertNotIn('DM_PSO_MTL4', mac)
                    self.assertEqual((ios['DM_PSO_PREBUILD']['default'], mac['DM_PSO_PREBUILD']['default']), ('1', '1'))

    def test_unknown_platform_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, 'SETTINGS_PLATFORM must be ios or mac'):
            build(WONDER, 'nvn', 'mca')

    def test_malformed_platform_defaults_are_rejected(self):
        for default in ('1|', '|0', '1|0|1'):
            with self.subTest(default=default), tempfile.TemporaryDirectory() as tmp:
                row = '\t'.join(('DM_X', 'toggle', '-', default, 'always', 'Game', 'X')) + '\n'
                (Path(tmp) / 'settings.tsv').write_text(row, encoding='utf-8')
                with patch.object(settings, 'HERE', Path(tmp)), patch.object(settings.nacp, 'languages', return_value=['en-US']), \
                        self.assertRaisesRegex(SystemExit, 'platform default'):
                    settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')

    def test_meta_fields_and_the_schema_version(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(settings.nacp, 'languages', return_value=['en-US', 'ja']), patch.dict(os.environ, {'GFXAPI': 'nvn'}):
            (Path(tmp) / 'main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render scale row's condition
            listed = settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')
        rows = {s['env']: s for s in listed['settings']}
        self.assertEqual(listed['schema'], 1)
        self.assertEqual([e for e, s in rows.items() if s.get('level') == 'basic'], ['DM_FPS_TARGET', 'DM_RENDER_SCALE', 'DM_OPMODE', 'DM_LANG', 'DM_RUMBLE'])
        self.assertEqual(rows['DM_RUMBLE_GAIN']['needs'], 'DM_RUMBLE=1')
        self.assertFalse({'level', 'needs'} & set(rows['DM_METAL_HUD']), 'a row without meta has no optional fields')

    def test_meta_is_strict(self):
        self.assertEqual(settings.meta('level=basic; needs=DM_RUMBLE=1', 1), {'level': 'basic', 'needs': 'DM_RUMBLE=1'})
        self.assertEqual(settings.meta('', 1), {})
        for bad, why in [('colour=red', 'unknown meta key'), ('level', 'unknown meta key'), ('level=basic;level=basic', 'twice'),
                         ('level=advanced', 'does not match'), ('needs=DM_RUMBLE', 'does not match'), ('needs=rumble=1', 'does not match')]:
            with self.subTest(bad=bad), self.assertRaises(SystemExit) as e:
                settings.meta(bad, 1)
            self.assertIn(why, str(e.exception))

    def test_meta_keys_agree_with_the_docs_and_the_schema(self):
        """A key is added in settings.py's META, docs/frontends.md and docs/launcher.schema.json together"""
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        fields = schema['$defs']['setting']['properties']
        docs = (ROOT / 'docs/frontends.md').read_text(encoding='utf-8')
        for key in settings.META:
            with self.subTest(key=key):
                self.assertIn(key, fields)
                self.assertNotIn(key, schema['$defs']['setting']['required'], 'a meta field is optional')
                self.assertRegex(docs, rf'- `{key}` \(optional\)')
        self.assertEqual(schema['properties']['schema']['const'], settings.SCHEMA)

    def test_written_lists_follow_the_schema(self):
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        for gid, api, platform in [(BOTW, 'nvn', None), (BOTW, 'nvn', 'mac'), (WONDER, 'nvn', None), ('0100535012974000', 'vulkan', 'mac')]:
            for fixups, mods in (((), ()), (('FPS_STATE_OFF', 'RENDER_SCALE'), ('fps', 'ultrawide'))):   # with the rows the rewriter table and the mods bring, and their rules
                with self.subTest(gid=gid, platform=platform, fixups=fixups), tempfile.TemporaryDirectory() as tmp, \
                        patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': api, **({'SETTINGS_PLATFORM': platform} if platform else {})}):
                    (Path(tmp) / 'main.fixups.tsv').write_text(''.join(f'# {k}\t1\n' for k in fixups))
                    (Path(tmp) / 'mods.tsv').write_text('# header\n' + ''.join(f'{r}\tsome mod\t3\n' for r in mods))
                    self.assertEqual(conforms(settings.build(gid, tmp, Path(tmp) / 'control.nacp'), schema, schema), [])
        rule = {'option': 'metalfx', 'when': ['DM_PICTURE_FIT=stretch'], 'why': 'x'}
        row = {'env': 'DM_X', 'kind': 'toggle', 'section': 'Game', 'label': 'X', 'note': '', 'default': '1', 'on': '1', 'off': '0'}
        self.assertEqual(conforms({'game': BOTW, 'settings': [{**row, 'inactive': [rule], 'hint': [rule], 'hide': [{'when': ['device:ipad']}]}]}, schema, schema), [])
        for bad in ({'inactive': [{'when': ['device:ipad']}]}, {'hint': [{'why': 'x'}]}, {'hide': [{}]}, {'inactive': rule}):
            with self.subTest(bad=bad):
                self.assertNotEqual(conforms({'game': BOTW, 'settings': [{**row, **bad}]}, schema, schema), [])

    def test_schema_1_takes_new_sections_but_not_new_kinds(self):
        """A section is a heading a reader draws by its name, so a new one stays schema 1; a new kind would not"""
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        row = {'env': 'DM_X', 'kind': 'toggle', 'section': 'Picture', 'label': 'X', 'note': '', 'default': '1', 'on': '1', 'off': '0'}
        self.assertEqual(conforms({'schema': 1, 'game': BOTW, 'settings': [row]}, schema, schema), [])
        self.assertNotEqual(conforms({'schema': 1, 'game': BOTW, 'settings': [{**row, 'kind': 'slider'}]}, schema, schema), [])

    def test_render_base_goes_into_the_render_scale_row(self):
        schema = json.loads((ROOT / 'docs/launcher.schema.json').read_text(encoding='utf-8'))
        for gid, base in [(BOTW, {'docked': [1600, 900], 'handheld': [1280, 720]}), (WONDER, None)]:   # Breath of the Wild's note; Wonder's profile has none
            with self.subTest(gid=gid), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': 'nvn'}):
                (Path(tmp) / 'main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render scale row's condition
                listed = settings.build(gid, tmp, Path(tmp) / 'control.nacp')
            self.assertEqual({s['env']: s for s in listed['settings']}['DM_RENDER_SCALE'].get('base'), base)
            self.assertEqual(conforms(listed, schema, schema), [])
        for bad in ('1600x900', '1600x900 1280', 'big small', '1600x900x3 1280x720', 'a1600x900 1280x720', '1600x900 1280x720 640x360'):
            with self.subTest(bad=bad):
                profile = type('Profile', (), {'id': BOTW, 'get': lambda self, key, default='', bad=bad: bad})()
                with self.assertRaises(SystemExit): settings.render_base(profile)

    def test_render_scale_reaches_the_stubs_largest_scale(self):
        """The rewriter writes a render-scale stub's largest scale as RENDER_SCALE: 1 keeps the table's range (a stub that only lowers the size), 3 raises its top (Hades II)"""
        for value, top in (('1', 1.0), ('3', 3.0)):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp, \
                    patch.object(settings.nacp, 'languages', return_value=['en-US']), patch.dict(os.environ, {'GFXAPI': 'nvn'}):
                (Path(tmp) / 'main.fixups.tsv').write_text(f'# RENDER_SCALE\t{value}\n')
                row = {s['env']: s for s in settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')['settings']}['DM_RENDER_SCALE']
            self.assertEqual((row['min'], row['max']), (0.5, top))

    def test_table_format_is_strict(self):
        good = 'DM_X\ttoggle\t-\t0\talways\tGame\tX\n'
        for bad, why in [('DM_X\ttoggle\t-\t0\talways\tGame\tX\t\tlevel=basic\textra\n', 'columns'),
                         ('DM_X\ttoggle\t-\t0\talways\tGame\tX\t\tneeds=DM_NOPE=1\n', 'no row sets'),
                         ('DM_Y\ttoggle\t-\t0\talways\tGame\tY\t\tneeds=DM_X=on\n', 'never takes'),
                         ('DM_X\ttoggle\t-\t0\talways\tX\n', 'columns'), ('DM_X\ttoggle\t-\t0\talways\tsecret\tX\n', 'section'),
                         ('DM_X\ttoggle\ton\t0\talways\tGame\tX\n', 'toggle values'), ('DM_X\ttoggle\t-\t2\talways\tGame\tX\n', 'defaults to 0 or 1')]:
            with self.subTest(why=why), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / 'settings.tsv').write_text('# header\n' + good + bad, encoding='utf-8')
                with patch.object(settings, 'HERE', Path(tmp)), \
                        patch.object(settings.nacp, 'languages', return_value=['en-US']), self.assertRaises(SystemExit) as e:
                    settings.build(BOTW, tmp, Path(tmp) / 'control.nacp')
                self.assertIn(why, str(e.exception))


def real_inactive():   # (variable, inactive value, table) for every row of the real settings.tsv with inactive rules
    table = {r[1][0]: (r[1][1], r[1][2]) for r in settings.rows()}
    for n, c in settings.rows():
        m = settings.meta(c[8], n)
        if 'inactive' in m: yield c[0], m['inactive'], table


def conforms(value, node, root, at='$'):
    """The JSON Schema keywords launcher.schema.json uses (type, required, properties, items, enum, const, pattern, $ref, allOf with
    if / then), as a list of problems: enough to hold the written lists to the contract without a jsonschema package"""
    if '$ref' in node: return conforms(value, root['$defs'][node['$ref'].rsplit('/', 1)[1]], root, at)
    problems = []
    kinds = {'object': dict, 'array': list, 'string': str, 'integer': int, 'number': (int, float)}
    if 'type' in node and not isinstance(value, kinds[node['type']]): return [f'{at}: not a {node["type"]}']
    if 'const' in node and value != node['const']: problems.append(f'{at}: not {node["const"]!r}')
    if 'enum' in node and value not in node['enum']: problems.append(f'{at}: not one of {node["enum"]}')
    if 'pattern' in node and not re.search(node['pattern'], value): problems.append(f'{at}: does not match {node["pattern"]}')
    if isinstance(value, dict):
        problems += [f'{at}: no {k}' for k in node.get('required', []) if k not in value]
        for k, v in value.items():
            if k in node.get('properties', {}): problems += conforms(v, node['properties'][k], root, f'{at}.{k}')
        for rule in node.get('allOf', []):
            if not conforms(value, rule['if'], root, at): problems += conforms(value, rule['then'], root, at)
    if isinstance(value, list) and 'items' in node:
        for i, v in enumerate(value): problems += conforms(v, node['items'], root, f'{at}[{i}]')
    return problems


if __name__ == '__main__':
    unittest.main()
