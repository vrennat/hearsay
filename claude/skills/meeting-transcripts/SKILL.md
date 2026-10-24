---
name: meeting-transcripts
description: Read and manage the user's recorded meetings in ~/Meetings (written by Hearsay). Use when the user asks about their meetings, calls or transcripts, what was said or decided, who said what, action items or follow-ups, a meeting summary, or wants to rename speakers or retitle or reprocess a meeting.
---

# Meeting transcripts (Hearsay)

Hearsay records meetings on this Mac and writes plain files to `~/Meetings` (another folder when the user chose
one; `~/Meetings/CLAUDE.md` is the folder's own reading guide). One folder per meeting, named
`yyyy-MM-dd HHmm <title>`. **The folder name is the meeting id** every `hearsay` command takes.

## 1. Find the meeting: read the index first

- `~/Meetings/index.md`: a table, newest first:
  `| Date | Title | Duration | Speakers named | Status |`. Title links to `<id>/transcript.md`. "Speakers named"
  is `named/main` (e.g. `2/3`).
- `~/Meetings/index.jsonl`: one JSON object per line, keys sorted: `endedAt`, `id`, `named`, `path`, `speakers`
  (each `id`, `label`, `main`, `name`, `talkSeconds`), `startedAt`, `status`, `title`. Dates are ISO 8601.
  Use it to filter by date, title or attendee name without opening every folder.

Match "yesterday's standup" or "my call with Rob" against `title`, `startedAt` and speaker names.

### Encrypted folders

If the meeting folder has `transcript.md.enc` instead of `transcript.md` (and `~/Meetings/.hearsay-vault.json`
says `"enabled": true`), transcripts are encrypted with the user's password and the index has titles and dates
only. Do not try to read `.enc` files. Ask the user to run commands with `HEARSAY_PASSWORD` set (every `hearsay`
command reads it), and use `hearsay export <id> --to <dir>` to get plaintext copies to read. `audio/*.enc` is
recording audio encrypted with a Keychain key; `hearsay process` reads it directly.

## 2. Read the meeting

In `~/Meetings/<id>/`:

- **`transcript.md`**: the one to read. YAML front matter, then turns:

  ```
  ---
  title: "Rob / Tanner"
  started: 2026-10-23T09:30:00.000Z
  ended: 2026-10-23T10:02:11.000Z
  duration: "32:11"
  engine: parakeet
  status: done
  named: false
  cleaned_by: "hearsay"
  attendees:
    - "Rob Smith"
  speakers:
    - id: mic-1
      name: "Tanner"
      label: "Me"
      talk_time: "14:02"
    - id: sys-1
      name: null
      label: "Remote 1"
      talk_time: "16:40"
  ---

  # Transcript

  [00:05] **Tanner:** Morning, can you hear me?
  ```

  - Speaker ids: `mic-N` are voices in the room (the user's microphone), `sys-N` are remote voices from call audio.
  - `name: null` means unnamed; the transcript then shows the `label` (`Me`, `Room N`, `Remote N`).
  - `named: true` only when every main speaker (5%+ of its stream's talk time) has a name. When it is `false`,
    say who is unnamed instead of guessing; offer `hearsay hints` and `hearsay rename`.
  - `cleaned_by:` present means fillers ("um", "uh") and stutters were removed. Absent means verbatim.
  - Body is `# No speech` with no turns when nothing was transcribed.
- **`transcript.raw.md`**: same front matter (without `cleaned_by:`), verbatim text. Use it when exact wording
  matters (quotes, disputes about what was said).
- **`meeting.json`**: `title`, `startedAt`, `endedAt`, `attendees`, `me`, `speakerNames`, `streams`, `status`, `error`.
  - `status`: `recording` (still going), `recorded` (waiting to be processed), `processing`, `done`, `failed`.
  - `error` on a `failed` meeting says why (`no audio captured`, `no speech: ...`, ...).
  - `error: "interrupted"` on a `done` meeting: the app stopped mid-recording (crash, quit, power); the transcript
    covers only what was captured. Say so when summarising. `interrupted; <reason>` on a `failed` meeting means
    it was interrupted and then failed.
- **`live.md`**: the rolling transcript written while recording (`# Live transcript`, `Updated <date>`, then the
  same `[mm:ss] **Name:** text` turns). Use it when `status` is `recording` or `transcript.md` does not exist yet.
  It is rougher than the final transcript and its speaker ids do not match the final ones.
- `transcript.json`, `cleanup.json`, `live.json`: the data the Markdown is generated from. `audio/`: the recording.

Timestamps `[mm:ss]` (or `[h:mm:ss]`) are from the meeting start. For action items, decisions and follow-ups,
attribute each to the speaker who said it and cite the timestamp.

## 3. Change things with the `hearsay` CLI, never by editing files

All Markdown and both index files are **regenerated** from the JSON; edits to them are lost on the next
render. Use the CLI (installed as `hearsay`). Every command takes `--root <folder>` (default `~/Meetings`);
pass it when the user's folder is elsewhere. Quote ids: they contain spaces.

- `hearsay speakers "<id>"`: speakers with ids, labels, names and talk time. Run before renaming.
- `hearsay rename "<id>" <speaker-id> "<Name>"`: name a speaker, e.g. `sys-1 "Rob"`. Empty name `""` clears it.
  Re-renders the transcript and index.
- `hearsay title "<id>" "<New title>"`: retitle. The folder name (id) stays.
- `hearsay hints "<id>"`: name suggestions from how people address each other. Suggestions only; confirm with the
  user before renaming.
- `hearsay process "<id>"`: rerun transcription, speakers and naming. Slow; speaker ids may change, so names
  typed earlier can land on other voices (it warns). Refuses when the audio was removed.
- `hearsay cleanup "<id>"`: rewrite the filler-free text.
- `hearsay retention --audio-days N --transcript-days N`: lists what would be deleted; `--apply` does it. Never add
  `--apply` without the user's explicit go-ahead.
- `hearsay summaries`: on-device summaries, if this build has it (run bare `hearsay` to list the commands).
- `hearsay reindex`: regenerate every Markdown file and the index.

Do not run `process`, `retention --apply` or anything else that rewrites or deletes data on a meeting whose
`status` is `recording` or `processing`.
