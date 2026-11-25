// Raw HID gamepads that GameController does not list (an 8BitDo in its own mode: a Bluetooth HID gamepad macOS pairs, GitHub issue #637): one device's buttons, hat and axes
// as HID reports them, turned into Switch buttons and sticks. Pure, so tests/t_pad_hid.c checks it without a controller; pad_hid_mac.h reads the devices.
// Buttons by position, as front_mac.m maps GameController (right A, bottom B, top X, left Y). The default map is 8BitDo's D-input numbering (HID button usages 1 A, 2 B, 4 X,
// 5 Y, 7 / 8 LB / RB, 9 / 10 LT / RT, 11 select, 12 start, 14 / 15 stick clicks, by Xbox labels); DM_HID_MAP=A=2,B=1,… replaces entries, DM_HID_LOG=1 logs each usage pressed.
// Sticks: X / Y left, Z / Rz right (Rx / Ry on a device without Z); analog triggers (Brake / Accelerator) press ZL / ZR past half.
// Steam Link's virtual Xbox 360 pad, GamePad-N (045e:028e, GitHub issue #2465), delivers Xbox button usages and six Generic Desktop axes:
// X / Y left stick, Rx / Ry right stick, Z / Rz the two triggers (pad_hid_axis_for). That layout is selected only for the matching ID and axes (pad_hid_layout_for).
#pragma once
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "dm_input.h"

#define PAD_HID_DEFAULT_VENDOR 0x2DC8   // 8BitDo, whose numbering the default map is (another vendor's pad gets a log line saying so, pad_hid_mac.h)
enum { PH_X, PH_Y, PH_Z, PH_RX, PH_RY, PH_RZ, PH_BRAKE, PH_ACCEL, PH_AXES };
enum pad_hid_layout { PAD_HID_DEFAULT, PAD_HID_X360 };
typedef struct {
    uint32_t buttons;          // bit u - 1: HID button usage u held (usages 1..32)
    int hat;                   // -1 centered, 0 up, then clockwise to 7 up-left
    float axis[PH_AXES];       // -1..1 (a trigger rests at -1)
    uint8_t has[PH_AXES];      // the device has the axis
    uint8_t map[16];           // Switch button bit (dm_input.h order) -> HID button usage, 0 none
    enum pad_hid_layout layout;
} pad_hid;

static const char *const pad_hid_names[16] = {"A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "PLUS", "MINUS", "LEFT", "UP", "RIGHT", "DOWN"};
// Xbox 360 usages as macOS delivers Steam Link's virtual pad's values (measured one button at a time; not the descriptor's own order): 1 A (bottom), 2 B (right), 3 X (left),
// 4 Y (top), 5 / 6 LB / RB, 7 / 8 stick clicks, 9 start, 10 back, and the d-pad as buttons 12 up, 13 down, 14 left, 15 right; the triggers are axes
static const uint8_t pad_hid_x360_map[16] = {2, 1, 4, 3, 7, 8, 5, 6, 0, 0, 9, 10, 14, 12, 15, 13};
// has: the descriptor's axes, before any layout applies. A virtual pad can reuse the Xbox ID with dedicated Brake / Accelerator usages: that one keeps the default
static enum pad_hid_layout pad_hid_layout_for(int vid, int pid, const uint8_t has[PH_AXES]) {
    if (vid == 0x045e && pid == 0x028e && has[PH_X] && has[PH_Y] && has[PH_RX] && has[PH_RY] &&
        has[PH_Z] && has[PH_RZ] && !has[PH_BRAKE] && !has[PH_ACCEL]) return PAD_HID_X360;
    return PAD_HID_DEFAULT;
}

// Identical pads (front_mac.m, DM_PAD_IDENTICAL): whether every pad of one model is read as a player of its own, instead of through GameController.
// n: the pads of the model IOKit has; listed: GameController's controllers of it; read: whether they are read that way already; due: a wait after the last change is over.
// 1 read them, 0 do not, -1 not yet: a pad connected a moment ago may simply not be listed yet, so a model starts only after the wait, and stops at once
static inline int pad_dupes_want(int n, int listed, int read, int due) { return n < 2 || n <= listed ? 0 : read || due ? 1 : -1; }

// DM_HID_MAP: comma-separated NAME=usage entries over the layout's map (an unknown name or a usage past 32 is skipped)
static void pad_hid_init(pad_hid *h, const char *map, enum pad_hid_layout layout) {
    static const uint8_t def[16] = {2, 1, 5, 4, 14, 15, 7, 8, 9, 10, 12, 11};
    memset(h, 0, sizeof *h); h->hat = -1; h->layout = layout; memcpy(h->map, layout == PAD_HID_X360 ? pad_hid_x360_map : def, sizeof h->map);
    for (int a = 0; a < PH_AXES; a++) h->axis[a] = a >= PH_BRAKE ? -1 : 0;
    for (const char *s = map; s && *s; s = strchr(s, ',') ? strchr(s, ',') + 1 : "") {
        const char *eq = strchr(s, '='), *end = strchr(s, ','); if (!eq || (end && eq > end)) continue;
        int u = atoi(eq + 1);
        for (int b = 0; b < 16; b++) if ((size_t)(eq - s) == strlen(pad_hid_names[b]) && !strncasecmp(s, pad_hid_names[b], eq - s) && u >= 0 && u <= 32) h->map[b] = (uint8_t)u;
    }
}
static int pad_hid_axis_of(uint32_t page, uint32_t usage) {   // -1: not a gamepad axis
    if (page == 1 && usage >= 0x30 && usage <= 0x35) return PH_X + (int)(usage - 0x30);
    if (page == 2 && usage == 0xC5) return PH_BRAKE;
    if (page == 2 && usage == 0xC4) return PH_ACCEL;
    return -1;
}
// The same axis mapping for the descriptor's axes and the callback's values: on the Xbox 360 layout Z / Rz are the triggers, and the right stick is Rx / Ry
static int pad_hid_axis_for(enum pad_hid_layout layout, int axis) {
    if (layout == PAD_HID_X360 && axis == PH_Z) return PH_BRAKE;
    if (layout == PAD_HID_X360 && axis == PH_RZ) return PH_ACCEL;
    return axis;
}
static float pad_hid_norm(long v, long min, long max) { return max > min ? (float)(2.0 * (v - min) / (max - min) - 1) : 0; }
static int pad_hid_hat(long v, long min, long max) { return v >= min && v <= max && v - min < 8 ? (int)(v - min) : -1; }   // past the 8 directions: centered
// One stick: a round dead zone against drift (PAD_HID_DEAD of full deflection), and past it the deflection scaled back to start at 0, so the stick neither jumps to the dead zone's
// edge nor loses a small x while y is deflected. Each axis is clamped after the scale: a square-gated stick still reaches full x and y in its corners.
#define PAD_HID_DEAD 0.12f
static void pad_hid_stick(float x, float y, int32_t *ox, int32_t *oy) {
    float r = sqrtf(x * x + y * y);
    if (r <= PAD_HID_DEAD) { *ox = *oy = 0; return; }
    float k = (r - PAD_HID_DEAD) / (1 - PAD_HID_DEAD) / r; x *= k; y *= k;
    *ox = (int32_t)((x < -1 ? -1 : x > 1 ? 1 : x) * DM_STICK_MAX); *oy = (int32_t)((y < -1 ? -1 : y > 1 ? 1 : y) * DM_STICK_MAX);
}

static uint64_t pad_hid_buttons(const pad_hid *h) {
    static const uint64_t hat[8] = {DM_BTN_UP, DM_BTN_UP | DM_BTN_RIGHT, DM_BTN_RIGHT, DM_BTN_RIGHT | DM_BTN_DOWN, DM_BTN_DOWN, DM_BTN_DOWN | DM_BTN_LEFT, DM_BTN_LEFT, DM_BTN_LEFT | DM_BTN_UP};
    uint64_t m = 0;
    for (int b = 0; b < 16; b++) if (h->map[b] && h->buttons >> (h->map[b] - 1) & 1) m |= 1ull << b;
    if (h->hat >= 0 && h->hat < 8) m |= hat[h->hat];
    if (h->has[PH_BRAKE] && h->axis[PH_BRAKE] > 0) m |= DM_BTN_ZL;
    if (h->has[PH_ACCEL] && h->axis[PH_ACCEL] > 0) m |= DM_BTN_ZR;
    return m;
}
static void pad_hid_sticks(const pad_hid *h, int32_t s[4]) {   // lx, ly, rx, ry; HID's Y grows downward, the Switch's upward
    int z = h->has[PH_Z];
    pad_hid_stick(h->axis[PH_X], -h->axis[PH_Y], &s[0], &s[1]);
    pad_hid_stick(h->axis[z ? PH_Z : PH_RX], -h->axis[z ? PH_RZ : PH_RY], &s[2], &s[3]);
}
