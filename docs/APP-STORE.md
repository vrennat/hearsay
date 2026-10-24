# Mac App Store release

The second distribution channel, after Homebrew (docs/RELEASING.md). The App Store build is the sandboxed
flavour of the same bundle (`scripts/build-app.sh --mas`), and the spike that proved the process tap and
dictation work under the sandbox is recorded in docs/SPEC.md (Amendments, 2026-10-24).

## What the project already has

- `scripts/build-app.sh --mas`: App Sandbox entitlements, `HSDistribution=appStore`, privacy manifest
  (`Resources/PrivacyInfo.xcprivacy`: no tracking, no collected data), `ITSAppUsesNonExemptEncryption=false`
  (CryptoKit AES-GCM for data at rest is Apple's standard crypto, exempt from export documentation),
  category Productivity, and, when `HEARSAY_PROVISION_PROFILE` is set, the embedded profile plus the
  `application-identifier` and `team-identifier` entitlements.
- `scripts/package-mas.sh [--upload]`: signs with Apple Distribution, wraps the app in a signed `.pkg`
  with `productbuild`, and with `--upload` validates and uploads it through `altool` using the App Store
  Connect API key.

## One-time setup in Apple's portals (needs the account owner)

1. **Certificates** (developer.apple.com, Certificates, Identifiers & Profiles). Create and install in the
   login keychain:
   - *Apple Distribution* (signs the app)
   - *Mac Installer Distribution* (signs the `.pkg`; appears in the keychain as
     "3rd Party Mac Developer Installer")
   Xcode, Settings, Accounts, Manage Certificates can create both.
2. **App ID**: explicit, `com.tannervass.hearsay`, capabilities none beyond the defaults (the sandbox and
   audio input are entitlements, not App ID capabilities).
3. **Provisioning profile**: type *Mac App Store Connect*, for that App ID and the Apple Distribution
   certificate. Download it and point `HEARSAY_PROVISION_PROFILE` at it, for example
   `~/.appstoreconnect/Hearsay_Mac_App_Store.provisionprofile`.
4. **API key issuer id** (App Store Connect, Users and Access, Integrations, Team Keys). The key
   Put the key in `~/.appstoreconnect/private_keys/` and export `ASC_KEY_ID` and `ASC_ISSUER_ID`.
   The same key and issuer also create the notary profile for Homebrew releases (docs/RELEASING.md).
5. **App record** (App Store Connect, Apps, +): platform macOS, name `Hearsay Transcripts` (Apple rejects the bare name "Hearsay" as taken; record id 6826543397), primary language English,
   bundle id `com.tannervass.hearsay`, SKU `hearsay`. Certificates, the profile and the listing text can all be
   created through the App Store Connect API with the upload key (done 2026-10-24: certs Y3PH23KVQ2 and
   Q4A3R42332, profile `Hearsay Mac App Store` saved at `~/.appstoreconnect/profiles/Hearsay_MAS.provisionprofile`).

## Each submission

```sh
export HEARSAY_PROVISION_PROFILE=~/.appstoreconnect/Hearsay_Mac_App_Store.provisionprofile
export ASC_ISSUER_ID=<issuer uuid>
scripts/package-mas.sh --upload
```

Then in App Store Connect: pick the build, fill the version page (description from README.md, keywords,
support URL `https://tanner.place/hearsay`, privacy policy URL), answer App Privacy with "Data Not
Collected", upload screenshots (menu panel, a finished transcript, Settings → Storage; 1280×800 or larger),
and add review notes explaining that system audio comes from a Core Audio process tap and that the
consent reminder is deliberate.

## Known gaps before the first submission

- The store build records to the container (`~/Library/Containers/com.tannervass.hearsay/Data/Meetings`),
  which is hard to find. First launch should offer a folder picker and keep a security-scoped bookmark
  (the `files.user-selected.read-write` and `bookmarks.app-scope` entitlements are already present).
- The CLI cannot be installed to `PATH` by a sandboxed app; Settings → Agents shows the symlink command
  instead. Review may ask why the binary ships inside the bundle: it is the same process the app uses.
- Review guideline 2.4.5 (sandbox) and 5.1.1 (data use): the usage strings in `build-app.sh` explain mic,
  system audio and calendar access; no login, no analytics.

## Submitting through the API (2026-10-24)

The whole listing except the App Privacy questionnaire can be driven with the App Store Connect API and the
upload key: version localization text, app info (subtitle, privacy URL, categories), age rating declaration,
price schedule (free) and availability, screenshots (1280×800 is the smallest accepted Mac size), build
attach, `contentRightsDeclaration` on the app, `appStoreReviewDetails` (contact name, phone and email are
required), then a `reviewSubmissions` record with one `reviewSubmissionItems` entry and `submitted: true`.
App Privacy ("Data Not Collected") must be published by hand in the web UI first, or the submission item
is refused. Screenshots on a 1x display capture at 1x; capture windows by id (`screencapture -l`) and
composite onto the wallpaper window (owner WindowManager, name "Wallpaper") rather than cropping the screen.

## Build numbers

`CFBundleVersion` is the commit count, so a squashed history builds as 1. App Store Connect never accepts the same build number twice for a version, so a store re-upload sets `HEARSAY_BUILD_NUMBER` above the last uploaded build (0.1.0 went to the store as build 2 after build 1 was replaced). The Developer ID build keeps the commit count.
