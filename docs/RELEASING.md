# Releasing Hearsay (Developer ID / Homebrew)

Homebrew is the first distribution channel (docs/SPEC.md, Amendments). A release is a Developer ID signed,
notarized and stapled `Hearsay.app`, zipped, attached to a GitHub release on `vrennat/hearsay`, and installed by
the cask in `vrennat/homebrew-tap`.

## One-time setup

1. **Notary credentials.** Store them in the login keychain under the profile name `scripts/release.sh` uses:

   ```sh
   xcrun notarytool store-credentials hearsay-notary \
     --apple-id <your Apple ID> --team-id 4Q8P5YMHPK --password <app-specific password>
   ```

   The password is an app-specific password from account.apple.com (Sign-In and Security, App-Specific Passwords),
   not your Apple ID password. Alternatively use an App Store Connect API key (Users and Access, Integrations,
   Team Keys, role Developer):

   ```sh
   xcrun notarytool store-credentials hearsay-notary \
     --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <issuer UUID>
   ```

   Check it with `xcrun notarytool history --keychain-profile hearsay-notary`.

2. **GitHub CLI** logged in with push access to `vrennat/hearsay`: `gh auth status`.

3. **The tap repository.** Homebrew maps `vrennat/tap` to the GitHub repo `vrennat/homebrew-tap`:

   ```sh
   gh repo create vrennat/homebrew-tap --public --description "Homebrew tap for Hearsay"
   gh repo clone vrennat/homebrew-tap ~/Developer/homebrew-tap
   mkdir -p ~/Developer/homebrew-tap/Casks
   ```

   It must be public: `brew` fetches it without credentials.

## Each release

1. Bump `VERSION` and `HearsayCore.version` together, commit.
2. `scripts/release.sh <version>`. It refuses on a dirty tree or a `VERSION` mismatch, then: runs
   `scripts/build-app.sh` and takes the staged bundle `.build/app/Hearsay.app` (not `/Applications`), zips it with
   `ditto -c -k --keepParent`, notarizes (`notarytool submit --wait`), staples, re-zips the stapled app, computes
   the sha256, tags and pushes `v<version>`, creates the GitHub release with `Hearsay-<version>.zip`, and rewrites
   `version` and `sha256` in `Casks/hearsay.rb`.
3. Commit `Casks/hearsay.rb`, copy it to `~/Developer/homebrew-tap/Casks/hearsay.rb`, commit and push the tap.
4. Check: `brew update && brew upgrade --cask hearsay` (or a fresh install, below).

The cask links `Hearsay.app/Contents/MacOS/hearsay-cli`, so the bundle must contain the CLI; the script fails
before notarizing if it does not.

## What `brew install --cask vrennat/tap/hearsay` does

- Taps `vrennat/homebrew-tap` (clones it under Homebrew's Taps folder) if it is not tapped yet.
- Downloads `Hearsay-<version>.zip` from the GitHub release and checks its sha256 against the cask.
- Refuses on macOS older than 27 (`:golden_gate` in Homebrew) and on Intel Macs (`depends_on arch: :arm64`).
- Moves `Hearsay.app` into `/Applications` and symlinks `hearsay` in Homebrew's bin (`/opt/homebrew/bin/hearsay`)
  to `Hearsay.app/Contents/MacOS/hearsay-cli`.
- Gatekeeper accepts the app because it is notarized and stapled.

`brew uninstall --cask hearsay` removes the app and the symlink. `brew uninstall --zap --cask hearsay` also
removes the log, the preferences and the FluidAudio models. `~/Meetings` is never removed.

## Sparkle (self-update)

The Developer ID build updates itself with Sparkle 2. The feed is
`https://github.com/vrennat/hearsay/releases/latest/download/appcast.xml`; `scripts/release.sh` writes
`appcast.xml` (one item: the release being published), signs the zip with `sign_update`, and attaches
both files to the GitHub release. The App Store build compiles the updater out (`HEARSAY_NO_SPARKLE`) and
ships without the framework.

One-time setup on the release Mac (the private key never leaves its login Keychain):

    swift package resolve
    .build/artifacts/sparkle/Sparkle/bin/generate_keys            # creates the key, prints the public key
    .build/artifacts/sparkle/Sparkle/bin/generate_keys -p > Resources/sparkle-public-key.txt
    git add Resources/sparkle-public-key.txt && git commit -m "chore: Sparkle public key"

Back the private key up (`generate_keys -x sparkle-private-key.txt`, then store that file in a password
manager and delete it). **Losing it means no installed copy can be updated again**: every user would have
to reinstall by hand. `release.sh` refuses to run without `Resources/sparkle-public-key.txt`. The cask
says `auto_updates true`, so `brew upgrade` leaves updating to the app.


## Live speaker assignment (0.1.7)

Unmatched live words and equal-overlap ambiguities are shown as Speaker uncertain, never Remote 1.
Nearby speech without temporal overlap is no longer used as evidence of a speaker. Uncertain groups
cannot be named or supply names to the final transcript. Detected groups remain provisional; naming
one does not train the diarizer or split merged voices. Final offline diarization remains independent.
Content-free `live-assignment` log counters every 30 seconds report words, matched/uncertain words,
segment slots, matched slots and segment count. Many uncertain words point to timing/coverage;
one matched slot with one segment slot points toward model merging, not a participant count.
Synthetic four-voice/timing fixtures validate assignment, not acoustic model accuracy.

`release.sh` builds with `--no-install`: publishing never replaces or quits the installed app.
Set `HEARSAY_BUILD_ROOT` to an isolated scratch/staging directory and `HEARSAY_BUILD_JOBS=1`
for a bounded build. Large external writers must run under the host's required-volume supervisor.
