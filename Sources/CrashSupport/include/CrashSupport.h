#ifndef CRASH_SUPPORT_H
#define CRASH_SUPPORT_H

/// Installs fatal-signal handlers that relaunch the app. Stub until step 8.
void crash_support_install(const char *_Nonnull bundle_path, int resume_recording);

/// Updates whether a relaunch should pass --resume-recording. Stub until step 8.
void crash_support_set_recording(int recording);

/// Runs `block`, catching any Objective-C exception (AVAudioEngine and tap installation raise them).
/// Returns NULL on success, else a malloc'd "Name: reason" string the caller must free().
char *_Nullable hs_try_objc(__attribute__((noescape)) void (^_Nonnull block)(void));

#endif
