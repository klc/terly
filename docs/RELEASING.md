# Terly release guide

This guide is the single source of truth for publishing a signed and notarized Terly release via GitHub Releases and the Sparkle update channel.

## GitHub secrets

The following secrets must be configured under **Repository Settings → Secrets and variables → Actions**:

- `MACOS_CERTIFICATE_P12`: Base64 content of the Developer ID Application `.p12` file.
- `MACOS_CERTIFICATE_PASSWORD`: The `.p12` password.
- `NOTARY_TEAM_ID`: Apple Developer Team ID.
- `NOTARY_KEY_P8`: Base64 content of the App Store Connect API `.p8` key.
- `NOTARY_KEY_ID`: App Store Connect API Key ID.
- `NOTARY_ISSUER_ID`: App Store Connect Issuer ID.
- `SPARKLE_ED_PRIVATE_KEY`: The private EdDSA key output from `generate_keys`.

`GITHUB_TOKEN` is provided automatically by GitHub Actions. Certificates, notary keys, and the Sparkle private key must never be committed to the repository.

## Pre-release checklist

1. `MARKETING_VERSION` in `project.yml` must match the target release version, and `CURRENT_PROJECT_VERSION` must be greater than the previous source build number.
2. `CHANGELOG.md` must contain an exact `## X.Y.Z` heading. The workflow extracts release notes from this heading up to the next version heading.
3. Generate and verify the Xcode project:

   ```sh
   xcodegen generate
   swift test
   xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator \
     -configuration Debug test \
     -only-testing:SSHConfigCoreTests \
     -only-testing:SSHConfiguratorTests
   xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator \
     -configuration Release -destination 'generic/platform=macOS' \
     ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
   ```

4. `git diff --check` must be clean; `Package.resolved` should not contain unexpected local SwiftTerm pin changes.
5. Manual smoke test: pane resize/swap/zoom, tab reorder/rename, Finder upload overwrite confirmation, transfer cancel/retry, and workspace restoration after app restart.

## Publishing

Once the prepared commit is merged into the default branch, create and push an annotated tag:

```sh
git tag -a v1.2.0 -m 'Terly 1.2.0'
git push origin v1.2.0
```

`.github/workflows/release.yml` reads the release version from the tag and the build number from the GitHub run number. It regenerates the Xcode project, archives/exports using Developer ID, performs Apple notarization and stapling, and builds DMG/ZIP archives. Next, it signs the Sparkle archive, updates `appcast.xml` on `gh-pages`, and attaches all artifacts to the GitHub Release.

## Post-release verification

- The GitHub Actions `Release` job must be green (successful).
- `Terly-X.Y.Z.dmg` and `Terly-X.Y.Z.zip` must be present under the GitHub Release.
- `https://klc.github.io/terly/appcast.xml` must reflect the new version and point to the correct download URL.
- The DMG should open on a clean Mac; `spctl -a -vv /Applications/Terly.app` must show accepted with `Notarized Developer ID` as the source.
- Checking for updates in an older Terly release (**Settings → Updates → Check for Updates**) must discover and install the new version.

If the workflow fails, do not overwrite or reuse the same tag. Commit the fix, bump the patch version (e.g., `v1.1.2`), and publish a new tag.
