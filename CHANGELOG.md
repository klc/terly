# Changelog

Bu dosya Terly'nin sürüm geçmişini özetler. Biçim gevşek biçimde
[Keep a Changelog](https://keepachangelog.com/) esinlidir; sürüm başlıkları
`release.yml` tarafından GitHub Release notlarına ve Sparkle appcast'ine
otomatik olarak aktarılır (bkz. `docs/RELEASING.md`).

## 1.0.0

İlk sürüm. `~/.ssh/config` yönetimi, gömülü terminal, dosya aktarımı, tünel
ve runbook'ları bir araya getiren yerel SwiftUI SSH çalışma alanı.

### Config yönetimi
- Config'i kayıpsız ayrıştırır; yorumlar ve bilinmeyen direktifler korunur.
- Host, `Match` bloğu ve global direktifler için form tabanlı düzenleme;
  host alias'ları çok seviyeli gruplanır.
- Write-through kaydetme: her düzenleme anında yedeklenip diske yazılır; ham
  config editörü ve değişiklik geçmişi/önizlemesi menü çubuğundan açılır.
- Harici değişiklik algılama, yedek geçmişi/geri yükleme, atomik yazım ve
  `0600` dosya izinleri.
- `ssh -G` ile geçici doğrulama; `Match exec` için açık onay.

### Bağlantı tanılama ve güven merkezi
- Çözümlenmiş `ssh -G` ayarları, DNS, ProxyJump, IdentityFile izinleri, SSH
  agent ve `known_hosts` fingerprint kontrolü; uçtan uca bağlantı testi.
- Redakte edilmiş tanılama raporunu panoya kopyalama; tüm ağ adımlarında
  timeout ve iptal desteği.

### Terminal
- Uygulama içi SwiftTerm tabanlı terminal; her bağlantı ayrı sekmede kendi
  SSH sürecinde çalışır.
- Yatay/dikey bölünebilen paneller; `⌘` ile senkron seçim ve girdi paylaşımı.
- Yazı tipi/boyut ve renk teması ayarları (Sistem, Solarized Dark/Light,
  Dracula, Nord, One Dark, Gruvbox Dark) canlı önizlemeyle.
- Terminal içi arama (`⌘F`).
- Beklenmedik kopmalarda durum şeridi, tek tık yeniden bağlanma ve artan
  bekleme ile opt-in otomatik yeniden bağlanma; ağ dönüşü algılama.

### Bağlantı grupları ve hızlı erişim
- İsimlendirilmiş bağlantı grupları; ayrı sekme veya tek sekmede bölme
  olarak birlikte açma.
- `⌘K` hızlı erişim: alias/`HostName`/`User`/grup adına göre fuzzy arama,
  favoriler ve son kullanılanlar.

### Başlangıç akışı ve anahtar kurulumu
- Host bazında başlangıç akışı: kullanıcı değiştirme, dizine geçme, shell
  komutu adımları; önizleme ve tek seferlik atlama.
- Anahtar Kurulumu sihirbazı: `ssh-keygen` ile ed25519 anahtar üretimi,
  isteğe bağlı agent'a ekleme, `authorized_keys`'e güvenli kopyalama
  (`ssh-copy-id` kullanılmaz); private key hiçbir kod yolunda okunmaz.
- `SSH_ASKPASS` köprüsü: parolalı/agent'sız hostlarda SCP/SFTP/checksum
  için gizli girişli parola diyaloğu ve ayrı host-key onay diyaloğu; parola
  hiçbir yerde kalıcı saklanmaz.

### Dosya aktarımı
- SCP/SFTP ile tekil dosya ve klasör yükleme/indirme; eşzamanlılık sınırlı
  kuyruk, otomatik yeniden deneme, üzerine yazma onayı.
- Uzak dizin tarayıcısında Yeni Klasör, Yeniden Adlandır, Sil (yalnız boş
  klasör; özyinelemeli silme yok).
- Kalıcı aktarım geçmişi (son 200 kayıt), yeniden aktarma, yol maskeleme ve
  iptal edilen aktarımlar için kısmi dosya temizliği.
- Opsiyonel aktarım sonrası checksum doğrulaması.

### Tünel yöneticisi ve snippet'ler
- Local/Remote/Dynamic port forwarding; tek tek başlatma/durdurma ve
  bağlantıya bağlı otomatik başlatma.
- `⌘S` snippet paleti; secret değerler Keychain'de saklanır.

### Runbook'lar
- Onaylı, çoklu host'ta güvenli komut çalıştırma (runbook'lar).

### Test ve CI
- `SSHConfigCore` ve uygulama için birim testleri (`swift test` ve
  `xcodebuild test`), XCUITest tabanlı UI smoke testi, sahte process
  çalıştırıcısıyla aktarım kuyruğu/reconnect entegrasyon testleri ve
  1000 host'luk config için performans regresyon testi.

### Sürümleme ve dağıtım
- `project.yml`'de sürüm bilgisi (`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`)
  ve Hardened Runtime; yerel geliştirme derlemesi ad-hoc imzalı kalır.
- Sparkle entegrasyonu: Ayarlar penceresinde "Güncellemeleri Denetle" ve
  otomatik denetim seçeneği (gerçek anahtarlar Mustafa'nın sağlamasına
  bağlıdır — bkz. `docs/RELEASING.md`).
- Tag tetiklemeli `release.yml`: imzalama, notarization, DMG/ZIP paketleme
  ve appcast yayınlama iş akışı (secret'lar girilince uçtan uca çalışır).
