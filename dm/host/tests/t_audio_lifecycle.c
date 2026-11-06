// The iOS audio session's lifecycle (../audio_lifecycle.h, plain C, no game profile or sound device): every order of the interruption notice, iOS 27's lifecycle
// notices, the scene callbacks and the media services reset that front_ios.m feeds it, and what real output does after each. A small front end below does what
// audio_life_on returns, in its order, as front_ios.m does: the activation (granted or rejected, as the test says), the units created again, dm_audio_suspend.
// make -C dm/host/tests GAME=<id> audio-lifecycle (also in run)
#include "../audio_lifecycle.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    audio_life s;
    int suspended;     // what dm_audio_suspend was last called with (it acts on a change only)
    int changes;       // how many times that changed: each is an "audio suspended" / "audio resumed" line
    int activations, resets;
    int grant;         // the next activations are granted (1) or rejected (0)
    int ended;         // what audio_life_activated returned last
    int note;
} fe;

static void apply(fe *f) { int on = audio_life_suspended(&f->s); if (on != f->suspended) { f->suspended = on; f->changes++; } }
static int ev(fe *f, int e, double now) {
    audio_life_do d = audio_life_on(&f->s, e, now);
    f->ended = 0;
    if (d.act & AUDIO_LIFE_ACTIVATE) { f->activations++; f->ended = audio_life_activated(&f->s, f->grant); }
    if (d.act & AUDIO_LIFE_RESET_UNITS) f->resets++;
    if (d.act & AUDIO_LIFE_APPLY) apply(f);
    return f->note = d.note;
}
static fe boot(int lifecycle) {   // main.m sets the session up at start (granted), then front_ios_audio_watch reads DM_AUDIO_LIFECYCLE
    fe f; memset(&f, 0, sizeof f); f.grant = 1;
    audio_life_activated(&f.s, 1); f.s.lifecycle = (unsigned char)lifecycle;
    return f;
}

int main(void) {
    // the notes' texts, as the log lines end
    assert(!strcmp(audio_life_note(AUDIO_LIFE_NOTE_NONE), "") && !strcmp(audio_life_note(AUDIO_LIFE_NOTE_RESUMING), "; resuming"));
    assert(!strcmp(audio_life_note(AUDIO_LIFE_NOTE_REJECTED), "; the last activation was rejected: left to the becoming-active retry"));
    assert(AUDIO_LIFE_RESUME_TRIES == 3 && strstr(audio_life_note(AUDIO_LIFE_NOTE_REJECTED_AGAIN), "the last 3 recommendations"));   // the line names the count

    // a call: "began", the deactivation by the system, the resumption, "ended", in that order. The first suspends, the second finds it suspended; the resumption
    // resumes and sets the session up, "ended" sets it up again and changes nothing
    fe f = boot(1);
    ev(&f, AUDIO_LIFE_BEGAN, 1); assert(f.suspended && f.changes == 1 && f.note == AUDIO_LIFE_NOTE_NONE);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1.01); assert(f.suspended && f.changes == 1 && f.note == AUDIO_LIFE_NOTE_ALREADY);
    ev(&f, AUDIO_LIFE_RESUME, 20); assert(!f.suspended && f.changes == 2 && f.activations == 1 && f.note == AUDIO_LIFE_NOTE_RESUMING);
    ev(&f, AUDIO_LIFE_ENDED, 20.01); assert(!f.suspended && f.changes == 2 && f.activations == 2);
    ev(&f, AUDIO_LIFE_ACTIVE, 20.02); assert(f.note == AUDIO_LIFE_NOTE_NONE && f.changes == 2);   // the activations' notices: nothing to end
    // the other order: the lifecycle notices first, then the old ones
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1); assert(f.suspended && f.note == AUDIO_LIFE_NOTE_NONE);
    ev(&f, AUDIO_LIFE_BEGAN, 1.01); assert(f.suspended && f.changes == 1);
    ev(&f, AUDIO_LIFE_ENDED, 9); assert(!f.suspended && f.changes == 2);
    ev(&f, AUDIO_LIFE_RESUME, 9.01); assert(!f.suspended && f.changes == 2 && f.note == AUDIO_LIFE_NOTE_SET_UP);
    // "should not resume" with the session up resumes too, as "ended" always has
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1); ev(&f, AUDIO_LIFE_RESUME_NOT, 5); assert(!f.suspended && f.activations == 1 && f.note == AUDIO_LIFE_NOTE_RESUMING);
    // the app's own deactivation changes nothing
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_APP, 1); assert(!f.suspended && !f.changes && !f.activations && f.note == AUDIO_LIFE_NOTE_NOTHING);

    // a deactivation by another app with no resumption and no "ended": the next activation's "became active" ends it, in the foreground only
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1); assert(f.suspended);
    ev(&f, AUDIO_LIFE_ACTIVE, 2); assert(!f.suspended && f.note == AUDIO_LIFE_NOTE_RESUMING && !f.activations);   // real output only: the session is already active
    f = boot(1);
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 2); ev(&f, AUDIO_LIFE_ACTIVE, 3);
    assert(f.suspended && f.s.intr && f.note == AUDIO_LIFE_NOTE_NONE);   // in the background: the return does it
    // a deactivation after "became active" (a late one): suspended, and nothing but its own end or the focus fallback resumes
    f = boot(1);
    ev(&f, AUDIO_LIFE_ACTIVE, 1); ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 2); assert(f.suspended);
    ev(&f, AUDIO_LIFE_FOCUS, 3); assert(!f.suspended && f.note == AUDIO_LIFE_NOTE_FALLBACK && f.activations == 1);

    // a suspension: the app goes to the background, iOS suspends it and deactivates the session, and its notice (no interruption context) comes once the app runs again
    // (a) before the return: the return and the focus resume
    f = boot(1);
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); assert(f.suspended && f.changes == 1);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 100); assert(f.s.intr && f.note == AUDIO_LIFE_NOTE_IN_BACKGROUND && !f.activations);
    ev(&f, AUDIO_LIFE_FOREGROUND, 100.1); assert(f.suspended && f.activations == 1);
    ev(&f, AUDIO_LIFE_FOCUS, 100.2); assert(!f.suspended && f.note == AUDIO_LIFE_NOTE_FALLBACK && f.activations == 2 && f.changes == 2);
    // (b) after the return and the focus, when nothing else would end it: the session is asked for and granted, and output never stops
    f = boot(1);
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); ev(&f, AUDIO_LIFE_FOREGROUND, 100); ev(&f, AUDIO_LIFE_ACTIVE, 100.01); ev(&f, AUDIO_LIFE_FOCUS, 100.02);
    assert(!f.suspended && f.changes == 2 && f.activations == 1);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 100.3); assert(f.note == AUDIO_LIFE_NOTE_RETAKE && f.activations == 2 && !f.suspended && f.changes == 2 && !f.ended);
    // (c) the same with the old notice's late "began" first: the granted activation ends that interruption too
    f = boot(1);
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); ev(&f, AUDIO_LIFE_FOREGROUND, 100); ev(&f, AUDIO_LIFE_FOCUS, 100.02);
    ev(&f, AUDIO_LIFE_BEGAN, 100.2); assert(f.suspended);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 100.3); assert(!f.suspended && f.ended == AUDIO_LIFE_RETAKE_DEACTIVATION);
    // a deactivation with no context while something holds the session: rejected, so an interruption after all, which its resumption ends
    f = boot(1); f.grant = 0;
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 5); assert(f.suspended && f.s.intr && f.s.off && !f.ended);
    f.grant = 1; ev(&f, AUDIO_LIFE_RESUME, 8); assert(!f.suspended && !f.s.off);
    // at most once a second: a second one within the second is an interruption, without asking
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 5); assert(f.activations == 1 && !f.suspended);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 5.5); assert(f.activations == 1 && f.suspended && f.note == AUDIO_LIFE_NOTE_RETAKE_SOON);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 5.6); assert(f.note == AUDIO_LIFE_NOTE_ALREADY);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 6.6); assert(f.activations == 2 && !f.suspended && f.ended == AUDIO_LIFE_RETAKE_DEACTIVATION);

    // a media services reset with a deactivation, in either order: the reset's granted activation ends the interruption, and the units are created again first
    f = boot(1);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1); assert(f.suspended);
    ev(&f, AUDIO_LIFE_RESET, 1.1); assert(!f.suspended && f.resets == 1 && f.activations == 1 && f.ended == AUDIO_LIFE_RETAKE_RESET);
    f = boot(1);
    ev(&f, AUDIO_LIFE_RESET, 1); assert(!f.suspended && f.resets == 1 && !f.ended);
    ev(&f, AUDIO_LIFE_INACTIVE_NO_CONTEXT, 1.1); assert(!f.suspended && f.activations == 2);   // the reset's deactivation, after it: asked for and granted
    // a reset while a call holds the session: the activation is rejected and the interruption stays, until it ends
    f = boot(1);
    ev(&f, AUDIO_LIFE_BEGAN, 1); f.grant = 0; ev(&f, AUDIO_LIFE_RESET, 2); assert(f.suspended && f.s.off && f.resets == 1);
    f.grant = 1; ev(&f, AUDIO_LIFE_ENDED, 9); assert(!f.suspended);
    // a reset in the background keeps the interruption for the return
    f = boot(1);
    ev(&f, AUDIO_LIFE_BEGAN, 1); ev(&f, AUDIO_LIFE_BACKGROUND, 2); ev(&f, AUDIO_LIFE_RESET, 3); assert(f.suspended && f.s.intr && !f.ended);

    // a rejected activation, then "should not resume": not activated again (that could be rejected again and bring the notice back); the focus retries
    f = boot(1);
    ev(&f, AUDIO_LIFE_BEGAN, 1); f.grant = 0; ev(&f, AUDIO_LIFE_ENDED, 2); assert(f.s.off && f.activations == 1);
    ev(&f, AUDIO_LIFE_RESUME_NOT, 2.01); assert(f.note == AUDIO_LIFE_NOTE_REJECTED && f.activations == 1);
    ev(&f, AUDIO_LIFE_RESUME_NOT, 2.02); assert(f.activations == 1);
    f.grant = 1; ev(&f, AUDIO_LIFE_FOCUS, 3); assert(f.activations == 2 && !f.s.off && !f.suspended);
    // "should resume" after a rejection activates again
    f = boot(1); f.grant = 0;
    ev(&f, AUDIO_LIFE_FOREGROUND, 1); assert(f.s.off);
    f.grant = 1; ev(&f, AUDIO_LIFE_RESUME, 1.5); assert(!f.s.off && f.activations == 2);
    // "should resume" answered by a rejection every time (each could bring the notice back): 3 activations, then the focus retry; a grant starts the count again
    f = boot(1); ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 1); f.grant = 0;
    for (int i = 0; i < 6; i++) ev(&f, AUDIO_LIFE_RESUME, 2 + i * 0.01);
    assert(f.activations == 3 && f.note == AUDIO_LIFE_NOTE_REJECTED_AGAIN && f.s.off);
    f.grant = 1; ev(&f, AUDIO_LIFE_FOCUS, 3); assert(f.activations == 4 && !f.s.off && !f.suspended && !f.s.resume_rejected);
    ev(&f, AUDIO_LIFE_INACTIVE_SYSTEM, 4); f.grant = 0; ev(&f, AUDIO_LIFE_RESUME, 5); assert(f.activations == 5 && f.s.resume_rejected == 1);
    // rejections by other activations (the return, the focus) do not count: a recommendation after them still activates
    f = boot(1); f.grant = 0;
    for (int i = 0; i < 4; i++) { ev(&f, AUDIO_LIFE_FOREGROUND, 1 + i); ev(&f, AUDIO_LIFE_FOCUS, 1.1 + i); }
    assert(f.s.off && !f.s.resume_rejected);
    f.grant = 1; ev(&f, AUDIO_LIFE_RESUME, 9); assert(!f.s.off && f.note == AUDIO_LIFE_NOTE_SET_UP);
    // a resumption in the background resumes nothing yet and sets nothing up
    f = boot(1);
    ev(&f, AUDIO_LIFE_BEGAN, 1); ev(&f, AUDIO_LIFE_BACKGROUND, 2); ev(&f, AUDIO_LIFE_RESUME, 3);
    assert(f.suspended && !f.s.intr && !f.activations && f.note == AUDIO_LIFE_NOTE_IN_BACKGROUND);
    ev(&f, AUDIO_LIFE_FOREGROUND, 4); assert(!f.suspended && f.activations == 1);

    // DM_AUDIO_LIFECYCLE=0: the lifecycle notices are not observed, and the rest is as before them. "became active" (were it fed) ends nothing, and the reset sets
    // the session and the units up without ending an interruption or applying it
    f = boot(0);
    ev(&f, AUDIO_LIFE_BEGAN, 1); ev(&f, AUDIO_LIFE_ACTIVE, 2); assert(f.suspended);
    int changes = f.changes;
    ev(&f, AUDIO_LIFE_RESET, 3); assert(f.suspended && f.s.intr && f.resets == 1 && f.activations == 1 && f.changes == changes && !f.ended);
    ev(&f, AUDIO_LIFE_FOCUS, 4); assert(!f.suspended && f.note == AUDIO_LIFE_NOTE_FALLBACK);
    // the background and its return, with a rejected activation on the way back that the focus retries (as before iOS 27)
    f = boot(0);
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); assert(f.suspended);
    f.grant = 0; ev(&f, AUDIO_LIFE_FOREGROUND, 2); assert(!f.suspended && f.s.off);
    f.grant = 1; ev(&f, AUDIO_LIFE_FOCUS, 3); assert(!f.s.off && f.activations == 2 && f.note == AUDIO_LIFE_NOTE_NONE);
    ev(&f, AUDIO_LIFE_FOCUS, 4); assert(f.activations == 2);   // nothing to retry

    // quiet: the session is not ours to read in the background, during an interruption, or after a rejected activation
    f = boot(1); assert(!audio_life_quiet(&f.s));
    ev(&f, AUDIO_LIFE_BACKGROUND, 1); assert(audio_life_quiet(&f.s)); ev(&f, AUDIO_LIFE_FOREGROUND, 2); assert(!audio_life_quiet(&f.s));
    ev(&f, AUDIO_LIFE_BEGAN, 3); assert(audio_life_quiet(&f.s)); ev(&f, AUDIO_LIFE_ENDED, 4); assert(!audio_life_quiet(&f.s));
    f.grant = 0; ev(&f, AUDIO_LIFE_FOCUS, 5); ev(&f, AUDIO_LIFE_FOREGROUND, 6); assert(audio_life_quiet(&f.s) && !f.suspended);
    puts("audio lifecycle: interruptions, lifecycle notices in either order, suspension, reset, rejected activations and the switch passed");
    return 0;
}
