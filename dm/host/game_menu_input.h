// The Mac's in-game menu and its input (front_mac.m; the panel is dm/ios/Sources/GameMenuPanel.swift, hosted by dm/mac/GameMenuMac.swift). While the menu is open the game keeps
// running and gets no controller, keyboard or mouse input: every controller's buttons and left stick (each player's as the host reads it, pad_set) and the keyboard's keys go to the
// panel as one set of GM_* bits, which the panel turns into its moves (GameMenuMacPad: a press, a held direction repeating). Once it closes, the game gets its input back only when
// nothing is held any more (GM_SETTLE), so the B, A or Home that closed it never reaches the game. Pure, so tests/t_game_menu_input.c checks it without a window or a controller.
#pragma once
#include <stdint.h>
#include "dm_input.h"

// The panel's inputs, in the order of LauncherPadEvent (dm/ios/Sources/LauncherFocus.swift): up, down, left, right, A, B, X, Y, +, -, L, R, ZL, ZR
enum {
    GM_UP = 1u << 0, GM_DOWN = 1u << 1, GM_LEFT = 1u << 2, GM_RIGHT = 1u << 3, GM_A = 1u << 4, GM_B = 1u << 5, GM_X = 1u << 6, GM_Y = 1u << 7,
    GM_PLUS = 1u << 8, GM_MINUS = 1u << 9, GM_L = 1u << 10, GM_R = 1u << 11, GM_ZL = 1u << 12, GM_ZR = 1u << 13,
};

typedef enum {
    GM_CLOSED,   // the game has its input
    GM_OPEN,     // the panel has it
    GM_SETTLE,   // the panel closed: the game gets its input again once nothing is held
} gm_phase;

// The game gets no input in these phases
static inline int gm_blocks_input(gm_phase p) { return p != GM_CLOSED; }

// After an input change while settling: closed once nothing is held
static inline gm_phase gm_settle(gm_phase p, uint32_t held) { return p == GM_SETTLE && !held ? GM_CLOSED : p; }

// A controller's state as the panel reads it: the Switch buttons (dm_input.h DM_BTN_*, as the host maps the pad: A is the right button, or the one printed A on a Nintendo pad)
// and the D-pad, with the left stick past 60 % as the D-pad too (ly up is positive), as the Gate reads a pad (LauncherController.swift)
static inline uint32_t gm_bits(uint64_t m, int32_t lx, int32_t ly) {
    const int32_t t = DM_STICK_MAX * 6 / 10;
    uint32_t b = 0;
    if ((m & DM_BTN_UP) || ly > t) b |= GM_UP;
    if ((m & DM_BTN_DOWN) || ly < -t) b |= GM_DOWN;
    if ((m & DM_BTN_LEFT) || lx < -t) b |= GM_LEFT;
    if ((m & DM_BTN_RIGHT) || lx > t) b |= GM_RIGHT;
    if (m & DM_BTN_A) b |= GM_A;
    if (m & DM_BTN_B) b |= GM_B;
    if (m & DM_BTN_X) b |= GM_X;
    if (m & DM_BTN_Y) b |= GM_Y;
    if (m & DM_BTN_PLUS) b |= GM_PLUS;
    if (m & DM_BTN_MINUS) b |= GM_MINUS;
    if (m & DM_BTN_L) b |= GM_L;
    if (m & DM_BTN_R) b |= GM_R;
    if (m & DM_BTN_ZL) b |= GM_ZL;
    if (m & DM_BTN_ZR) b |= GM_ZR;
    return b;
}

// A key (macOS virtual key code) while the panel is open: the arrows and WASD move, Return, Space and J choose (A), Escape, Delete and K go back or close (B), U is X (Undo, or Back
// to the preset; zoom in, in a document), Q and E step the preset (L, R), and I, Z and C are Y, ZL and ZR, all as on the game's key map (front_mac.m key_bit). In a document,
// also - zooms out (Y) and [ and ] go to the previous and next one (ZL, ZR): keys the game's key map leaves free. 0 for any other key
static inline uint32_t gm_key(unsigned short code) {
    switch (code) {
    case 126: case 13: return GM_UP;      // ↑ W
    case 125: case 1: return GM_DOWN;     // ↓ S
    case 123: case 0: return GM_LEFT;     // ← A
    case 124: case 2: return GM_RIGHT;    // → D
    case 36: case 76: case 49: case 38: return GM_A;   // Return, keypad Enter, Space, J
    case 53: case 51: case 40: return GM_B;            // Escape, Delete, K
    case 32: return GM_X;                 // U
    case 12: return GM_L;                 // Q
    case 14: return GM_R;                 // E
    case 34: case 27: return GM_Y;        // I, -
    case 6: case 33: return GM_ZL;        // Z, [
    case 8: case 30: return GM_ZR;        // C, ]
    }
    return 0;
}

// The key that opens the menu over the game, besides the controller's Home and the app menu's Game Menu… (⌘,): Escape, which the game's key map leaves free
#define GM_OPEN_KEY 53
