// StateReporting for NX 18 (state_report.h): the screen and frame-rate hold states, for the system's always-on Metal performance traces. Nothing leaves the device: the
// states live in the system's own traces, which the player collects and shares themselves
#import <Foundation/Foundation.h>
#import <StateReporting/StateReporting.h>
#include <os/lock.h>
#include <string.h>
#include "dm.h"
#include "state_report.h"

static os_unfair_lock g_state_lock = OS_UNFAIR_LOCK_INIT;
static char g_label[2][32], g_fg[32], g_under[32];   // the state reported in each domain; the screen state behind Background; the one the menu covers
static int g_bg, g_menu;
static NSString *const g_domain[2] = {@"com.nx18.screen", @"com.nx18.hold"};
static const char *const g_name[2] = {"screen", "hold"};

static dispatch_queue_t state_q(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("dm.state-report", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
    return q;
}
// Under g_state_lock: the domain's state becomes label when it is another; the system hears it off the caller's thread
static void state_set(int d, const char *label) {
    if (!strncmp(g_label[d], label, sizeof g_label[d] - 1)) return;
    strlcpy(g_label[d], label, sizeof g_label[d]);
    LOG("[state] %s: %s", g_name[d], label);
    NSString *s = @(label), *dom = g_domain[d];
    dispatch_async(state_q(), ^{ @autoreleasepool {
        [[SRStateReporter reporterForDomain:dom] reportTransitionToStateLabel:s stableMetadata:nil volatileMetadata:nil];
    } });
}
static void dm_state_set_screen_locked(const char *label) {   // under g_state_lock: the screen state, or the one shown when the app comes back
    if (g_bg) strlcpy(g_fg, label, sizeof g_fg); else state_set(DM_STATE_SCREEN, label);
}
void dm_state_report(int domain, const char *label) {
    if ((domain != DM_STATE_SCREEN && domain != DM_STATE_HOLD) || !label || !*label) return;
    os_unfair_lock_lock(&g_state_lock);
    if (domain == DM_STATE_SCREEN && g_menu) strlcpy(g_under, label, sizeof g_under);   // the first frame under the menu: shown when it closes
    else if (domain == DM_STATE_SCREEN && g_bg) strlcpy(g_fg, label, sizeof g_fg);   // shown when the app comes back
    else state_set(domain, label);
    os_unfair_lock_unlock(&g_state_lock);
}
void dm_state_background(int on) {
    os_unfair_lock_lock(&g_state_lock);
    if (on && !g_bg) { g_bg = 1; strlcpy(g_fg, g_label[DM_STATE_SCREEN], sizeof g_fg); state_set(DM_STATE_SCREEN, "Background"); }
    else if (!on && g_bg) { g_bg = 0; if (g_fg[0]) state_set(DM_STATE_SCREEN, g_fg); }
    os_unfair_lock_unlock(&g_state_lock);
}
void dm_state_menu(int open) {
    os_unfair_lock_lock(&g_state_lock);
    if (open && !g_menu) { strlcpy(g_under, g_bg ? g_fg : g_label[DM_STATE_SCREEN], sizeof g_under); g_menu = 1; dm_state_set_screen_locked("Menu"); }
    else if (!open && g_menu) { g_menu = 0; if (g_under[0]) dm_state_set_screen_locked(g_under); }
    os_unfair_lock_unlock(&g_state_lock);
}
