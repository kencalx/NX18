"""The touch controls drawn into the game's frame (dm/host/touch_draw.h; front_ios.m, DmGamepad.m, nvn_mtl.m, present.metal), checked in the sources off the device: what the unit
tests do not run together. dm/host/tests t_touch_draw (the sequence lock, the canvas, the atlas), dm/gfx/tests t_present_touch (the present's draw on the Metal 4 queue) and the
Duo harness's DuoTouchDrawTests (the layout, the frames and the look against the render server) each take one side; here: the switch and its row, that a player build keeps it,
that only the live present draws the controls, that the present and the gamepad name the same calls and the shader the same functions, and the paths that keep the layers."""
from pathlib import Path
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tests'))


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class TouchDraw(unittest.TestCase):
    def setUp(self):
        self.front = read('dm/ios/Sources/front_ios.m'); self.pad = read('dm/ios/Sources/DmGamepad.m'); self.nvn = read('dm/gfx/nvn/nvn_mtl.m')
        self.layout = body(self.front, '- (void)viewDidLayoutSubviews {\n    [super viewDidLayoutSubviews];\n    screen_cache')

    def test_switch_is_documented_and_kept_in_player_builds(self):
        row = next(l for l in read('docs/env_switches.tsv').splitlines() if l.startswith('DM_TOUCH_DRAW\t'))
        self.assertEqual(row.split('\t')[1], 'diagnostic')
        self.assertIn('`layer`', row)
        self.assertIn('getenv("DM_TOUCH_DRAW")', self.front)
        self.assertIn('!strcmp(td, "layer")', self.front)
        src = read('dm/ios/Sources/player_env.h')
        # dm_player_diagnostic_key's rule, read from the header: DM_TOUCH_DRAW is no DM_NVN_* or test switch and no name it lists, so a player build keeps it for the A/B
        self.assertNotIn('"DM_TOUCH_DRAW"', src)
        for p in ('DM_NVN_', 'DM_TEST_', 'MTL_DEBUG_', 'MTL_SHADER_VALIDATION'): self.assertFalse('DM_TOUCH_DRAW'.startswith(p))

    def test_present_drawable_game(self):
        """DM_PRESENT_DRAWABLE=game: the canvas at the picture's render size, the controls pictured at the same scale, standing down where MetalFX fills the screen"""
        row = next(l for l in read('docs/env_switches.tsv').splitlines() if l.startswith('DM_PRESENT_DRAWABLE\t'))
        self.assertEqual(row.split('\t')[1], 'switch')
        self.assertIn('getenv("DM_PRESENT_DRAWABLE")', self.front)
        self.assertIn('touch_drawable_game(pd, &bad)', self.front)
        self.assertNotIn('"DM_PRESENT_DRAWABLE"', read('dm/ios/Sources/player_env.h'))   # a player build keeps it for the A/B
        for p in ('DM_NVN_', 'DM_TEST_'): self.assertFalse('DM_PRESENT_DRAWABLE'.startswith(p))
        self.assertIn('CGFloat drawScale = pxScale;', self.layout, 'unset: the screen\'s pixels, as before')
        g = self.layout.split('if (g_drawable_game) {')[1].split('self.game.drawableScale')[0]
        for why in ('onTV', 'g_drawable_native', 'fxScreen', '!touchDraw'): self.assertIn(why, g, f'{why} stands the switch down')
        self.assertIn('touch_drawable_scale(layout.game.size.width, layout.game.size.height, g_picture_px.width, g_picture_px.height, pxScale)', g)
        self.assertIn('self.game.drawableScale = touchDraw && drawScale < pxScale ? drawScale : 0;', self.layout)
        lay = body(self.front, '- (void)layoutSubviews {\n    [super layoutSubviews];\n    CAMetalLayer')
        # the drawable rounds the canvas as the gamepad rounds its frame's (touchFrameHead), so the frame fits it (touch_frame_fits)
        self.assertIn('round(self.bounds.size.width * self.drawableScale), round(self.bounds.size.height * self.drawableScale)', lay)
        self.assertIn('lround(_canvas.size.width * _canvasScale)', self.pad)

    def test_layers_stay_where_the_picture_is_not_on_the_phone(self):
        for why in ('onTV', 'g_touch_failed', 'g_touch_layer', '!g_pictured', 'front_web_touch()'):
            self.assertIn(why, self.layout.split('BOOL touchDraw')[0], f'{why} keeps the layers')
        self.assertIn('BOOL touchDraw = shown && !layerWhy;', self.layout)
        self.assertIn('dm_gamepad_controls_shown(self.pad)', self.layout)
        self.assertIn('if (!onTV) self.game.frame = canvas;', self.layout)
        self.assertIn('touchDraw || g_drawable_native', self.layout, 'the drawable keeps the screen\'s pixels while the controls are in the frame')
        self.assertIn('dm_gamepad_touch_draw(self.pad, touchDraw, canvas, drawScale, dm_touch_picture(layout.game, canvas));', self.layout)
        self.assertIn('LOG("front end: touch controls %s"', self.layout, 'the path is logged at the start and at each change')
        self.assertIn('void front_web_shown(void) { [g_root.view setNeedsLayout]; }', self.front, 'a page shown or gone lays the view out again')
        web = read('dm/host/web_apple.m')
        self.assertIn('__attribute__((weak)) void front_web_shown(void) {}', web)
        self.assertNotIn('g_touch = 0;', web, 'every change of the page goes through web_shown')
        self.assertNotIn('g_touch = 1;', web)
        self.assertIn('static void web_shown(int on) { if (g_touch == on) return; g_touch = on; front_web_shown(); }', web)
        load = body(self.front, '- (void)viewDidLoad {\n    [super viewDidLoad];\n    self.view.backgroundColor = UIColor.blackColor;\n    __weak DmRootVC')
        self.assertIn('registerForTraitChanges:@[UITraitDisplayScale.class]', load, 'a display scale change lays the root out: the canvas follows the drawable')
        first = body(self.front, 'void front_picture_shape(int w, int h) {')
        self.assertIn('[g_root.view setNeedsLayout]; }', first, 'the first picture lays the view out again, into the frame')

    def test_gamepad_hides_its_layers_and_relayouts_the_root(self):
        draw = body(self.pad, '- (void)touchDraw:(BOOL)on canvas:(CGRect)canvas scale:(CGFloat)scale picture:(CGRect)pic {')
        on = draw[:draw.index('if (was)')]
        self.assertIn('_sprites = NO;', on, 'a new canvas: the pictures and their places are the old one\'s until the layout')
        self.assertIn('[self touchLayers:NULL];', on, 'the layers show until a present drew the controls for it')
        off = draw[draw.index('if (was)'):]
        self.assertIn('f.on = TOUCH_OFF; mtl_present_touch(&f);', off, 'the present is told when it must stop')
        self.assertIn('mtl_present_touch_release();', off, 'and lets the atlas go')
        self.assertIn('_atlasKey = nil;', off, 'made again when they come back')
        self.assertIn('touch_frame z = {0}; mtl_present_touch(&z);', off, 'then no frame at all')
        self.assertIn('dispatch_after(', off)
        pub = body(self.pad, '- (void)touchPublish {')
        self.assertIn('BOOL ready = _atlasOK && _sprites;', pub)
        self.assertIn('f.on = ready ? TOUCH_ON : TOUCH_PLACE;', pub)
        self.assertIn('mtl_present_touch_ack(_ackFrom);', pub)
        drawn = body(self.pad, '- (void)touchDrawn:(uint32_t)seq {')
        self.assertIn('touch_seq_since(seq, _ackFrom)', drawn, 'an answer to a frame from before the change does not hide the layers')
        self.assertIn('_controls.hidden = YES;', drawn)
        self.assertIn('[self touchLayers:"the drawable does not fit the frame"]', body(self.pad, '- (void)touchUnfit {'))
        self.assertIn('[self.superview setNeedsLayout];', body(self.pad, '- (void)touchUnfit {'))
        self.assertIn('void front_touch_drawn(uint32_t seq) { dispatch_async(dispatch_get_main_queue()', self.pad)
        self.assertIn('void front_touch_unfit(void) { dispatch_async(dispatch_get_main_queue()', self.pad)
        layout = body(self.pad, '- (void)layoutSubviews {')
        self.assertLess(layout.index('_sprites = YES;'), layout.index('[self refresh];'))
        changed = body(self.pad, '- (void)padsChanged:(NSNotification *)note {')
        self.assertIn('self->_controls.hidden = any || (self->_touchDraw && self->_inFrame);', changed)
        self.assertIn('[self.superview setNeedsLayout];', changed, 'a controller takes the game view back to the picture')
        self.assertIn('[self.superview setNeedsLayout];', body(self.pad, '- (void)setPadLayout:(int)l {'), 'Tap too')
        refresh = body(self.pad, '- (void)refresh {')
        self.assertIn('[self touchAtlas];', refresh)
        self.assertIn('mtl_present_touch_idle_ns() > TOUCH_STALL_NS', refresh, 'no present for a while: a press shows on the layers')
        self.assertLess(refresh.index('TOUCH_STALL_NS'), refresh.index('[self touchPublish];'), 'the frame published after it asks for the present\'s answer')
        self.assertIn('if (_inFrame) return;', refresh)
        self.assertIn('[self layerLook];', refresh)
        atlas = body(self.pad, '- (void)touchAtlas {')
        for call in ('renderInContext:g', 'touch_shadow(g, ls[i], sc, _spritePt[i]);', 'touch_grey(', 'mtl_present_touch_atlas(', 'front_touch_draw_failed();'):
            self.assertIn(call, atlas)
        self.assertIn('[CATransaction begin]', atlas, 'the looks rendered are set and put back in one transaction')

    def test_only_the_live_present_draws_them(self):
        enc = body(self.nvn, 'static int present_encode_m4(')
        self.assertIn('int touch = live && touch_frame_now(&tf, dw, dh);', enc)
        self.assertIn('if (touch) touch_draw(en, &tf, uvb, dst.pixelFormat, dw, dh);', enc)
        self.assertLess(enc.index('touch_draw(en'), enc.index('m4_end_present(en);'), 'inside the present pass')
        self.assertIn('#define PRESENT_UV_FLOATS (TOUCH_UV + TOUCH_QUADS * 8)', self.nvn, 'every present constants buffer holds the quads')
        now = self.nvn[self.nvn.index('static int present_now(const tex_t *t'):]
        self.assertIn('uint64_t touch_seq = g_touch_seq;', now)
        self.assertIn('atomic_store_explicit(&g_touch_done, touch_seq, memory_order_release);', now, 'a completed present lets the replaced atlases go')
        self.assertIn('uint32_t touch_drew = g_touch_drew;', now)
        self.assertIn('front_touch_drawn(touch_drew);', now, 'a completed present that drew the controls answers the front end, once per request')
        self.assertIn('atomic_compare_exchange_strong(&g_touch_ack, &want, 0)', now)
        self.assertIn('if (live) g_touch_drew = 0;', enc)
        fnow = body(self.nvn, 'static int touch_frame_now(touch_frame *f, double dw, double dh) {')
        self.assertIn('touch_unfit_step(&g_touch_unfit, f, fits)', fnow)
        self.assertIn('front_touch_unfit();', fnow)
        self.assertIn('return touch_frame_places(f, g_touch_last_seq, &g_touch_dead, fits);', fnow, 'an off frame places nothing after a drawable of another size')
        adopt = body(self.nvn, 'static void touch_adopt(uint64_t seq) {')
        self.assertIn('int drop = g_touch_drop;', adopt, 'a released atlas is retired as a replaced one')
        self.assertIn('if (f->on != TOUCH_ON ||', body(self.nvn, 'static void touch_draw(id<MTL4RenderCommandEncoder> en'))
        for weak in ('void front_touch_drawn(uint32_t seq) { (void)seq; }', 'void front_touch_unfit(void) {}'):
            self.assertIn('__attribute__((weak)) ' + weak, self.nvn)
        self.assertIn('__attribute__((weak)) void front_touch_draw_failed(void) {}', self.nvn)
        self.assertIn('void front_touch_draw_failed(void) {', self.front)

    def test_shader_functions_and_the_blended_pipeline(self):
        msl = read('dm/gfx/msl/present.metal')
        for fn in ('vertex TouchV vs_touch(', 'fragment float4 fs_touch(', 'fragment float4 fs_touch_grey('):
            self.assertIn(fn, msl)
        for name in ('@"vs_touch"', '@"fs_touch"', '@"fs_touch_grey"'): self.assertIn(name, body(self.nvn, 'static int touch_pipeline(MTLPixelFormat pf) {'))
        over = body(read('dm/gfx/nvn/host_msl.m'), 'id<MTLRenderPipelineState> host_msl_rps_over(')
        self.assertIn('MTLBlendFactorOne;', over)
        self.assertIn('MTLBlendFactorOneMinusSourceAlpha;', over)

    def test_harness_stubs_follow_the_calls(self):
        stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'); h = read('dm/host/touch_draw.h')
        calls = ('uint32_t mtl_present_touch(const touch_frame *f)', 'int mtl_present_touch_atlas(const void *px, int w, int h, size_t row, int channels, uint32_t gen)',
                 'void mtl_present_touch_ack(uint32_t seq)', 'void mtl_present_touch_release(void)', 'uint64_t mtl_present_touch_idle_ns(void)')
        for c in calls:
            self.assertIn(c + ';', h)
            self.assertIn(c + ' {', stubs)
            self.assertIn(c + ' {', self.nvn)
        for c in ('void front_touch_drawn(uint32_t seq);', 'void front_touch_unfit(void);', 'void front_touch_draw_failed(void);'): self.assertIn(c, h)


if __name__ == '__main__':
    unittest.main()
