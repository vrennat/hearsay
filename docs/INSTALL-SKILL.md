# Installing the meeting-transcripts skill

Symlink it into Claude Code's skills folder so edits in the repo take effect:

```sh
mkdir -p ~/.claude/skills && ln -sfn "$PWD/claude/skills/meeting-transcripts" ~/.claude/skills/meeting-transcripts
```

Run it from the repository root. The skill needs the `hearsay` CLI on `PATH` (`~/.local/bin/hearsay` from
`scripts/build-app.sh`, or `/opt/homebrew/bin/hearsay` from the cask).
