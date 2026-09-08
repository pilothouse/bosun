# In-app auto-update (Sparkle)

Bosun updates itself with [Sparkle 2](https://sparkle-project.org) against a **signed appcast** (issue
#57). This doc covers the one-time setup, how a release reaches users, and the Homebrew / App Store
interactions. It's the companion to `docs/signing.md` (Developer ID signing + notarization).

## How it fits together

- The app embeds `Sparkle.framework` (added in `Package.swift`; copied into `Bosun.app/Contents/Frameworks`
  and signed inside-out by `scripts/package-app.sh`). All Sparkle code is confined to one file,
  `Sources/Bosun/UpdaterController.swift`.
- At launch the updater reads two Info.plist keys written by `package-app.sh`:
  - `SUFeedURL` = `https://github.com/pilothouse/bosun/releases/latest/download/appcast.xml`
    — `releases/latest/download/<asset>` always resolves to the newest **published** (non-draft,
    non-prerelease) release, so the feed needs no separate hosting.
    Note this value is burned into every shipped Info.plist and can never be changed for copies
    already installed, so it pins the app to this repo owner. A later rename or org move keeps
    working only for as long as GitHub's redirect does — settle the org before the first release.
  - `SUPublicEDKey` = the EdDSA **public** key. Sparkle refuses any update whose enclosure signature
    doesn't verify against it. (Not a secret — it's pinned in every shipped build.)
- "Check for Updates…" lives in the **Bosun** menu; "Automatically check for updates" lives in
  **Settings ▸ General** (bound to Sparkle's own `automaticallyChecksForUpdates`, persisted by Sparkle
  under `SUEnableAutomaticChecks` — deliberately *not* in the `bosun.preferences` blob).

## Release flow

1. Push a `v*` tag → `release.yml` builds the notarized `Bosun.dmg` and attaches it to a **draft** Release.
2. A maintainer reviews and **publishes** the Release.
3. Publishing fires `appcast.yml`, which: downloads the published `Bosun.dmg`, signs it with the EdDSA
   **private** key (`sign_update`), prepends a signed `<item>` to the cumulative `appcast.xml`
   (`scripts/update-appcast.py`), commits it, and uploads `appcast.xml` as a Release asset.
4. Installed copies fetch `…/releases/latest/download/appcast.xml`, verify the signature, and offer the
   update.

The draft→publish gate matters: the appcast is only updated on **publish**, so the feed never advertises a
build whose assets aren't live yet.

## One-time key setup (maintainer)

Generate the EdDSA key pair **once** (one key signs every app you ship; keep the private key safe):

```sh
# The CLI tools ship in the Sparkle release tarball, e.g.:
curl -fsSL -o sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-2.9.3.tar.xz
tar -xJf sparkle.tar.xz bin/generate_keys
./bin/generate_keys              # stores the private key in your login Keychain, prints SUPublicEDKey
./bin/generate_keys -x sparkle_private_key.pem   # export the private key (for the CI secret / backup)
```

Then:

- Put the printed public key in `scripts/package-app.sh` → `SU_PUBLIC_ED_KEY`.
- Add the exported private key (the file's contents) as the repo secret **`SPARKLE_ED_PRIVATE_KEY`**
  (Settings → Secrets and variables → Actions). `appcast.yml` is a **no-op** without it, so forks don't
  break.

To **rotate** keys, repeat and replace both the `SU_PUBLIC_ED_KEY` value and the secret. Older installs
pinned to the old public key won't accept updates signed by the new key until they update once manually.

> The committed default `SU_PUBLIC_ED_KEY` was generated during development; its private key lives in the
> developer's login Keychain (account `bosun`) and the gitignored `.build/sparkle-tools/`. Regenerate your
> own before the first public release if you don't hold that private key.

## Homebrew

Homebrew is the primary channel. The Cask (in its tap, not this repo) should declare:

```ruby
auto_updates true
```

This tells Homebrew the app updates itself, so `brew upgrade` won't fight Sparkle (it stops flagging the
app as outdated when Sparkle has already moved it ahead of the Cask's pinned version). Point the Cask's
`url` at the per-release DMG (`…/releases/download/#{version}/Bosun.dmg`); both channels serve the same
notarized artifact.

## Mac App Store (future)

Sparkle is **forbidden** in App Store builds (self-updating code violates the rules; the Store has its own
updater). The current build is future-proofed by *runtime isolation*:

- `UpdaterController` detects an App Store install (a `_MASReceipt` in the bundle) and **never creates the
  updater** — `Domain/UpdatePolicy.inAppUpdatesSupported(isAppStoreBuild:)`. The menu item and the Settings
  toggle then disappear (verified by dropping a fake `_MASReceipt` into the bundle).
- A real MAS target would additionally drop the Sparkle dependency. Because every Sparkle reference is
  behind `UpdaterController`, that's a localized change (e.g. gate the dependency in `Package.swift` on a
  build flag and stub `UpdaterController`), not a refactor — left for when a MAS build actually exists.

## Testing the update flow locally (no Developer ID needed)

The signed-appcast path is verifiable end-to-end without notarization:

```sh
swift build -c release --disable-sandbox --product Bosun
bash scripts/package-app.sh            # ad-hoc; embeds + signs Sparkle.framework

# Advertise a higher version from a local server, signed with your private key:
cp dist/Bosun.dmg /tmp/feed/Bosun-9.9.9.dmg
SIG=$(./bin/sign_update --ed-key-file sparkle_private_key.pem /tmp/feed/Bosun-9.9.9.dmg)
#   …write /tmp/feed/appcast.xml with a 9.9.9 <item> whose enclosure carries $SIG…
( cd /tmp/feed && python3 -m http.server 8765 & )
defaults write dev.anvas.bosun SUFeedURL http://localhost:8765/appcast.xml   # overrides Info.plist
open dist/Bosun.app                     # Bosun ▸ Check for Updates… → "Bosun 9.9.9 is now available"
defaults delete dev.anvas.bosun SUFeedURL                                    # restore the real feed
```

A mismatched signature makes Sparkle reject the update — that's the EdDSA check doing its job.

> Local limit: there's no Developer ID identity on the dev machine, so the **ad-hoc** convenience build
> drops the hardened runtime and entitlements to stay launchable (see the rationale in
> `scripts/package-app.sh` §5). The notarized Developer ID build keeps both; the framework and app share
> one Team ID, so hardened-runtime library validation passes with no extra entitlement. The CI release path
> exercises that branch.
