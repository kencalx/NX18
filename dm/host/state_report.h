// What NX 18 is doing, told to iOS / macOS 27's StateReporting (state_report.m), so a Lookback performance trace (Settings › Developer › Performance Trace, metalperftrace),
// Instruments' Points of Interest and the Metal Performance HUD show each slowdown against it. Two domains, each in one state at a time:
//   screen: Gate, Loading, Playing, Menu (NX 18's in-game panel), Background
//   hold:   Frame rate cap, Heat hold 30, Low Power hold 30 (hle_nvn.c thermal_capped)
// Calls come at the pace of the player's actions (the system rate-limits faster ones); a repeat of the current state does nothing. Any thread. Each change is also a log line ([state])
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
enum { DM_STATE_SCREEN = 0, DM_STATE_HOLD = 1 };
void dm_state_report(int domain, const char *label);
void dm_state_background(int on);
void dm_state_menu(int open);   // NX 18's in-game panel opened (1) or closed (0): screen shows Menu, then the state it covered (Loading or Playing)   // the app went to (1) or came back from (0) the background: screen shows Background, then the state it left
#ifdef __cplusplus
}
#endif
