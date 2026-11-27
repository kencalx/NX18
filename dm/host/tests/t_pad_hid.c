// Raw HID gamepads (pad_hid.h, GitHub issue #637): the default map and DM_HID_MAP, the Xbox 360 layout of virtual pads (issue #2465), hat directions, axis scaling, the stick dead zone and analog triggers
#include <stdio.h>
#include "../pad_hid.h"

static int checks, fails;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

int main(void) {
    pad_hid h; int32_t s[4];
    pad_hid_init(&h, NULL, PAD_HID_DEFAULT);
    CHECK(pad_hid_buttons(&h) == 0);
    h.buttons = 1u << 1; CHECK(pad_hid_buttons(&h) == DM_BTN_A);             // usage 2 (right) is A
    h.buttons = 1u << 0; CHECK(pad_hid_buttons(&h) == DM_BTN_B);             // usage 1 (bottom) is B
    h.buttons = 1u << 11 | 1u << 9; CHECK(pad_hid_buttons(&h) == (DM_BTN_PLUS | DM_BTN_ZR));
    pad_hid_init(&h, "a=1,B=2,bogus=3,ZR=99,X=,MINUS=13", PAD_HID_DEFAULT);
    h.buttons = 1u << 0; CHECK(pad_hid_buttons(&h) == DM_BTN_A);
    h.buttons = 1u << 12; CHECK(pad_hid_buttons(&h) == DM_BTN_MINUS);
    h.buttons = 1u << 9; CHECK(pad_hid_buttons(&h) == DM_BTN_ZR);           // 99 skipped: the default stays
    h.buttons = 1u << 4; CHECK(pad_hid_buttons(&h) == 0);                    // X= maps X to nothing
    pad_hid_init(&h, NULL, PAD_HID_DEFAULT);
    CHECK(pad_hid_hat(1, 1, 8) == 0 && pad_hid_hat(0, 1, 8) == -1 && pad_hid_hat(8, 0, 7) == -1 && pad_hid_hat(15, 0, 15) == -1);
    h.hat = pad_hid_hat(4, 1, 8); CHECK(pad_hid_buttons(&h) == (DM_BTN_DOWN | DM_BTN_RIGHT));
    CHECK(pad_hid_axis_of(1, 0x30) == PH_X && pad_hid_axis_of(1, 0x35) == PH_RZ && pad_hid_axis_of(2, 0xC5) == PH_BRAKE && pad_hid_axis_of(1, 0x39) == -1);
    CHECK(pad_hid_norm(0, 0, 65535) == -1 && pad_hid_norm(65535, 0, 65535) == 1 && pad_hid_norm(5, 3, 3) == 0);
    h.has[PH_X] = h.has[PH_Y] = h.has[PH_Z] = h.has[PH_RZ] = 1;
    h.axis[PH_X] = 1; h.axis[PH_Y] = -1; h.axis[PH_Z] = 0.05f; h.axis[PH_RZ] = 0.04f;
    pad_hid_sticks(&h, s);
    CHECK(s[0] == DM_STICK_MAX && s[1] == DM_STICK_MAX);                     // Y up; a square-gated corner reaches full x and y
    CHECK(s[2] == 0 && s[3] == 0);                                           // inside the round dead zone
    h.axis[PH_RZ] = 0.5f; pad_hid_sticks(&h, s);
    CHECK(s[2] > 0 && s[3] < 0 && s[3] > -DM_STICK_MAX / 2);                 // past it: the small x stays, the deflection is scaled back
    h.axis[PH_X] = 0.13f; h.axis[PH_Y] = 0; pad_hid_sticks(&h, s);
    CHECK(s[0] > 0 && s[0] < DM_STICK_MAX / 50 && s[1] == 0);                // just past the edge: near 0, no jump
    h.has[PH_Z] = 0; h.has[PH_RX] = 1; h.axis[PH_RX] = -1; pad_hid_sticks(&h, s); CHECK(s[2] == -DM_STICK_MAX && s[3] == 0);   // Rx / Ry without Z
    h.has[PH_ACCEL] = 1; h.axis[PH_ACCEL] = -1; CHECK(!(pad_hid_buttons(&h) & DM_BTN_ZR));
    h.axis[PH_ACCEL] = pad_hid_norm(200, 0, 255); CHECK(pad_hid_buttons(&h) & DM_BTN_ZR);
    // The Xbox 360 layout (a virtual 045e:028e pad read as HID, Steam Link's GamePad-N, issue #2465): one-at-a-time presses of a GameSir G8 through Steam Link as macOS
    // delivered them: bottom, right, top, left, back, start, LB, RB, then the d-pad up, right, down, left
    uint8_t has[PH_AXES] = {[PH_X] = 1, [PH_Y] = 1, [PH_Z] = 1, [PH_RX] = 1, [PH_RY] = 1, [PH_RZ] = 1};
    CHECK(pad_hid_layout_for(0x045e, 0x028e, has) == PAD_HID_X360);
    CHECK(pad_hid_layout_for(0x045e, 0x02ea, has) == PAD_HID_DEFAULT);
    CHECK(pad_hid_layout_for(0x054c, 0x028e, has) == PAD_HID_DEFAULT);
    has[PH_RX] = 0; CHECK(pad_hid_layout_for(0x045e, 0x028e, has) == PAD_HID_DEFAULT);
    has[PH_RX] = 1; has[PH_ACCEL] = 1; CHECK(pad_hid_layout_for(0x045e, 0x028e, has) == PAD_HID_DEFAULT);
    pad_hid_init(&h, NULL, PAD_HID_X360); CHECK(h.layout == PAD_HID_X360);
    { static const unsigned usage[] = {1, 2, 4, 3, 10, 9, 5, 6, 12, 15, 13, 14};
      static const uint64_t want[] = {DM_BTN_B, DM_BTN_A, DM_BTN_X, DM_BTN_Y, DM_BTN_MINUS, DM_BTN_PLUS, DM_BTN_L, DM_BTN_R, DM_BTN_UP, DM_BTN_RIGHT, DM_BTN_DOWN, DM_BTN_LEFT};
      for (unsigned i = 0; i < sizeof usage / sizeof *usage; i++) { h.buttons = 1u << (usage[i] - 1); CHECK(pad_hid_buttons(&h) == want[i]); } }
    h.buttons = 1u << 6 | 1u << 7; CHECK(pad_hid_buttons(&h) == (DM_BTN_LS | DM_BTN_RS));
    h.buttons = 0;
    CHECK(pad_hid_axis_for(PAD_HID_X360, PH_Z) == PH_BRAKE && pad_hid_axis_for(PAD_HID_X360, PH_RZ) == PH_ACCEL);
    CHECK(pad_hid_axis_for(PAD_HID_X360, PH_RX) == PH_RX && pad_hid_axis_for(PAD_HID_X360, PH_X) == PH_X);
    CHECK(pad_hid_axis_for(PAD_HID_DEFAULT, PH_Z) == PH_Z && pad_hid_axis_for(PAD_HID_DEFAULT, PH_RZ) == PH_RZ);
    h.has[PH_X] = h.has[PH_Y] = h.has[PH_RX] = h.has[PH_RY] = h.has[PH_BRAKE] = h.has[PH_ACCEL] = 1;   // the axes hidpad_found sets on it: no Z
    h.axis[PH_X] = pad_hid_norm(16384, -32768, 32767); h.axis[PH_Y] = pad_hid_norm(-32768, -32768, 32767);
    h.axis[PH_RX] = pad_hid_norm(-32768, -32768, 32767); h.axis[PH_RY] = pad_hid_norm(0, -32768, 32767);
    h.axis[PH_BRAKE] = pad_hid_norm(255, 0, 255); h.axis[PH_ACCEL] = pad_hid_norm(0, 0, 255);
    pad_hid_sticks(&h, s);
    CHECK(s[0] > DM_STICK_MAX / 3 && s[0] < DM_STICK_MAX * 2 / 3 && s[1] == DM_STICK_MAX);   // a half push stays a half push
    CHECK(s[2] == -DM_STICK_MAX && abs(s[3]) < 2);                                          // the right stick from Rx / Ry
    CHECK(pad_hid_buttons(&h) == DM_BTN_ZL);                                                // left trigger down, right one up
    pad_hid_init(&h, "A=1,B=2", PAD_HID_X360); h.buttons = 1u << 0; CHECK(pad_hid_buttons(&h) == DM_BTN_A);   // DM_HID_MAP still replaces entries
    // identical pads: a model is read here only with two or more pads and more than GameController lists, after the wait, and stops at once
    CHECK(pad_dupes_want(1, 0, 0, 1) == 0); CHECK(pad_dupes_want(2, 2, 1, 0) == 0); CHECK(pad_dupes_want(3, 3, 0, 1) == 0);
    CHECK(pad_dupes_want(2, 1, 0, 0) == -1); CHECK(pad_dupes_want(2, 1, 0, 1) == 1); CHECK(pad_dupes_want(2, 0, 0, 1) == 1);
    CHECK(pad_dupes_want(3, 1, 1, 0) == 1);   // a third pad of a model read already joins it without a wait
    CHECK(pad_dupes_want(1, 1, 1, 0) == 0);   // one unplugged: back to GameController

    // Betop Kunpeng 20 in NS mode over USB (S2Arm 0d4e4c702's idea): its two names over USB with the Pro Controller's ID, and nothing else
    CHECK(pad_hid_kp20(0x057e, 0x2009, "USB", "BTP-KP20E NS WIRED") && pad_hid_kp20(0x057e, 0x2009, "USB", "BTP-KP20E NS DONGLE") && pad_hid_kp20(0x057e, 0x2009, "usb", "btp-kp20e ns wired"));
    CHECK(!pad_hid_kp20(0x057e, 0x2009, "USB", "Pro Controller") && !pad_hid_kp20(0x057e, 0x2009, "USB", "BTP-KP20E NS"));     // a Pro Controller; no prefix match
    CHECK(!pad_hid_kp20(0x057e, 0x2009, "Bluetooth", "BTP-KP20E NS DONGLE"));                                                   // not over Bluetooth
    CHECK(!pad_hid_kp20(0x045e, 0x2009, "USB", "BTP-KP20E NS WIRED") && !pad_hid_kp20(0x057e, 0x2007, "USB", "BTP-KP20E NS WIRED"));   // another ID
    CHECK(!pad_hid_kp20(0x057e, 0x2009, NULL, "BTP-KP20E NS WIRED") && !pad_hid_kp20(0x057e, 0x2009, "USB", NULL));
    printf("t_pad_hid: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
