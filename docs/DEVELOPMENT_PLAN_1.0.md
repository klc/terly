# Terly 1.0 Geliştirme Planı

Kaynak: `docs/PRODUCT_ROADMAP.md` + 2026-07-17 rakip analizi.
Kapsam: 1.0 blocker'ları (5) + güçlü adaylar (4) = 9 iş paketi (WP).
Yürütme modeli: her WP tek bir alt ajan oturumu; plan + review ana oturumda.

## Genel kurallar (her WP için geçerli)

1. Ürün ilkeleri (`PRODUCT_ROADMAP.md` §2) bağlayıcıdır:
   - Özel anahtar içeriği asla okunmaz/saklanmaz.
   - Parola ve token düz metin metadata'ya yazılmaz; **parola hiçbir yerde kalıcı saklanmaz**.
   - Host key değişikliği sessiz kabul edilmez.
   - Kullanıcı görmeden çoklu sunucuda komut çalıştırılmaz.
2. Process argümanları shell birleştirmesi yapılmadan iletilir; quoting gerekiyorsa
   mevcut `StartupShellQuoter` kullanılır.
3. Metadata dosyaları atomik yazılır, izin `0600` (dizin `0700`).
4. Yeni process işleri `SSHProcessClient` katmanını kullanır; ayrı `Process` yönetimi eklenmez.
5. Her WP sonunda: `xcodegen generate` sonrası build + `swift test` yeşil (mevcut 199 test kırılmaz),
   yeni davranışlar için birim testleri eklenir.
6. UI metinleri Türkçe, mevcut üslupla uyumlu.
7. README ilgili bölümü aynı WP içinde güncellenir.

## Sıra ve bağımlılıklar

```
WP1 (tutarsızlık) → bağımsız, İLK
WP2 (askpass/parola) → WP3 ve WP5'in ön koşulu
WP3 (anahtar sihirbazı) → WP2'den sonra
WP4 (temalar) → bağımsız
WP5 (SFTP dosya işlemleri) → WP2'den sonra (parolalı hostlarda da çalışsın)
WP6 (aktarım geçmişi + temizlik) → WP5'ten sonra (aynı dosyalar)
WP7 (otomatik reconnect) → bağımsız
WP8 (test altyapısı + CI) → WP1-7 bittikçe genişler, iskeleti erken kurulabilir
WP9 (imzalama + Sparkle + release) → SON; Mustafa'nın sağlayacağı sertifika/anahtarlar gerekir
```

---

## WP1 — Doküman/davranış tutarsızlıklarını kapat

**Sorun:** e4a0a45 write-through kaydı getirdi ama README.md:39 hâlâ "yalnızca Kaydet
seçildiğinde yazar" diyor; roadmap ilke #6 da eski modeli anlatıyor. Ham config editörü ve
Değişiklikler önizlemesi UI'dan kalktı ama README.md:11 hâlâ var diyor; struct'lar ölü kod.

**Karar (uygulanacak):** write-through kalıcı davranıştır. Ham config editörü ve Değişiklikler
önizlemesi UI'ya **menü çubuğundan** geri döner (yeni toolbar ikonu YOK).

**Kapsam:**
- README güvenlik bölümü: write-through davranışını dürüst anlat (her düzenleme anında
  `~/.ssh/config`'e yazılır, yedek geçmişi güvence).
- `PRODUCT_ROADMAP.md` ilke #6'yı güncelle: "config yalnızca kullanıcının uygulama içindeki
  açık düzenleme eylemleri sonucunda değişir; her yazım öncesi yedek alınır."
- Menü çubuğuna (ör. `Dosya` veya `Görünüm` menüsü) iki komut: "Ham Config Editörü…" ve
  "Değişiklik Geçmişi/Önizleme…" — mevcut ölü struct'ları yeniden bağla. Ham editörde kayıt yine
  write-through + yedek üzerinden.
- Gerçekten kullanılamayan kalıntı prop/kod varsa temizle.

**Kabul:** README ile davranış birebir aynı; ham editör menüden açılıyor; build + testler yeşil.
**Boyut:** küçük (yarım gün).

---

## WP2 — Parola kimlik doğrulama: SSH_ASKPASS köprüsü

**Sorun:** SCP/SFTP/checksum `-B` / `BatchMode=yes` ile çalışıyor; agent'ta anahtar yoksa
aktarım anında başarısız. Parolalı sunucusu olan kullanıcı için uygulama fiilen kullanılamaz.
(Terminal SSH etkilenmiyor — gerçek PTY, parola istemi zaten görünüyor.)

**Tasarım:**
- App bundle içine küçük bir askpass yardımcı executable'ı eklenir
  (`Contents/MacOS/terly-askpass` ya da Resources altında; Info.plist'e gerek yok).
  Yardımcı, prompt metnini `argv[1]`'den alır, AppKit/`osascript` güvenli parola diyaloğu
  gösterir, girilen değeri stdout'a yazar. **Hiçbir yere kaydetmez, loglamaz.**
- `SSHProcessClient`'a opsiyonel "interactive auth" modu: environment'a
  `SSH_ASKPASS=<helper>`, `SSH_ASKPASS_REQUIRE=force`, `DISPLAY=:0` eklenir ve
  `BatchMode` verilmez.
- Prompt sınıflandırma: askpass'a gelen metin parola istemi olmayabilir (ör. host key
  onayı `yes/no`). Yardımcı, `yes/no` kalıbını ayrı bir ONAY diyaloğu olarak gösterir ve
  kullanıcının seçimini aynen döndürür — otomatik "yes" ASLA basılmaz (ilke #4).
- Kullanım yerleri: `SCPTransferPlanBuilder` (`-B` kaldır → interactive mod),
  `SFTPDirectoryListingService`, `SFTPFolderTransferRunner`, `ChecksumVerifier`.
- **Bilinçli DOKUNULMAYACAK yerler:** `RunbookExecutionEngine` ve
  `SSHConnectionDiagnostics` BatchMode kalır (runbook'ta askıda parola istemi ve çoklu host
  parola fırtınası istemiyoruz; tanılama zaten agent durumunu raporluyor). Bu tercih README'ye yazılır.
- Aynı kuyrukta birden fazla aktarım aynı hosta parola soruyorsa istemler seri gösterilir
  (eşzamanlı diyalog yağmuru yok) — kuyruk zaten eşzamanlılık limiti uyguluyor; diyalog
  gösterimi ana aktörde seri hale getirilir.
- İptal: kullanıcı diyaloğu kapatırsa yardımcı boş çıktı + sıfır olmayan exit döner; hata
  sınıflandırıcıda "kimlik doğrulama iptal edildi" kategorisi eklenir.

**Kabul:**
- Agent'sız, yalnız parolalı bir hosta SFTP listeleme ve SCP yükleme diyalogla çalışır.
- Parola hiçbir dosyaya/UserDefaults'a/loga yazılmaz (test: helper çıktısı yalnız stdout).
- Host key onayı ayrı onay diyaloğu; "hayır" seçilirse bağlantı kurulmaz.
- `SSHErrorClassifier` yeni kategorileri sınıflandırır; birim testleri var.
**Boyut:** büyük (1-2 gün). **Güvenlik açısından review zorunlu.**

---

## WP3 — Anahtar üretme ve sunucuya kopyalama sihirbazı

**Ön koşul:** WP2 (ilk kopyalama genelde parolayla yapılır).

**Kapsam:**
- Sidebar'a veya host ayarlarına "Anahtar Kurulumu…" eylemi. Üç adımlı sihirbaz:
  1. **Üret:** `/usr/bin/ssh-keygen -t ed25519 -f <seçilen yol> -C <yorum>` ayrı
     process argümanlarıyla. Passphrase alanı doğrudan ssh-keygen'in kendi istemine bırakılır
     (askpass üzerinden) — uygulama passphrase'i tutmaz. Var olan dosyanın üzerine yazma
     yalnız açık onayla.
  2. **Agent'a ekle (opsiyonel):** `ssh-add <path>` (yine askpass ile).
  3. **Sunucuya kopyala:** `ssh-copy-id -i <pub> -- <alias>` VEYA daha kontrollü:
     public key içeriği okunur (PUBLIC key okumak serbest; private ASLA) ve
     `ssh <alias> -- sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'`
     stdin'den beslenir. Komut önizlemesi kullanıcıya gösterilir (ilke #5 ruhu).
- Sihirbaz sonunda host'un `IdentityFile` alanını yeni anahtara güncellemeyi öner (onaylı).
- Tanılama merkezine "anahtar kurulumu öner" bağlantısı: agent'ta anahtar yok +
  permission denied kombinasyonunda sihirbaza yönlendir.

**Kabul:** anahtarsız hosta uçtan uca kurulum (üret → kopyala → parolasız bağlan) çalışır;
private key içeriği hiçbir kod yolunda okunmaz (test/inceleme ile doğrulanır); quoting
testleri (boşluklu yol, özel karakter) var.
**Boyut:** orta (1 gün).

---

## WP4 — Terminal renk temaları

**Kapsam:**
- `TerminalSettings`'e tema seçimi. SwiftTerm `TerminalView` ANSI renk paleti +
  arkaplan/önplan/cursor API'lerini kullan.
- Hazır temalar: Sistem (mevcut davranış), Solarized Dark/Light, Dracula, Nord,
  One Dark, Gruvbox Dark. Palet tanımları koda gömülü statik tablo (dosya formatı,
  import v.s. YOK — 1.0 sonrası).
- Ayarlar penceresindeki mevcut canlı önizleme temayı da gösterir.
- Tema değişikliği açık terminallere anında uygulanır (font değişimiyle aynı yol).
- Seçim `@AppStorage`/mevcut ayar kalıcılığıyla saklanır.

**Kabul:** tema değişimi açık oturumda anında görünür; app yeniden açılınca korunur;
`resolvedFont` cache'i bozulmaz; build + testler yeşil.
**Boyut:** küçük-orta (yarım-1 gün).

---

## WP5 — SFTP tarayıcıya dosya işlemleri

**Ön koşul:** WP2.

**Kapsam:**
- `RemoteFileBrowserView`'a sağ-tık menüsü + kısayollar: **Yeni Klasör**, **Yeniden Adlandır**,
  **Sil**.
- Uygulama: `SFTPDirectoryListingService` genişletilir; sftp batch komutları
  (`mkdir`, `rename`, `rm`, boş dizin için `rmdir`) `-b -` üzerinden beslenir. Yol quoting
  merkezi quoter ile; sftp'nin kendi quoting kuralları için birim testli bir escape katmanı.
- Silme her zaman onay diyaloğu ister; klasör silme yalnız boş klasörde (recursive silme
  1.0 dışı — tehlikeli, kapsam dışı yaz).
- İşlem sonrası dizin listesi tazelenir; hata sınıflandırıcı sftp hata çıktıları için genişler
  (permission denied, dosya mevcut, dizin boş değil).

**Kabul:** üç işlem parola ve anahtarlı hostlarda çalışır; boşluklu/özel karakterli adlar
testli; yanlışlıkla recursive silme mümkün değil.
**Boyut:** orta (1 gün).

---

## WP6 — Aktarım geçmişi + kısmi dosya temizliği

**Ön koşul:** WP5 (aynı dosyalar).

**Kapsam:**
- `TransferQueueEngine`: tamamlanan/başarısız/iptal edilen aktarımlar
  `~/Library/Application Support/Terly/transfer-history.json`'a atomik + `0600`
  yazılır (son 200 kayıt; alan: yön, yerel/uzak yol, boyut, süre, sonuç, zaman).
- Kuyruk görünümüne "Geçmiş" sekmesi/bölümü; kayıttan "yeniden aktar" eylemi.
- Ayarlarda "geçmişte yolları maskele" seçeneği (redaksiyon: `~/...` kısaltma + kullanıcı adı silme).
- İptal edilen aktarım için: hedefte kısmi dosya kalmış olabilir uyarısı + tek tık
  "kısmi dosyayı sil" (yalnız iptal edilen aktarımın kendi hedef yolu; boyut, aktarım
  bittiği andan küçükse). Uzak taraf için sftp `rm`, yerel için `FileManager`.
- Silme her zaman yol gösterilerek onaylatılır.

**Kabul:** geçmiş kalıcı, app restart sonrası duruyor; kısmi dosya silme yalnız ilgili
yolu hedefliyor (test); redaksiyon seçeneği çalışıyor.
**Boyut:** orta (1 gün).

---

## WP7 — Otomatik yeniden bağlanma

**Kapsam:**
- `TerminalWorkspaceModel.reconnectPane` temel alınır.
- Oturum beklenmedik kapandığında (kullanıcı kapatması DEĞİL — exit code / sinyal ayrımı)
  pane içinde durum şeridi: "Bağlantı koptu — Yeniden bağlan / Otomatik dene".
- Otomatik mod (host ayarında opt-in, varsayılan KAPALI): artan bekleme 2s → 4s → 8s →
  … maks 60s, maks 5 deneme; geri sayım görünür, her an iptal edilebilir.
- `NWPathMonitor` ile ağ dönüşü algılanır; otomatik mod kapalıysa yalnız öneri gösterilir,
  kendiliğinden bağlanılmaz (roadmap §8: kullanıcı onayı).
- Başlangıç akışı olan hostta: otomatik reconnect akışı yeniden çalıştırır mı? Host
  ayarındaki mevcut davranış tercihi kullanılır; aynı komutun iki kez koşması engellenir
  (akış yalnız yeni process'te bir kez).
- Senkron giriş: reconnect olan pane, akış bitene dek senkron gruptan düşer (mevcut
  startup-flow kilidi yeniden kullanılır).

**Kabul:** kopan oturum tek tıkla geri gelir; otomatik mod backoff'la çalışır ve iptal
edilebilir; kullanıcının kendi kapattığı sekme reconnect önermez; testler
(exit ayrımı, backoff zamanlayıcı) var.
**Boyut:** orta-büyük (1-1,5 gün).

---

## WP8 — Test altyapısı ve CI genişletme

**Kapsam:**
- Mevcut `.github/workflows` build işine `swift test` (SSHConfigCore + app testleri) eklenir;
  test sonuçları PR'da görünür.
- UI smoke: `XCUITest` ile tek senaryo — app açılır, sidebar görünür, ⌘K açılır/kapanır,
  Ayarlar penceresi açılır. (SSH bağlantısı GEREKTİRMEZ; CI'da koşabilir.)
- Sahte process çalıştırıcısıyla (`SSHProcessClient` test kancası) aktarım kuyruğu ve
  reconnect state-machine entegrasyon testleri.
- Büyük config perf testi: 1000 host'luk sentetik config parse + gruplama süresi eşiği
  (regresyon bekçisi, cömert eşik).
- Accessibility hızlı geçiş: ana görünümlerde etiket eksikleri (`accessibilityLabel`)
  taranıp kapatılır.

**Kabul:** CI'da build + tüm testler + UI smoke koşuyor; suite yeşil.
**Boyut:** orta (1 gün). WP1-7 ilerledikçe testler bu iskelete eklenir.

---

## WP9 — Sürümleme, imzalama, notarization, Sparkle (EN SON)

**Mustafa'nın sağlaması gerekenler (ajan yapamaz):**
- [ ] Apple Developer Program üyeliği + Developer ID Application sertifikası
- [ ] `notarytool` için App Store Connect API anahtarı veya app-specific password
- [ ] Sparkle EdDSA anahtar çifti (`generate_keys`; private key GitHub secret)
- [ ] Appcast barındırma kararı (öneri: GitHub Releases + `appcast.xml` GitHub Pages)

**Ajan kapsamı (anahtarlar placeholder'la):**
- `project.yml`: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, `ENABLE_HARDENED_RUNTIME: YES`,
  `CODE_SIGN_IDENTITY` ayarları; bundle ID sürüm öncesi Terly yeniden adlandırmasında
  `com.mkilic.Terly` yapıldı (ilk yayın öncesi olduğundan Keychain/UserDefaults bağı kırılmadı).
- Sparkle SPM paketi eklenir; `SUFeedURL`, `SUPublicEDKey` Info.plist anahtarları;
  Ayarlar'da "Güncellemeleri denetle" + otomatik denetim seçeneği. Sandbox YOK (uygulama
  zaten `~/.ssh`'a ve `Process`'e muhtaç) — Sparkle'ın sandboxsuz yolu kullanılır.
- Release workflow (`release.yml`, tag tetiklemeli): xcodegen → archive → codesign →
  notarize → staple → dmg/zip → Sparkle imza → GitHub Release + appcast güncelleme.
  Secret adları dokümante edilir.
- `CHANGELOG.md` başlatılır; release notu appcast'e akar.

**Kabul:** tag push → imzalı, notarize edilmiş, Sparkle ile güncellenebilir dmg üreten
workflow (secrets girilince) uçtan uca çalışır; yerel kurulumda "Güncellemeleri denetle"
appcast'i okur.
**Boyut:** büyük (1-2 gün + Apple onay süreçleri).

---

## Ajan yürütme notları (her WP prompt'una eklenecek)

- Repo: `~/Documents/ssh-configurator`, Swift 6, macOS 14+, XcodeGen (`project.yml` →
  `xcodegen generate`). Yeni dosyalar doğru target'a `project.yml` üzerinden girer.
- Bitiş tanımı: `xcodegen generate` + Xcode build BAŞARILI + `swift test` yeşil +
  README/dokümantasyon güncel + kısa değişiklik özeti raporu.
- Commit atma; diff'i ana oturum (Tarkan) review eder, commit mesajını o yazar.
- Kapsam dışına çıkma; WP'de "1.0 dışı" denen hiçbir şeyi ekleme.

---

## WP10 — Git tabanlı config senkronizasyonu (1.0 kapsamına sonradan eklendi, 2026-07-17)

**Fikir (Mustafa):** kullanıcının kendi private git reposu (ör. GitHub) sync backend'i olur;
uygulama değişiklikte commit'ler, yeni makinede/format sonrası clone edip geri yükler.
Aracı sunucu yok, history bedava. Termius'un bulut kasasına karşı ayırt edici özellik.

**Güvenlik/tasarım sınırları (bağlayıcı):**
- Uygulama git kimliği SAKLAMAZ: sistem git'i (`/usr/bin/git`) argv dizisiyle çağrılır,
  kullanıcının kendi SSH anahtarı/credential helper'ı kullanılır. Token/parola Keychain'e
  dahi yazılmaz.
- Repo çalışma dizini: `~/Library/Application Support/Terly/sync/` (0700).
  `~/.ssh/config` gerçeklik kaynağı kalır; export/import katmanı kopyalar. Symlink YOK
  (uygulama symlink config'e yazmayı zaten reddediyor — o ilke bozulmaz).
- Sync seti: `~/.ssh/config` + `~/.ssh` altındaki Include edilen dosyalar (dışındakiler
  uyarıyla atlanır), startup-flows.json, quick-access.json, auto-reconnect.json, tünel
  store, runbook store, snippet store (isSecret değerler HARİÇ — placeholder; restore'da
  "değer bu makinede yok" gösterilir).
- Dahil DEĞİL: private key içerikleri (asla), transfer-history.json ve workspace düzeni
  (makineye özgü), known_hosts (commit gürültüsü; v2 adayı), Backups dizini, Keychain.
- Kadans: write-through her düzenlemede push atmaz. Değişiklikte 30 sn debounce ile YEREL
  commit (mesaj: kısa Türkçe özet + zaman). Push varsayılan MANUEL ("Şimdi senkronize et");
  "otomatik push" opt-in. Pull: uygulama açılışında + manuel; yalnız fast-forward.
- Diverge/çakışma: satır merge YOK. Üçlü seçim UI: (a) yereli yedekle + uzaktakini al,
  (b) uzaktakini yerelle ez (force push değil — yeni commit), (c) iptal. Her uygulanan
  seçenekten önce mevcut yedek sistemi çalışır. Sessiz merge/üzerine yazma imkânsız.
- Restore (temiz kurulum): remote URL → clone → mevcut yerel durumla fark önizlemesi
  (ChangePreviewView deseni) → onay → önce yedek, sonra uygula → eksik IdentityFile
  listesi gösterilir (tanılama zaten algılıyor).
- UI: Ayarlar'a "Senkronizasyon" sekmesi (remote URL, durum: son sync/ahead/behind/hata,
  otomatik push toggle) + sidebar'da küçük sync durumu göstergesi.
- README/UI dürüstlüğü: "repo private olmalı", "git history kalıcıdır" açık uyarı;
  bootstrap paradoksu (yeni makinede GitHub erişimi için önce anahtar/HTTPS credential
  gerekir) dokümante edilir, WP3 sihirbazına yönlendirme yapılır.
- Testler: export/import round-trip, secret hariç tutma (snippet isSecret asla repoya
  düşmez — kanıt testi), çakışma karar yolları ve ff-only pull (sahte git çalıştırıcı),
  git argv inşası (shell birleştirme yok), Include çözümleme sınırları.

**Kabul:** iki makine simülasyonu (iki ayrı sync dizini) ile düzenle→commit→push→pull→
uygula döngüsü testlerde çalışır; secret sızıntısı yapısal olarak imkânsız; çakışmada
kullanıcı seçmeden hiçbir şey değişmez; agent'sız/anahtarsız ortamda anlaşılır hata.
**Boyut:** büyük (1,5-2 gün). **Güvenlik review zorunlu.**
