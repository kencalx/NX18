// Real-time safety of the audio render callback, checked by the compiler: RT_NONBLOCKING marks a function clang's function effect analysis holds to "never blocks
// on a lock, never allocates, never throws" (the `nonblocking` attribute, clang.llvm.org/docs/FunctionEffectAnalysis.html), and RT_ACCEPTED marks the calls such a
// function makes knowingly, each with the reason it does not hold up the real-time thread. hle_audio.c marks au_render, pull_device and pull; the lint-c job builds
// hle_audio.c with -Wfunction-effects (dm/tools/lint_c.py DIAG_FLAGS), where a new blocking call in them is a finding, and the build itself does not turn it on.
// The attribute changes no generated code (clang: no runtime behaviour outside RealtimeSanitizer builds); a compiler without it (clang before 20) gets nothing.
// -DRT_NONBLOCKING= builds without it. The names start RT_, not DM_: a DM_ name is an environment switch (docs/env_switches.tsv, dm/tools/env_switches.py)
#pragma once

#ifndef RT_NONBLOCKING
#if defined(__has_attribute)
#if __has_attribute(nonblocking)
#define RT_NONBLOCKING __attribute__((nonblocking))
#endif
#endif
#endif
#ifndef RT_NONBLOCKING
#define RT_NONBLOCKING
#endif

// RT_ACCEPTED("why", statements;): statements an RT_NONBLOCKING function runs although the analysis cannot prove them safe, and why they are, through clang's
// documented way to exempt code from it (a diagnostic push, ignore and pop: FunctionEffectAnalysis.html, Disabling diagnostics). The reason must be a non-empty
// string literal; it stays in the source and costs nothing at run time. The statements go in a block of their own
#if defined(__clang__)
#define RT_ACCEPTED(why, ...)                                                                                          \
    _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wunknown-warning-option\"")                  \
    _Pragma("clang diagnostic ignored \"-Wfunction-effects\"")                                                         \
    { _Static_assert(sizeof("" why) > 1, "RT_ACCEPTED needs a reason"); __VA_ARGS__ }                                  \
    _Pragma("clang diagnostic pop")
#else   // another compiler has neither the attribute nor the analysis
#define RT_ACCEPTED(why, ...) { _Static_assert(sizeof("" why) > 1, "RT_ACCEPTED needs a reason"); __VA_ARGS__ }
#endif
