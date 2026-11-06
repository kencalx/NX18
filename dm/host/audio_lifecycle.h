// The iOS audio session's lifecycle as front_ios.m follows it: whether real audio output is suspended (the silent sink paces the game meanwhile) because the app is in
// the background or another session has interrupted ours, and when the session is set up again. Every notice and scene event goes through audio_life_on, which says
// what to do; the front end does it in the order of the AUDIO_LIFE_ACTIVATE / _RESET_UNITS / _APPLY bits. Plain C with no clock of its own (the caller passes the
// time), so dm/host/tests/t_audio_lifecycle.c runs each order of the notices on any machine. Nothing here changes what a game sees: it only picks between the AudioUnit and
// the silent sink, which keeps the game paced the same (dm_audio_suspend).
//
// The notices: the interruption notice ("began", "ended"), and on iOS 27 the lifecycle notices (developer.apple.com/documentation/avfaudio/handling-audio-interruptions):
// a deactivation (by the app or the system; the system's carries an interruption context only when another app interrupted), a resumption recommendation (after a
// system interruption ends, or after some rejected activations), and "became active". Both kinds may come for one interruption, in either order: the first changes the
// state, the second finds nothing to change (dm_audio_suspend acts on a change only; activating an active session changes nothing). With the lifecycle notices off
// (DM_AUDIO_LIFECYCLE=0, s->lifecycle 0) the transitions are those from before iOS 27: the interruption notice, the becoming-active fallback and the media services reset.
#pragma once

typedef struct {
    unsigned char bg;          // the app is in the background
    unsigned char intr;        // an interruption holds real output on the silent sink
    unsigned char off;         // the last activation was rejected (another app or a call still held the session): tried again when the app becomes active
    unsigned char lifecycle;   // iOS 27's lifecycle notices are observed (DM_AUDIO_LIFECYCLE, on unless 0)
    unsigned char retake;      // the activation asked for takes the session back (AUDIO_LIFE_RETAKE_*): its outcome decides the interruption (audio_life_activated)
    unsigned char by_resume;   // the activation asked for answers a resumption recommendation
    unsigned char resume_rejected;   // activations answering recommendations rejected in a row (none since one was granted)
    double retook_at;          // when a deactivation with no interruption context last took the session back (s; 0 never)
} audio_life;

enum {   // events: the notice or scene callback that came
    AUDIO_LIFE_BEGAN,               // the interruption notice, "began"
    AUDIO_LIFE_ENDED,               // the interruption notice, "ended"
    AUDIO_LIFE_INACTIVE_APP,        // iOS 27: the session was deactivated by the app (which never deactivates it)
    AUDIO_LIFE_INACTIVE_SYSTEM,     // iOS 27: deactivated by the system, with an interruption context: another app interrupted
    AUDIO_LIFE_INACTIVE_NO_CONTEXT, // iOS 27: deactivated by the system with no interruption context (no other app: a suspension's late notice, a reset), or no context at all
    AUDIO_LIFE_RESUME,              // iOS 27: resumption recommended, "should resume"
    AUDIO_LIFE_RESUME_NOT,          // iOS 27: resumption recommended, "should not resume", or no recommendation
    AUDIO_LIFE_ACTIVE,              // iOS 27: the session became active (after an activation of the app's)
    AUDIO_LIFE_BACKGROUND,          // the scene entered the background
    AUDIO_LIFE_FOREGROUND,          // the scene is returning to the foreground
    AUDIO_LIFE_FOCUS,               // the scene became active
    AUDIO_LIFE_RESET,               // the media services were reset
};
enum {   // what to do, in this order
    AUDIO_LIFE_ACTIVATE = 1,        // set the session up again (front_ios_audio_session), which reports how it went through audio_life_activated
    AUDIO_LIFE_RESET_UNITS = 2,     // create every output's AudioUnit again (dm_audio_reset)
    AUDIO_LIFE_APPLY = 4,           // dm_audio_suspend(audio_life_suspended(s))
};
enum {   // what the event did, for its log line (audio_life_note)
    AUDIO_LIFE_NOTE_NONE, AUDIO_LIFE_NOTE_NOTHING, AUDIO_LIFE_NOTE_ALREADY, AUDIO_LIFE_NOTE_RETAKE, AUDIO_LIFE_NOTE_RETAKE_SOON, AUDIO_LIFE_NOTE_IN_BACKGROUND,
    AUDIO_LIFE_NOTE_RESUMING, AUDIO_LIFE_NOTE_SET_UP, AUDIO_LIFE_NOTE_REJECTED, AUDIO_LIFE_NOTE_REJECTED_AGAIN, AUDIO_LIFE_NOTE_FALLBACK,
};
enum { AUDIO_LIFE_RESUME_TRIES = 3 };   // activations in a row a recommendation may have rejected before the next ones wait for the focus retry
enum { AUDIO_LIFE_RETAKE_NONE, AUDIO_LIFE_RETAKE_DEACTIVATION, AUDIO_LIFE_RETAKE_RESET };   // s->retake, and what audio_life_activated returns when it resumed
typedef struct { unsigned act; int note; } audio_life_do;

static inline int audio_life_suspended(const audio_life *s) { return s->bg || s->intr; }
// Our session is not the one playing (the background, an interruption, a rejected activation): what the session reports then is another's (front_ios_audio_settle)
static inline int audio_life_quiet(const audio_life *s) { return s->bg || s->intr || s->off; }

// The suffix of the event's log line
static inline const char *audio_life_note(int note) {
    switch (note) {
        case AUDIO_LIFE_NOTE_NOTHING: return "; nothing to do";
        case AUDIO_LIFE_NOTE_ALREADY: return "; already interrupted";
        case AUDIO_LIFE_NOTE_RETAKE: return "; no other app interrupted: taking the session back";
        case AUDIO_LIFE_NOTE_RETAKE_SOON: return "; taken back less than a second ago: waiting for a resumption instead";
        case AUDIO_LIFE_NOTE_IN_BACKGROUND: return "; in the background: the return to the foreground sets the session up again";
        case AUDIO_LIFE_NOTE_RESUMING: return "; resuming";
        case AUDIO_LIFE_NOTE_SET_UP: return "; not interrupted, the session set up again";
        case AUDIO_LIFE_NOTE_REJECTED: return "; the last activation was rejected: left to the becoming-active retry";
        case AUDIO_LIFE_NOTE_REJECTED_AGAIN: return "; the activations after the last 3 recommendations were rejected: left to the becoming-active retry";
        case AUDIO_LIFE_NOTE_FALLBACK: return "; resuming";
        default: return "";
    }
}

// The interruption ended: the session set up again unless in the background (the return to the foreground does it), then real output
static inline audio_life_do audio_life_resume(audio_life *s) {
    int was = s->intr; s->intr = 0;
    if (s->bg) return (audio_life_do){AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_IN_BACKGROUND};
    return (audio_life_do){AUDIO_LIFE_ACTIVATE | AUDIO_LIFE_APPLY, was ? AUDIO_LIFE_NOTE_RESUMING : AUDIO_LIFE_NOTE_SET_UP};
}

// One event at time now (seconds, any clock that does not go back): the state after it, and what to do
static inline audio_life_do audio_life_on(audio_life *s, int ev, double now) {
    switch (ev) {
        case AUDIO_LIFE_BEGAN: s->intr = 1; return (audio_life_do){AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_NONE};
        case AUDIO_LIFE_ENDED: { audio_life_do d = audio_life_resume(s); d.note = AUDIO_LIFE_NOTE_NONE; return d; }   // as before iOS 27: always resumes
        case AUDIO_LIFE_INACTIVE_APP: return (audio_life_do){0, AUDIO_LIFE_NOTE_NOTHING};
        case AUDIO_LIFE_INACTIVE_SYSTEM: {
            int was = s->intr; s->intr = 1;
            return (audio_life_do){AUDIO_LIFE_APPLY, was ? AUDIO_LIFE_NOTE_ALREADY : AUDIO_LIFE_NOTE_NONE};
        }
        case AUDIO_LIFE_INACTIVE_NO_CONTEXT:
            // No other app interrupted: the system deactivated the session while it suspended the app (that notice comes late, once the app runs again, possibly after
            // the app has activated its session on the way back and become active, when nothing else would end it) or with a media services reset. In the foreground
            // the session is asked for again: granted, nothing holds it and output goes on; rejected, something does, and the interruption waits for its end as above.
            // At most once a second, so that a system that keeps deactivating the session is not fought
            if (s->bg) { int was = s->intr; s->intr = 1; return (audio_life_do){AUDIO_LIFE_APPLY, was ? AUDIO_LIFE_NOTE_ALREADY : AUDIO_LIFE_NOTE_IN_BACKGROUND}; }
            if (s->retook_at > 0 && now - s->retook_at < 1.0) {
                int was = s->intr; s->intr = 1;
                return (audio_life_do){AUDIO_LIFE_APPLY, was ? AUDIO_LIFE_NOTE_ALREADY : AUDIO_LIFE_NOTE_RETAKE_SOON};
            }
            s->retook_at = now; s->retake = AUDIO_LIFE_RETAKE_DEACTIVATION;
            return (audio_life_do){AUDIO_LIFE_ACTIVATE | AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_RETAKE};
        case AUDIO_LIFE_RESUME:
        case AUDIO_LIFE_RESUME_NOT:
            // Either recommendation resumes, as "ended" always has (a game's sound is not playback its player paused), except "should not resume" right after a rejected
            // activation (Apple posts the recommendation after some of them): activating again would be rejected again, and could bring the same notice back. For the
            // same reason, once the activations answering AUDIO_LIFE_RESUME_TRIES recommendations in a row were rejected, the next wait for the focus retry or a grant
            if (ev == AUDIO_LIFE_RESUME_NOT && s->off) return (audio_life_do){0, AUDIO_LIFE_NOTE_REJECTED};
            if (s->off && s->resume_rejected >= AUDIO_LIFE_RESUME_TRIES) return (audio_life_do){0, AUDIO_LIFE_NOTE_REJECTED_AGAIN};
            {
                audio_life_do d = audio_life_resume(s);
                if (d.act & AUDIO_LIFE_ACTIVATE) s->by_resume = 1;
                return d;
            }
        case AUDIO_LIFE_ACTIVE:
            // The session is active again, after an activation of the app's (on the way back, the focus retry, a reset): an interruption whose end never came is over.
            // Real output only; the session needs no activation
            if (s->lifecycle && s->intr && !s->bg) { s->intr = 0; return (audio_life_do){AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_RESUMING}; }
            return (audio_life_do){0, AUDIO_LIFE_NOTE_NONE};
        case AUDIO_LIFE_BACKGROUND: s->bg = 1; return (audio_life_do){AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_NONE};
        case AUDIO_LIFE_FOREGROUND: s->bg = 0; return (audio_life_do){AUDIO_LIFE_ACTIVATE | AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_NONE};
        case AUDIO_LIFE_FOCUS: {
            // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            int note = AUDIO_LIFE_NOTE_NONE;
            if (s->intr) { s->intr = 0; s->off = 1; note = AUDIO_LIFE_NOTE_FALLBACK; }
            return (audio_life_do){(s->off ? AUDIO_LIFE_ACTIVATE : 0) | AUDIO_LIFE_APPLY, note};
        }
        case AUDIO_LIFE_RESET:
            // Every AudioUnit is invalid: the session is set up again and the units are created again. With the lifecycle notices, an activation that is granted also
            // ends an interruption (a reset can come with a deactivation, and nothing else would end it); before them, and in the background, the interruption stays
            if (!s->lifecycle) return (audio_life_do){AUDIO_LIFE_ACTIVATE | AUDIO_LIFE_RESET_UNITS, AUDIO_LIFE_NOTE_NONE};
            if (!s->bg) s->retake = AUDIO_LIFE_RETAKE_RESET;
            return (audio_life_do){AUDIO_LIFE_ACTIVATE | AUDIO_LIFE_RESET_UNITS | AUDIO_LIFE_APPLY, AUDIO_LIFE_NOTE_NONE};
    }
    return (audio_life_do){0, AUDIO_LIFE_NOTE_NONE};
}

// The activation's outcome (ok: setActive granted it). Returns the AUDIO_LIFE_RETAKE_* kind when a granted activation ended an interruption, for the log, else 0
static inline int audio_life_activated(audio_life *s, int ok) {
    int kind = s->retake, ended = 0;
    if (ok) s->resume_rejected = 0;
    else if (s->by_resume && s->resume_rejected < 255) s->resume_rejected++;
    s->off = !ok; s->retake = AUDIO_LIFE_RETAKE_NONE; s->by_resume = 0;
    if (kind == AUDIO_LIFE_RETAKE_DEACTIVATION) {   // granted: nothing holds the session, output goes on; rejected: an interruption after all
        if (ok) { ended = s->intr; s->intr = 0; } else s->intr = 1;
    } else if (kind == AUDIO_LIFE_RETAKE_RESET && ok && !s->bg) { ended = s->intr; s->intr = 0; }
    return ended ? kind : AUDIO_LIFE_RETAKE_NONE;
}
