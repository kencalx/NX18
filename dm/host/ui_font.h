// NX 18's UI font: one font, the player's own (the NSP script's --ui-font / UI_FONT), for every text NX 18 draws itself (the launchers, the in-game prompts and progress screens,
// the touch controls' key letters, the Mac's Cheats window), not the game's own text (its shared fonts are dm/font, hle_sdk16.c) and not what the system draws (menus, alerts,
// title bars, tooltips: docs/development.md, UI font). The app carries it as dm/uifont/ui.<ext> with Info.plist DMUIFontFile / DMUIFontName (build_ipa.sh, dm/mac/pack_app.py).
// Header-only, C and CoreText, so the iOS app (main.m, front_ios.m, DmGamepad.m), the Mac launcher (launcher.c, plain C) and the Mac host (front_mac.m, home_quit_mac.h) share it:
//   dm_ui_font_register(resources): once at start, before any view. DM_UI_FONT=<file> names the font, DM_UI_FONT=0 (or empty) turns it off; unset, Info.plist's DMUIFontFile under
//     resources (NULL: the environment only, as the Mac host). It registers the file for this process (CTFontManagerRegisterFontsForURL, kCTFontManagerScopeProcess), reads the
//     face's PostScript name from the file and publishes it as DM_UI_FONT_NAME, which every other part reads (another translation unit's copy of this header, Swift's NXFont,
//     a child process: launcher.c hands DM_UI_FONT to the host). Without a usable font DM_UI_FONT_NAME is unset and everything draws with the system font as before.
//   dm_ui_ctfont(size, emphasized): the UI font at size (times DM_UI_FONT_SCALE), else the system UI font. Characters the font lacks (a thin space, Hangul, Cyrillic, symbols)
//     come from the system font and its own fallbacks (a cascade list), as they would with the system font.
//   Objective-C: dm_ui_font(size, weight), dm_ui_mono_digits(size, weight), and dm_ui_label_text / dm_ui_field_text for text that wraps.
// The font has one weight: a weight asked for is the system font's alone (the face is never made bold, which Apple's text stacks do not synthesise), so headings keep their place
// by size and colour. iOS's Bold Text (accessibility) gives the system font at the asked weight. Its lines are only as tall as its ascent and descent (UIKit, AppKit and SwiftUI
// ignore its large line gap), tighter than the system font's: wrapped text gets DM_UI_LINE_SPACING of the size between lines. Its glyphs are larger than the system font's at one
// size: DM_UI_FONT_SCALE (default 0.9, 0.5 to 1.5) scales every size the UI asks for
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <TargetConditionals.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DM_UI_FN static __attribute__((unused))   // each part uses some of these
#define DM_UI_FONT_SCALE_DEFAULT 0.9   // the font's cap height is about 13 % above the system font's at one size
#define DM_UI_LINE_SPACING 0.3         // extra space between wrapped lines, in ems: the system font's lines are about 1.2 ems, this font's 1.0, and its descenders and accented
                                       // capitals reach past its ascent and descent (at 0.2 a "p" touched the "Ü" on the line below)

DM_UI_FN int dm_ui_font_info_string(const char *key, char *out, size_t n) {   // a string key of the main bundle's Info.plist
    CFBundleRef b = CFBundleGetMainBundle(); if (!b) return 0;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8); if (!k) return 0;
    CFTypeRef v = CFBundleGetValueForInfoDictionaryKey(b, k); CFRelease(k);
    return v && CFGetTypeID(v) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8) && *out;
}

DM_UI_FN int dm_ui_font_resolves(const char *ps) {   // a font of that PostScript name is available to this process (CTFontCreateWithName gives another one when it is not)
    CFStringRef want = CFStringCreateWithCString(NULL, ps, kCFStringEncodingUTF8); if (!want) return 0;
    CTFontRef f = CTFontCreateWithName(want, 12, NULL);
    CFStringRef got = f ? CTFontCopyPostScriptName(f) : NULL;
    int same = got && CFStringCompare(got, want, 0) == kCFCompareEqualTo;
    if (got) CFRelease(got);
    if (f) CFRelease(f);
    CFRelease(want);
    return same;
}

// Register the UI font for this process and publish its PostScript name (DM_UI_FONT_NAME); 1 when NX 18's text takes it, 0 for the system font. resources: the folder DMUIFontFile
// is relative to (the iOS app's bundle, the Mac app's Contents/Resources), or NULL for DM_UI_FONT alone
DM_UI_FN int dm_ui_font_register(const char *resources) {
    const char *env = getenv("DM_UI_FONT");
    char path[PATH_MAX] = "", rel[PATH_MAX] = "", listed[256] = "";
    unsetenv("DM_UI_FONT_NAME");   // set again below only for a font this process has
    if (env && (!*env || !strcmp(env, "0"))) { fprintf(stderr, "ui font: off (DM_UI_FONT=%s): the system font\n", env); return 0; }
    if (env) snprintf(path, sizeof path, "%s", env);
    else if (resources && dm_ui_font_info_string("DMUIFontFile", rel, sizeof rel)) {
        if (rel[0] == '/' || strstr(rel, "..")) { fprintf(stderr, "[RED] ui font: Info.plist DMUIFontFile is not a path inside the app (%s): the system font\n", rel); return 0; }
        snprintf(path, sizeof path, "%s/%s", resources, rel);
    } else return 0;   // the app has no UI font: the system font, as always
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFArrayRef descs = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
    char ps[256] = "";
    if (descs && CFArrayGetCount(descs) > 0) {
        CFStringRef n = (CFStringRef)CTFontDescriptorCopyAttribute((CTFontDescriptorRef)CFArrayGetValueAtIndex(descs, 0), kCTFontNameAttribute);
        if (n) { if (!CFStringGetCString(n, ps, sizeof ps, kCFStringEncodingUTF8)) ps[0] = 0; CFRelease(n); }
    }
    if (descs) CFRelease(descs);
    if (!*ps) { fprintf(stderr, "[RED] ui font: %s is no font this system reads: the system font\n", path); if (url) CFRelease(url); return 0; }
    CFErrorRef err = NULL;
    long code = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &err) ? 0 : err ? (long)CFErrorGetCode(err) : -1;
    if (err) CFRelease(err);
    CFRelease(url);
    // already registered (a second call, or the same name installed on this Mac): the name decides, as CoreText then finds a font by it
    if (!dm_ui_font_resolves(ps)) { fprintf(stderr, "[RED] ui font: %s could not be registered (CoreText error %ld): the system font\n", path, code); return 0; }
    if (code) fprintf(stderr, "ui font: %s was already available to this process (CoreText error %ld on registering %s)\n", ps, code, path);
    if (dm_ui_font_info_string("DMUIFontName", listed, sizeof listed) && strcmp(listed, ps))
        fprintf(stderr, "ui font: the file's PostScript name is %s, Info.plist DMUIFontName says %s: %s is used\n", ps, listed, ps);
    setenv("DM_UI_FONT_NAME", ps, 1);
    setenv("DM_UI_FONT", path, 0);   // a child process (the Mac host, which launcher.c starts) registers the same file
    fprintf(stderr, "ui font: %s registered (%s)\n", ps, path);
    return 1;
}

// The registered UI font's PostScript name, or NULL for the system font; taken once per translation unit, after dm_ui_font_register (the app's start). Text drawn first from
// another thread may meet the main thread here: one of them writes the name (done 0 -> 2 -> 1), the other waits for it, so neither reads a name half written
DM_UI_FN const char *dm_ui_font_ps(void) {
    static int done; static char name[256];
    if (__atomic_load_n(&done, __ATOMIC_ACQUIRE) != 1) {
        int zero = 0;
        if (__atomic_compare_exchange_n(&done, &zero, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            const char *n = getenv("DM_UI_FONT_NAME");
            if (n && *n && strlen(n) < sizeof name && dm_ui_font_resolves(n)) snprintf(name, sizeof name, "%s", n);
            __atomic_store_n(&done, 1, __ATOMIC_RELEASE);
        } else while (__atomic_load_n(&done, __ATOMIC_ACQUIRE) != 1) {}
    }
    return *name ? name : NULL;
}

DM_UI_FN CGFloat dm_ui_font_scale(void) {   // DM_UI_FONT_SCALE, 0.5 to 1.5, else the default; for the UI font only
    const char *s = getenv("DM_UI_FONT_SCALE");
    double v = s && *s ? strtod(s, NULL) : 0;
    return v >= 0.5 && v <= 1.5 ? (CGFloat)v : (CGFloat)DM_UI_FONT_SCALE_DEFAULT;
}

// The UI font at size (times the scale), or the system UI font (emphasized: the system's emphasized face, which the UI font does not have). +1 reference, the caller releases it
DM_UI_FN CTFontRef dm_ui_ctfont(CGFloat size, int emphasized) {
    CTFontRef sys = CTFontCreateUIFontForLanguage(emphasized ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, size, NULL);
    const char *ps = dm_ui_font_ps();
    if (!ps || !sys) return sys;
    // the fallback: the system font itself, then its own cascade list for the player's languages
    CFMutableArrayRef cascade = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CTFontDescriptorRef sd = CTFontCopyFontDescriptor(sys);
    if (sd) { CFArrayAppendValue(cascade, sd); CFRelease(sd); }
    CFArrayRef more = CTFontCopyDefaultCascadeListForLanguages(sys, NULL);
    if (more) { CFArrayAppendArray(cascade, more, CFRangeMake(0, CFArrayGetCount(more))); CFRelease(more); }
    CFStringRef name = CFStringCreateWithCString(NULL, ps, kCFStringEncodingUTF8);
    const void *keys[] = {kCTFontNameAttribute, kCTFontCascadeListAttribute}, *values[] = {name, cascade};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
    CTFontRef f = d ? CTFontCreateWithFontDescriptor(d, size * dm_ui_font_scale(), NULL) : NULL;
    if (d) CFRelease(d);
    CFRelease(attrs); CFRelease(name); CFRelease(cascade);
    if (!f) return sys;
    CFRelease(sys);
    return f;
}

#ifdef __OBJC__
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
typedef UIFont DMUIFont;
typedef UIFontWeight DMUIFontWeight;
DM_UI_FN int dm_ui_bold_text(void) { return UIAccessibilityIsBoldTextEnabled(); }   // Bold Text: the system font, whose weights follow it
#else
#import <AppKit/AppKit.h>
typedef NSFont DMUIFont;
typedef NSFontWeight DMUIFontWeight;
DM_UI_FN int dm_ui_bold_text(void) { return 0; }
#endif

DM_UI_FN int dm_ui_font_on(void) { return dm_ui_font_ps() && !dm_ui_bold_text(); }   // NX 18's text takes the UI font now

// The UI font at size (its one weight), else the system font at size and weight, as NX 18 drew before
DM_UI_FN DMUIFont *dm_ui_font(CGFloat size, DMUIFontWeight w) {
    if (!dm_ui_font_on()) return [DMUIFont systemFontOfSize:size weight:w];
    return (__bridge_transfer DMUIFont *)dm_ui_ctfont(size, 0);
}

// The emphasized system font of the touch controls' key letters (a CATextLayer's CTFont), or the UI font in its one weight. +1 reference
DM_UI_FN CTFontRef dm_ui_ctfont_emphasized(CGFloat size) {
    return dm_ui_font_on() ? dm_ui_ctfont(size, 1) : CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, size, NULL);
}

// Counters (frames per second, x of y): the UI font, whose digits are all one width already, else the system font with monospaced digits
DM_UI_FN DMUIFont *dm_ui_mono_digits(CGFloat size, DMUIFontWeight w) {
    if (!dm_ui_font_on()) return [DMUIFont monospacedDigitSystemFontOfSize:size weight:w];
    return dm_ui_font(size, w);
}

#if TARGET_OS_IPHONE
// A label's text that may wrap: with the UI font, the label's font, colour and alignment with DM_UI_LINE_SPACING between lines; else plain text, as before
DM_UI_FN void dm_ui_label_text(UILabel *l, NSString *text) {
    if (!dm_ui_font_on() || !text) { l.text = text; return; }
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = l.font.pointSize * DM_UI_LINE_SPACING; p.alignment = l.textAlignment;
    l.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: l.font, NSForegroundColorAttributeName: l.textColor ?: UIColor.labelColor,
                                                                                     NSParagraphStyleAttributeName: p}];
}
#else
// A text field's text that may wrap, as dm_ui_label_text
DM_UI_FN void dm_ui_field_text(NSTextField *t, NSString *text) {
    if (!dm_ui_font_on() || !text) { t.stringValue = text ?: @""; return; }
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = t.font.pointSize * DM_UI_LINE_SPACING; p.alignment = t.alignment;
    t.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: t.font, NSForegroundColorAttributeName: t.textColor ?: NSColor.labelColor,
                                                                                           NSParagraphStyleAttributeName: p}];
}
// A heading among plain rows (the Cheats window's sections): the bold system font, or the UI font a point larger, as it has no bold
DM_UI_FN NSFont *dm_ui_heading(CGFloat size) { return dm_ui_font_on() ? dm_ui_font(size + 1, NSFontWeightBold) : [NSFont boldSystemFontOfSize:size]; }
// A control of the Cheats window: the UI font at its control size's system size; untouched without it (AppKit's own font, as before)
DM_UI_FN void dm_ui_control(NSControl *c) {
    if (dm_ui_font_on()) c.font = dm_ui_font([NSFont systemFontSizeForControlSize:c.controlSize], NSFontWeightRegular);
}
#endif
#endif
