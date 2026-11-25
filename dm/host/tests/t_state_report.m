// state_report.m: each domain's state changes once per real change, the menu and the background give back the state they covered, and the hold is its own domain.
// The states are read from the [state] log lines (StateReporting itself only records into the system's traces)
#define DM_LOG_IMPL   // this test's dm_log below reads the lines
#import <Foundation/Foundation.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "../state_report.m"

static char g_out[2048];
void dm_log(const char *fmt, ...) {
    char line[256]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    strlcat(g_out, line, sizeof g_out); strlcat(g_out, "\n", sizeof g_out);
}
static int fails;
static void expect(const char *want) {
    if (strcmp(g_out, want)) { fprintf(stderr, "FAIL\nwant:\n%sgot:\n%s", want, g_out); fails++; }
    g_out[0] = 0;
}
int main(void) {
    @autoreleasepool {
        dm_state_report(DM_STATE_SCREEN, "Gate");
        dm_state_report(DM_STATE_SCREEN, "Gate");   // a repeat: nothing
        dm_state_report(DM_STATE_SCREEN, "Loading");
        expect("[dm] [state] screen: Gate\n[dm] [state] screen: Loading\n");
        dm_state_menu(1);
        dm_state_report(DM_STATE_SCREEN, "Playing");   // the first frame under the menu: kept for its close
        dm_state_menu(0);
        expect("[dm] [state] screen: Menu\n[dm] [state] screen: Playing\n");
        dm_state_background(1); dm_state_background(1);
        dm_state_background(0);
        expect("[dm] [state] screen: Background\n[dm] [state] screen: Playing\n");
        dm_state_menu(1); dm_state_background(1); dm_state_background(0); dm_state_menu(0);
        expect("[dm] [state] screen: Menu\n[dm] [state] screen: Background\n[dm] [state] screen: Menu\n[dm] [state] screen: Playing\n");
        dm_state_report(DM_STATE_HOLD, "Frame rate cap"); dm_state_report(DM_STATE_HOLD, "Heat hold 30"); dm_state_report(DM_STATE_HOLD, "Heat hold 30");
        dm_state_report(DM_STATE_SCREEN, "Playing"); dm_state_report(7, "x"); dm_state_report(DM_STATE_SCREEN, ""); dm_state_report(DM_STATE_SCREEN, NULL);
        expect("[dm] [state] hold: Frame rate cap\n[dm] [state] hold: Heat hold 30\n");
        dispatch_sync(state_q(), ^{});   // the system's reporter took every change without raising
    }
    if (!fails) printf("t_state_report: ok\n");
    return fails != 0;
}
