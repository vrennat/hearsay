# Recording checklist

Things only a person at the keyboard can verify. Build 50 or later. Log: `~/Library/Logs/Hearsay.log`.

## Before
- [ ] System Settings → Notifications → Hearsay: allow (the log says notifications are not allowed).
- [ ] Settings → General: your first name (used for `Me`). Settings → Storage: audio 24 h, encrypt recordings on.

## Recording
- [ ] Start Recording from the menu. The Mic chip should turn on within a second and the log should show `Mic format 48000.0 Hz x 4` (MOTU M4), no `Code=512`.
- [ ] Ear icon shows a red dot, the whole icon does not turn red. Check in a light menu bar too.
- [ ] Notch pill: elapsed never wraps at 9:59 → 10:00; meter moves with your voice; hover grows one row with title and Stop.
- [ ] Play a YouTube video: Call chip lights, pill shows the faint blue call layer.
- [ ] Live Window: lines arrive within ~2 s, rename a speaker, name hints appear when someone says a name.
- [ ] Join a Zoom/Meet call: the call app pause works (no "another app is using the mic" complaints), "Meeting over?" prompt about 15 s after the call ends.
- [ ] Stop: menu shows Transcribing, then done; the title comes from the on-device model (or the calendar title when specific).

## After
- [ ] Open the meeting from Recent: toolbar, search, speakers inspector, playback with Both/Mic/Call, rename saves to transcript.md.
- [ ] `audio/` holds only `*.m4a.enc`; `hearsay speakers "<id>"` works from Terminal.
- [ ] Settings → Storage → Encrypt transcripts with a password: turn on, quit, relaunch, unlock window appears, transcript opens; `HEARSAY_PASSWORD=... hearsay export "<id>" /tmp/x` works.
- [ ] Dictation: enable, hold the key, speak, release; text pastes into the frontmost app (Accessibility prompt the first time).
- [ ] Accessibility: VoiceOver (⌘F5) through the menu and meeting window; Reduce Motion stops the meter animation; run Accessibility Inspector's audit on the menu and the meeting window.
- [ ] Close the lid while recording (Developer ID build): recording continues.
