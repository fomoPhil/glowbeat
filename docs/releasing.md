# Releasing Glowbeat

Glowbeat ships outside the Mac App Store as a signed, notarized .dmg on this repo's
GitHub Releases. Installed copies update themselves with Sparkle.

## One command

```
scripts/release.sh 1.0.1 2            # version, build number (build must go up every time)
scripts/release.sh 1.0.1 2 --publish   # also creates the GitHub release
```

Out: `dist/Glowbeat-<version>.dmg` and `dist/appcast.xml` (`dist/` is gitignored).
Commit the `project.yml` version bump the script makes.

## What the script does

1. Writes the version and build into `project.yml`, runs `xcodegen generate`.
2. Archives Release (hardened runtime) into `build/DerivedData-release`, never
   `build/DerivedData`, which is the Debug build Phil runs.
3. Exports with the Developer ID identity, then checks: `codesign --verify --deep
   --strict`, no `get-task-allow`, the audio-input entitlement, the audio and local
   network usage strings, the Sparkle keys and the version.
4. Notarizes the app (zip) and staples it, so a dragged-out copy opens offline.
5. Builds the drag-to-Applications dmg with `create-dmg` (background from
   `scripts/dmg/`, regenerate with `python3 scripts/dmg/make-background.py`). Finder
   briefly opens a window while it lays out the icons.
6. Signs, notarizes and staples the dmg, then runs `xcrun stapler validate`,
   `spctl -a -t open --context context:primary-signature` and `spctl --assess` on the
   app inside the mounted image.
7. Builds `appcast.xml` with Sparkle's `generate_appcast`, starting from the appcast on
   the latest published release so older versions stay in the feed.
8. With `--publish`: `gh release create v<version>` on `fomoPhil/glowbeat` with the dmg, a copy named `Glowbeat.dmg` (the website's Download button links to `releases/latest/download/Glowbeat.dmg`),
   and `appcast.xml` attached. Notes come from `docs/release-notes/<version>.md` if it
   exists, otherwise GitHub generates them.

## How updates find the new version

- `SUFeedURL` in `App/Info.plist` is
  `https://github.com/fomoPhil/glowbeat/releases/latest/download/appcast.xml`. GitHub
  resolves `latest` to the newest non-draft, non-prerelease release, so every release
  must carry its own `appcast.xml` and the repo must be public.
- Each item's download URL is
  `https://github.com/fomoPhil/glowbeat/releases/download/v<version>/Glowbeat-<version>.dmg`,
  so the tag must be exactly `v<version>`.
- Sparkle compares `CFBundleVersion` (the build number), so it must increase.

## Keys and accounts

| What | Where |
|------|-------|
| Developer ID Application: PHILIP JAMES WOOLLEY (AXW4GKUTKZ) | login keychain (Personal Team) |
| Notarization | `asc` CLI, profile `Samplomatic` (Personal Team API key in the keychain). The script switches to it and checks it in the same command as each submit. |
| Sparkle EdDSA private key | login keychain, item "Private key for signing Sparkle updates", account `glowbeat` |
| Sparkle EdDSA public key | `SUPublicEDKey` in `App/Info.plist` |

Back up the Sparkle private key: if it is lost, installed copies can never verify
another update. Export it with
`build/DerivedData-release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account glowbeat -x glowbeat-sparkle-key.txt`
and keep the file in a password manager, never in the repo.

## If something fails

- Package resolution hangs: it is waiting on a hidden keychain prompt. The script passes
  `-packageAuthorizationProvider netrc` to avoid it; do the same for any manual build.
- Notarization rejected: `asc notarization log --id <id>` (after
  `asc auth switch --name Samplomatic`) gives the reasons.
- "Not a valid ID" or no results from `asc`: another session switched the profile.
- `stapler validate` "request timed out" (Error 68): Apple's ticket service hiccuped. The
  script retries; if it still fails, run `xcrun stapler validate dist/Glowbeat-<version>.dmg`
  again a minute later.
- A keychain prompt for `generate_appcast`: the script avoids it by having
  `generate_keys` (which created the key) export it to a private temp file for the run.
