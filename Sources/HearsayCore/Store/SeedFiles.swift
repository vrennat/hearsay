enum SeedFiles {
    static let readingGuide = """
    # Meetings folder

    Written by Hearsay. One folder per meeting, named `yyyy-MM-dd HHmm <title>`; the folder name is the meeting id.

    ## Start here

    - `index.md`: every meeting, newest first (date, title, duration, speakers named, status).
    - `index.jsonl`: the same, one JSON object per line (id, title, startedAt, endedAt, status, speakers, named, path).

    ## In each meeting folder

    - `transcript.md`: the transcript to read. Front matter lists speakers with talk time, `named: true` when every
      main speaker has a name, and `cleaned_by:` when filler removal was applied. Turns read `[mm:ss] **Name:** text`.
    - `transcript.raw.md`: the verbatim transcript, before cleanup.
    - `meeting.json`: title, times, `status` (recording, recorded, processing, done, failed) and `error`.
      `error: "interrupted"` on a `done` meeting means the app stopped mid-recording; the transcript covers
      only what was captured.
    - `live.md`: the live transcript written during recording. Use it when `transcript.md` is missing.
    - `transcript.json`, `cleanup.json`, `live.json`: the data the Markdown is generated from. Do not edit the
      Markdown; it is regenerated.
    - `audio/`: the recording.

    ## Encrypted files

    A file ending in `.enc` is encrypted. Audio (`audio/*.enc`) uses a key in the login Keychain. When
    `.hearsay-vault.json` exists with `"enabled": true`, the transcripts (`transcript.*`, `cleanup.json`, `live.*`)
    are `.enc` too and the index holds titles and dates only: read them with `HEARSAY_PASSWORD=... hearsay export <id>`
    (writes plaintext copies to a folder), never by opening the `.enc` file. `hearsay lock` / `hearsay unlock`
    turn transcript encryption on and off.

    ## hearsay

    Every command takes `--root <folder>` (default `~/Meetings`). Bare `hearsay` lists them.

    - `hearsay speakers <id>`: speakers with labels, names and talk time.
    - `hearsay rename <id> <speaker> <name>`: name a speaker (empty name clears it).
    - `hearsay title <id> <title>`: retitle a meeting (the folder name stays).
    - `hearsay hints <id>`: name suggestions from how people address each other.
    - `hearsay process <id>`: rerun transcription, speakers and naming on a meeting.
    - `hearsay cleanup <id>`: rewrite the filler-free text (`cleanup.json`).
    - `hearsay compress <id>`: re-encode a meeting's audio to AAC.
    - `hearsay voices [ids] [--apply]`: backfill voice matches and names without reprocessing.
    - `hearsay retention --audio-days N --transcript-days N [--apply]`: list, then apply, the storage plan.
    - `hearsay reindex`: regenerate every Markdown file and the index.
    - `hearsay import <audio>`: transcribe an audio file into a new meeting.
    - `hearsay live-sim <mic.wav> [--second <system.wav>]`: run the live transcriber on files into a new folder.
    - `hearsay dictate <audio>`: run the dictation path on a file and print the text.

    `glossary.txt` holds spelling fixes applied to every transcript.

    """

    static let glossary = """
    # Hearsay glossary: spelling fixes applied after transcription.
    # One fix per line:   wrong => Right
    # Matches whole words, ignoring case; the replacement is written as typed.
    # Lines starting with # are comments.
    # Example:
    # hear say => Hearsay

    """
}
