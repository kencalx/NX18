// Opt-in player builds ignore saved diagnostic overrides while retaining the
// FPS/HUD, controller, language and normal launcher settings. The game profile
// and bundle still supply the renderer's required paths and compatibility keys.
#pragma once
#include <string.h>
// Kept from env.txt in a player build too, so the owner can A/B the X1.0 changes on the phone (docs/development.md, the player build's list): measurement-only diagnostics
// that change no behaviour (DM_NVN_WAITS: the wait ledger; DM_SLOWFRAME: the long-frame rows), and the switches that turn a profile's X1.0 change off or the field log back to X1.0's
// lines, and DM_NVN_GHOST, which takes a profile's ghost_table back to 512 (or sets another size). Named one by one: every other DM_NVN_* and test switch stays filtered
static const char *const dm_player_kept_keys[]={"DM_NVN_WAITS","DM_SLOWFRAME","DM_REPLAY_RT","DM_REPLAY_SPARES","DM_FPS_HOLD_BACKOFF","DM_FPS_RESUME","DM_MOVIE_RESTART","DM_FIELD_LOG","DM_NVN_GHOST"};
static inline int dm_player_diagnostic_key(const char *key) {
    // Encoding placement changes scheduling, not diagnostics or launcher state.
    if(!strcmp(key,"DM_NVN_ENC_THREAD"))return 0;
    for(unsigned i=0;i<sizeof dm_player_kept_keys/sizeof *dm_player_kept_keys;i++)if(!strcmp(key,dm_player_kept_keys[i]))return 0;
    static const char *const prefixes[]={"DM_NVN_","DM_TEST_","MTL_DEBUG_","MTL_SHADER_VALIDATION"};
    for(unsigned i=0;i<sizeof prefixes/sizeof *prefixes;i++)
        if(!strncmp(key,prefixes[i],strlen(prefixes[i])))return 1;
    static const char *const names[]={"DM_CTL","DM_KEYS","DM_KBD","DM_DETCLOCK","DM_SLOWFRAME","DM_PROBE","DM_MSL_DIR"};
    for(unsigned i=0;i<sizeof names/sizeof *names;i++)if(!strcmp(key,names[i]))return 1;
    return 0;
}
// A whole env.txt line: the key dropped as above, or DM_SLOWFRAME with an empty value or zeros. slow_on (hle_nvn.c) takes any value as on, and before the player build kept the key a
// leftover DM_SLOWFRAME=0 did nothing there; dropped, it still does nothing, and =0 is the off side of an A/B as with every other kept switch
static inline int dm_player_env_dropped(const char *key,const char *value) {
    if(dm_player_diagnostic_key(key))return 1;
    return !strcmp(key,"DM_SLOWFRAME")&&value&&strspn(value,"0")==strlen(value);
}
