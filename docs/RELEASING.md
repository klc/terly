# Terly yayın rehberi

Bu rehber imzalı, notarize edilmiş bir Terly sürümünü GitHub Release ve Sparkle
update channel üzerinden yayınlamak için gereken source of truth'tur.

## GitHub secrets

Repository Settings → Secrets and variables → Actions altında şunlar bulunmalı:

- `MACOS_CERTIFICATE_P12`: Developer ID Application `.p12` dosyasının base64 içeriği.
- `MACOS_CERTIFICATE_PASSWORD`: `.p12` parolası.
- `NOTARY_TEAM_ID`: Apple Developer Team ID.
- `NOTARY_KEY_P8`: App Store Connect API `.p8` anahtarının base64 içeriği.
- `NOTARY_KEY_ID`: App Store Connect API Key ID.
- `NOTARY_ISSUER_ID`: App Store Connect Issuer ID.
- `SPARKLE_ED_PRIVATE_KEY`: `generate_keys` çıktısındaki private EdDSA anahtarı.

`GITHUB_TOKEN` GitHub Actions tarafından otomatik sağlanır. Sertifika, notary
anahtarı ve Sparkle private key hiçbir zaman repoya eklenmemelidir.

## Yayın öncesi kontrol

1. `project.yml` içinde `MARKETING_VERSION` hedef sürümle eşleşmeli ve
   `CURRENT_PROJECT_VERSION` önceki kaynak build numarasından büyük olmalı.
2. `CHANGELOG.md` içinde tam `## X.Y.Z` başlığı bulunmalı. Workflow release
   notlarını bu başlıktan bir sonraki sürüm başlığına kadar alır.
3. Xcode projesini üret ve doğrula:

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

4. `git diff --check` temiz olmalı; `Package.resolved` beklenmedik bir lokal
   SwiftTerm pin değişikliği içermemeli.
5. Manuel smoke test: pane resize/swap/zoom, tab reorder/rename, Finder upload
   overwrite onayı, transfer cancel/retry ve uygulama restart sonrası workspace.

## Yayınlama

Hazır commit varsayılan branche alındıktan sonra annotated tag oluşturup gönder:

```sh
git tag -a v1.1.0 -m 'Terly 1.1.0'
git push origin v1.1.0
```

`.github/workflows/release.yml` tag'den sürümü, GitHub run number'dan build
numarasını alır; Xcode projesini yeniden üretir, Developer ID ile archive/export
eder, Apple notarization ve staple işlemlerini yapar, DMG/ZIP üretir. Ardından
Sparkle arşivini imzalayıp `gh-pages` üzerindeki `appcast.xml` dosyasını günceller
ve aynı dosyaları GitHub Release'e ekler.

## Yayın sonrası doğrulama

- GitHub Actions `Release` job'u tamamen yeşil olmalı.
- GitHub Release altında `Terly-X.Y.Z.dmg` ve `Terly-X.Y.Z.zip` bulunmalı.
- `https://klc.github.io/terly/appcast.xml` yeni sürümü ve doğru download URL'ini göstermeli.
- Temiz bir Mac'te DMG açılmalı; `spctl -a -vv /Applications/Terly.app` accepted
  ve source olarak `Notarized Developer ID` göstermeli.
- Eski Terly sürümünde Ayarlar → Güncellemeler → Güncellemeleri Denetle yeni
  sürümü bulmalı ve kurabilmeli.

Workflow başarısız olursa aynı tag'i değiştirip tekrar kullanma. Hata düzeltmesini
commit et, patch sürümünü artır (`v1.1.1` gibi) ve yeni tag yayınla.
