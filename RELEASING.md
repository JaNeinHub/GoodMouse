# Releasing GoodMouse

How a new version gets from this repository to a signed download on the [Releases page](https://github.com/JaNeinHub/GoodMouse/releases).

There are two roles:

- **Maintainer:** builds the app and publishes the release on GitHub.
- **Signer:** has a paid Apple Developer account and signs and notarizes the app, so it opens on any Mac without a Gatekeeper warning.

Everything works with the Xcode Command Line Tools alone (`xcode-select --install`). Neither role needs Xcode.

## Why signing matters

An unsigned or self-signed app downloaded from the internet is blocked on first launch. Users have to find "Open Anyway" in System Settings → Privacy & Security, and many give up there.

A **Developer ID** signature plus Apple's **notarization** removes that step. It also keeps the Accessibility permission across updates: macOS identifies the app by the signer's Team ID, so users grant access once, not after every update. **Always use the same signer (Team ID).** A different Team ID counts as a different app, and every user has to grant Accessibility again.

## One-time setup (signer)

1. **Apple Developer Program** membership (99 USD per year) at [developer.apple.com](https://developer.apple.com/programs/). Note the **Team ID** (Membership details, 10 characters, e.g. `AB12CD34EF`).
2. **Developer ID Application certificate.**
   - In Keychain Access: Certificate Assistant → Request a Certificate From a Certificate Authority → "Saved to disk".
   - On developer.apple.com: Certificates → "+" → **Developer ID Application** → upload the request → download the certificate → double-click it.
   - Check: `security find-identity -v -p codesigning` lists `Developer ID Application: <Name> (<TEAMID>)`.
   - Keep the private key on that Mac (and a backup). Never send it to anyone; the signer runs the script below instead.
3. **App-specific password** for notarization: [account.apple.com](https://account.apple.com) → Sign-In and Security → App-Specific Passwords. Then store it once in the keychain:

   ```sh
   xcrun notarytool store-credentials goodmouse-notary --apple-id <apple id> --team-id <TEAMID>
   ```

   It asks for the app-specific password. `goodmouse-notary` is the profile name used below.

## Each release

### 1. Maintainer: prepare and build
1. Set the new version in `VERSION` (e.g. `2.7`) and add an entry to `CHANGELOG.md`.
2. Commit and push.
3. Build: `./build-app.sh` → `dist/GoodMouse <version>/GoodMouse.app`.
4. Send the app to the signer as a zip that keeps the bundle intact:

   ```sh
   ditto -c -k --keepParent "dist/GoodMouse 2.7/GoodMouse.app" GoodMouse-2.7-unsigned.zip
   ```

   Alternatively the signer clones the repository at that commit and runs `./build-app.sh` themselves. That way they sign exactly what they built.

### 2. Signer: sign and notarize
Unzip (double-click), then:

```sh
./sign-and-notarize.sh "path/to/GoodMouse.app" "Developer ID Application: <Name> (<TEAMID>)" goodmouse-notary
```

The script:
1. signs with hardened runtime (GoodMouse needs no extra entitlements),
2. uploads to Apple and waits for notarization (usually 1–5 minutes),
3. staples the ticket to the app,
4. checks the result with Gatekeeper.

It ends with `Done: …/GoodMouse-<version>.zip`. Send that zip back.

If notarization fails, the script prints the submission ID. `xcrun notarytool log <id> --keychain-profile goodmouse-notary` shows why.

### 3. Maintainer: check and publish
1. Unzip the signed zip and check it:

   ```sh
   spctl --assess --type execute --verbose=2 GoodMouse.app
   ```

   The output must say `accepted` and `source=Notarized Developer ID`.
2. On GitHub: **Releases → Draft a new release**.
   - Tag: `v2.7` (created on publish). Title: `GoodMouse 2.7`.
   - Notes: copy the `CHANGELOG.md` entry.
   - Attach `GoodMouse-2.7.zip`, the signed zip, never the unsigned one.
   - **Publish release.**

The README's download link points to `releases/latest`, so it picks up the new version automatically.
