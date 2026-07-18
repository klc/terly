# Yayınlama (Release) Rehberi

Bu doküman WP9'un (bkz. `docs/DEVELOPMENT_PLAN_1.0.md`) ajan kapsamının nasıl
uygulandığını, `release.yml` iş akışının adımlarını, gereken GitHub secret'larını
ve Mustafa'nın tek seferlik yapması gereken işleri listeler.

## Genel akış

Bir `v*` etiketi (ör. `v1.0.0`) push edildiğinde `.github/workflows/release.yml`
şu sırayla çalışır:

1. `xcodegen generate` ile proje yeniden üretilir.
2. `MACOS_CERTIFICATE_P12` sertifikası geçici bir keychain'e import edilir.
3. `xcodebuild archive` — Release yapılandırması, `CODE_SIGN_IDENTITY="Developer ID Application"`,
   `DEVELOPMENT_TEAM=$NOTARY_TEAM_ID`; sürüm numarası tag'ten (`MARKETING_VERSION`)
   ve `github.run_number`'dan (`CURRENT_PROJECT_VERSION`) gelir — `project.yml`
   içindeki `1.0.0`/`1` yalnızca yerel geliştirme varsayılanıdır, release'de
   komut satırından override edilir.
4. `xcodebuild -exportArchive` — `developer-id` yöntemiyle imzalı `.app` çıkarılır.
5. `.app` zip'lenip `notarytool submit --wait` ile Apple'a gönderilir.
6. Onaylanınca `stapler staple` ile bilet `.app`'e yapıştırılır.
7. Stapled `.app`'ten hem dağıtım `.zip`'i hem de `.dmg`'si (varsa `create-dmg`,
   yoksa `hdiutil`) üretilir.
8. `gh-pages` branch'i bir git worktree olarak hazırlanır (yoksa orphan branch
   olarak oluşturulur); yeni `.zip` `updates/` altına kopyalanır.
9. Sparkle'ın `generate_appcast` aracı (aynı özel anahtarla hem imzalar hem
   `appcast.xml` + delta güncellemelerini üretir — manuel `sign_update` +
   elle XML yazmaktan daha güvenilir olduğu için tercih edildi) çalıştırılır;
   çıktı `gh-pages` köküne kopyalanıp push edilir.
10. `CHANGELOG.md`'deki ilgili `## <versiyon>` bölümü GitHub Release notu
    olarak kullanılır; `.dmg` ve `.zip` Release'e asset olarak yüklenir.

Secret'lardan biri eksikse ilgili adım `::error::` ile açıkça durur (sessizce
yarım bir sürüm üretmez).

## Gerekli GitHub secret'ları

| Secret | Amaç |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application sertifikası, base64 (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Yukarıdaki `.p12` dosyasının parolası |
| `NOTARY_APPLE_ID` | Notarization yetkisi olan Apple ID e-postası |
| `NOTARY_TEAM_ID` | Apple Developer Team ID (10 karakter); aynı zamanda codesign/export için `DEVELOPMENT_TEAM` olarak kullanılır |
| `NOTARY_PASSWORD` | `NOTARY_APPLE_ID` için app-specific password (App Store Connect API anahtarı değil — bkz. aşağıdaki not) |
| `SPARKLE_ED_PRIVATE_KEY` | `generate_keys` çıktısındaki base64 EdDSA private key |

`GITHUB_TOKEN` GitHub tarafından otomatik sağlanır (Release oluşturma ve
`gh-pages`'e push için `permissions: contents: write` yeterli); ayrıca bir
secret eklemeye gerek yok.

> **Not:** Apple artık notarization için App Store Connect API anahtarını da
> destekliyor; bu workflow bilinçli olarak daha basit olan app-specific
> password yolunu (`NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_PASSWORD`)
> kullanıyor. API anahtarına geçmek istenirse `notarytool submit` çağrısı
> `--key`/`--key-id`/`--issuer` parametreleriyle güncellenmeli.

## Mustafa'nın tek seferlik yapması gerekenler

- [ ] **Apple Developer Program üyeliği** + **Developer ID Application**
      sertifikası oluşturup `.p12` olarak dışa aktarmak (Keychain Access →
      sertifika + private key seçip "Export 2 items…").
- [ ] `.p12`'yi base64'e çevirip `MACOS_CERTIFICATE_P12`, parolasını
      `MACOS_CERTIFICATE_PASSWORD` olarak repo secret'larına eklemek.
- [ ] Notarization için bir **app-specific password** üretmek
      (appleid.apple.com → Güvenlik → Uygulamaya özel parolalar) ve
      `NOTARY_APPLE_ID` / `NOTARY_TEAM_ID` / `NOTARY_PASSWORD` secret'larını
      eklemek.
- [ ] Sparkle deposundan (`Sparkle-2.9.4.tar.xz` içindeki `bin/generate_keys`)
      `./bin/generate_keys` çalıştırıp **EdDSA anahtar çifti** üretmek:
      - Public key: `project.yml` içindeki `SUPublicEDKey: REPLACE_WITH_SPARKLE_PUBLIC_KEY`
        placeholder'ının yerine gerçek public key'i yazmak (sonra
        `xcodegen generate` ile projeye yansıtmak).
      - Private key: `SPARKLE_ED_PRIVATE_KEY` repo secret'ı olarak eklemek.
      - **Private key'i kaybetmeyin** — kaybolursa mevcut kullanıcılara
        güncelleme imzalayacak başka yol kalmaz (key rotation dışında).
- [ ] **Appcast barındırma**: bu workflow varsayılan olarak GitHub Pages
      (`gh-pages` branch) + GitHub Releases kombinasyonunu kullanır ve
      `SUFeedURL`'i `https://klc.github.io/terly/appcast.xml`
      olarak varsayar (`project.yml`). Repo ayarlarından **Settings → Pages**
      kısmında `gh-pages` branch'ini "Pages kaynağı" olarak seçmek gerekir
      (branch ilk release'de workflow tarafından otomatik oluşturulur, ama
      Pages'in bunu yayınlaması için manuel bir kere etkinleştirme lazım).
      Farklı bir barındırma tercih edilirse `project.yml`'deki `SUFeedURL` ve
      `release.yml`'deki `--download-url-prefix` / gh-pages adımları
      güncellenmelidir.

## Yerel geliştirme etkilenmez

- `xcodegen generate` + `xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator build`
  hâlâ ad-hoc (`CODE_SIGN_IDENTITY="-"`, `CODE_SIGN_STYLE=Manual`,
  `DEVELOPMENT_TEAM=""`) imzayla, secret'sız çalışır.
- `swift test` ve `xcodebuild test` (CI'daki `ci.yml`) değişmedi; Sparkle SPM
  paketi hem `project.yml` hem `Package.swift` tarafında tanımlı olduğundan
  her iki yol da derlenir (bkz. karar notu aşağıda).
- Ayarlar penceresindeki **Güncellemeler** sekmesi placeholder public key
  algıladığında ("REPLACE_WITH_SPARKLE_PUBLIC_KEY") gerçek Sparkle denetimini
  tetiklemez, yalnızca "Güncelleme kanalı henüz yapılandırılmadı." uyarısını
  gösterir — bu placeholder anahtarlarla beklenen, güvenli davranıştır.

## Karar notu: Sparkle hem `project.yml` hem `Package.swift`'te

Sparkle'ın SPM paketi kaynak kodu değil, önceden derlenmiş bir
`.xcframework` (`binaryTarget`) indiriyor; bu yüzden hem `xcodebuild`
(xcodeproj) hem `swift build`/`swift test` (SwiftPM) tarafında sorunsuz
derlendi/test edildi (346 test yeşil kaldı) — ayrı bir hariç tutma/koşullu
derleme gerekmedi.
