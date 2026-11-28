// The Mac's in-game menu input (game_menu_input.h): a controller's buttons and left stick as the panel's bits, the keys while it is up, and the settle phase that keeps the
// press that closed it from the game
#include "../game_menu_input.h"
#include <stdio.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

int main(void) {
    CHECK(gm_bits(0, 0, 0) == 0, "nothing held, nothing for the panel");
    CHECK(gm_bits(DM_BTN_A | DM_BTN_B, 0, 0) == (GM_A | GM_B), "A and B");
    CHECK(gm_bits(DM_BTN_UP | DM_BTN_RIGHT, 0, 0) == (GM_UP | GM_RIGHT), "the D-pad");
    CHECK(gm_bits(DM_BTN_PLUS | DM_BTN_MINUS | DM_BTN_L | DM_BTN_R | DM_BTN_ZL | DM_BTN_ZR | DM_BTN_X | DM_BTN_Y, 0, 0) ==
          (GM_PLUS | GM_MINUS | GM_L | GM_R | GM_ZL | GM_ZR | GM_X | GM_Y), "the other buttons");
    CHECK(gm_bits(DM_BTN_LS | DM_BTN_RS | DM_BTN_SHAKE, 0, 0) == 0, "stick presses and a shake are nothing to the panel");
    CHECK(gm_bits(0, DM_STICK_MAX, 0) == GM_RIGHT && gm_bits(0, -DM_STICK_MAX, 0) == GM_LEFT, "the left stick left and right");
    CHECK(gm_bits(0, 0, DM_STICK_MAX) == GM_UP && gm_bits(0, 0, -DM_STICK_MAX) == GM_DOWN, "the left stick up (positive) and down");
    CHECK(gm_bits(0, DM_STICK_MAX / 2, -DM_STICK_MAX / 2) == 0, "a stick at half is no move");
    CHECK(gm_bits(0, DM_STICK_MAX * 7 / 10, 0) == GM_RIGHT, "past 60 % is a move");

    CHECK(gm_key(126) == GM_UP && gm_key(125) == GM_DOWN && gm_key(123) == GM_LEFT && gm_key(124) == GM_RIGHT, "the arrows move");
    CHECK(gm_key(13) == GM_UP && gm_key(1) == GM_DOWN && gm_key(0) == GM_LEFT && gm_key(2) == GM_RIGHT, "WASD move");
    CHECK(gm_key(36) == GM_A && gm_key(49) == GM_A && gm_key(38) == GM_A, "Return, Space and J choose");
    CHECK(gm_key(53) == GM_B && gm_key(51) == GM_B && gm_key(40) == GM_B, "Escape, Delete and K go back");
    CHECK(gm_key(32) == GM_X && gm_key(12) == GM_L && gm_key(14) == GM_R, "U, Q and E as on the game's key map");
    CHECK(gm_key(34) == GM_Y && gm_key(6) == GM_ZL && gm_key(8) == GM_ZR, "I, Z and C as on the game's key map (Y, ZL, ZR)");
    CHECK(gm_key(27) == GM_Y && gm_key(33) == GM_ZL && gm_key(30) == GM_ZR, "- zooms out, [ and ] step the documents");
    CHECK(gm_key(3) == 0 && gm_key(24) == 0, "keys the panel has no use for (F, =)");
    CHECK(GM_OPEN_KEY == 53, "Escape opens it");

    CHECK(!gm_blocks_input(GM_CLOSED) && gm_blocks_input(GM_OPEN) && gm_blocks_input(GM_SETTLE), "the game's input waits while open and settling");
    CHECK(gm_settle(GM_SETTLE, GM_B) == GM_SETTLE, "B that closed it still held: settling");
    CHECK(gm_settle(GM_SETTLE, 0) == GM_CLOSED, "nothing held: the game has its input again");
    CHECK(gm_settle(GM_OPEN, 0) == GM_OPEN, "open stays open");
    CHECK(gm_settle(GM_CLOSED, GM_A) == GM_CLOSED, "closed stays closed");

    printf("t_game_menu_input: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
