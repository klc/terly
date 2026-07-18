# Terly

macOS için yerel SwiftUI SSH çalışma alanı: `~/.ssh/config` yönetimi, gömülü terminal, dosya aktarımı, tünel ve runbook'lar. (Eski adı: SSH Configurator.)

## Özellikler

- Mevcut config içeriğini kayıpsız ayrıştırır; yorumlar ve bilinmeyen direktifler korunur.
- Host listesi ve form tabanlı `HostName`, `User`, `Port`, `IdentityFile` ve `ProxyJump` düzenleme.
- Host alias'larını `-` bileşenlerine göre çok seviyeli, açılır/kapanır gruplama (`ams-api-prod-1` → `ams → api → prod`).
- Global direktifler, `Match` blokları ve `Include` satırları için ayrı çalışma alanları.
- Tüm config için ham metin editörü ve diskteki dosya ile bellekteki çalışma kopyası arasındaki farkı gösteren önizleme (ör. bir yazma çakışması sonrası); ikisine de menü çubuğundan (**Dosya → Ham Config Editörü…** / **Dosya → Değişiklik Geçmişi/Önizleme…**) erişilir.
- Kaydedilmemiş değişiklikleri geri alma ve kaydetmeden önce çalışma kopyası modeli.
- Harici değişiklik algılama, yedek geçmişi/geri yükleme, atomik kaydetme ve `0600` dosya izni.
- Geçici config ile `ssh -G` doğrulaması. `Match exec` içeriyorsa yerel komut çalıştırma için açık onay ister.
- Bağlantı Tanılama ve Güven Merkezi; çözümlenmiş `ssh -G` ayarlarını kaynak satırlarıyla gösterir, DNS, ProxyJump, IdentityFile izinleri, SSH agent, `known_hosts` fingerprint'i ve uçtan uca bağlantıyı kontrol eder.
- Tanılama raporunu kullanıcı adı, yerel yol ve hassas komutları redakte ederek panoya kopyalar; tüm ağ adımları timeout ve iptal desteğine sahiptir.
- Seçilen somut Host alias'ını uygulama içindeki SwiftTerm terminalinde açar.
- Seçilen Host için SCP/SFTP ile dosya ve klasör yükleme/indirme; yerel dosya seçimi, uzak dizin tarayıcısı ve üzerine yazma onayı.
- Her bağlantıyı ayrı bir uygulama içi terminal sekmesinde doğrudan SSH süreci olarak çalıştırır.
- Sidebar'daki bağlantı satırı terminali doğrudan açar; satırdaki dişli bağlantı ayarlarını modal pencerede gösterir.
- İsimlendirilmiş bağlantı grupları oluşturur; grup ayarından bağlantıların ayrı terminal sekmelerinde veya tek sekme içindeki bölmelerde birlikte açılmasını seçtirir.
- Aktif terminal yatay veya dikey bölünebilir; yeni bölüm aynı SSH alias'ıyla ayrı bir bağlantı açar.
- Bölmeler `⌘` tuşu basılıyken tıklanarak senkron seçilebilir; klavye girdisi ve yapıştırılan komutlar seçili terminallere aynı anda gönderilir.
- Host ayarlarında bağlantıya özel Başlangıç Akışı oluşturur: `sudo -iu` ile kullanıcı değiştirme, uzak dizine geçme ve başarısızlık politikası olan shell komutu adımları eklenebilir, silinebilir ve sıralanabilir.
- Otomatik başlangıç bağlantıdan önce host bazında önizlenebilir, tek bağlantı veya grubun tamamı bir kereliğine atlanabilir ve açık terminalde manuel tekrar çalıştırılabilir.
- Grup bağlantılarında her host kendi profilini kullanır; başlangıçlar tamamlanana kadar senkron terminal girişi kapalı tutularak komutların yanlış bölmelere çoğaltılması engellenir.
- `⌘K` ile açılan hızlı erişim penceresinde alias, `HostName`, `User` veya bağlantı grubu adına göre fuzzy arama yapılır; sonuçtan bağlanma, ayar, dosya aktarımı ve tanılama eylemleri başlatılabilir.
- Favoriler ve son kullanılan bağlantılar hızlı erişimde öne çıkar; config uygulama içinden veya dışarıdan yenilendiğinde sonuç kataloğu da otomatik güncellenir.
- Tekil dosyaların yanı sıra klasör yükleme/indirme; aktarımlar eşzamanlılık sınırı olan bir kuyrukta yürütülür, başarısız aktarımlar otomatik olarak yeniden denenir.
- Local, Remote ve Dynamic Forward tipleriyle Tünel Yöneticisi; tüneller tek tek başlatılıp durdurulabilir ve bağlantıya bağlı olarak otomatik başlatılabilir.
- `⌘S` ile açılan snippet paletiyle sık kullanılan komut/metinler terminale hızlıca eklenir; snippet'ler ayrı bir bölümden yönetilir.
- Anahtar Kurulumu sihirbazı: bir host için ed25519 anahtar çifti üretir, isteğe bağlı olarak SSH agent'a ekler ve public key'i sunucudaki `authorized_keys` dosyasına kopyalar; sihirbaz host ayarları modalından ve sidebar sağ-tık menüsünden açılır.
- Ayarlar penceresindeki **Güncellemeler** sekmesinden Sparkle ile manuel veya otomatik güncelleme denetimi (bkz. Sürümleme ve güncellemeler).
- Ayarlar penceresindeki **Senkronizasyon** sekmesinden kullanıcının kendi private git reposuna config/tünel/snippet/runbook/başlangıç akışı senkronizasyonu; aracı sunucu yok, kimlik doğrulama tamamen sistem git'ine/SSH anahtarına bırakılır (bkz. Git ile senkronizasyon).

## Güvenlik

- Uygulama özel anahtar dosyalarının içeriğini asla okumaz.
- Yedekler `~/Library/Application Support/Terly/Backups` altında `0600` izinleriyle tutulur.
- Bir yedeği geri yüklerken mevcut config önce yeni bir yedek olarak saklanır.
- Sembolik link olan config dosyalarına doğrudan yazmayı reddeder.
- Uygulama write-through çalışır: ayrı bir **Kaydet** eylemi yoktur, her düzenleme eylemi (host ekleme/silme/kopyalama, alan düzenleme, ham config veya bölüm editörlerinden uygulama, Include ekleme/kaldırma) tamamlanır tamamlanmaz doğrudan `~/.ssh/config` dosyasına yazılır. Her yazımdan önce mevcut içerik otomatik olarak yedeklenir; bir yazım harici çakışma nedeniyle başarısız olursa değişiklik yalnızca bellekteki çalışma kopyasında kalır ve hata gösterilir.
- Terminal komutları shell metni birleştirilmeden ayrı process argümanlarıyla çalıştırılır.
- SCP/SFTP aktarımları ve checksum doğrulaması parola veya passphrase isteyebilen hostlarda `SSH_ASKPASS` köprüsü üzerinden çalışır: app bundle'ına gömülü `terly-askpass.sh` yardımcısı, ssh/scp/sftp'nin `argv[1]`'den ilettiği istemi sınıflandırır — parola/passphrase istemi için gizli girişli bir diyalog, sunucu kimliği (`yes/no`) onayı için ayrı bir onay diyaloğu gösterir ve kullanıcının seçimini birebir döndürür (otomatik "yes" hiçbir zaman basılmaz). Girilen değer yalnızca yardımcının stdout'una yazılır; argv'ye, environment'a, bir log dosyasına veya diske asla yazılmaz. Kullanıcı diyaloğu iptal ederse yardımcı boş çıktı ve sıfır olmayan bir çıkış koduyla döner. Aynı anda birden çok aktarım parola isteyebileceğinden yardımcı, dosya sistemi tabanlı basit bir kilitle (mkdir) seri çalışır: bir diyalog açıkken diğer bekleyen istemler sessizce sırada bekler, aynı anda birden fazla pencere açılmaz.
- Runbook çalıştırıcısı ve Bağlantı Tanılama merkezi bilinçli olarak `BatchMode=yes` ile çalışmaya devam eder: runbook'lar birden çok hostta aynı anda koşabildiği için parola istemi orada askıda kalan bir komut ya da eşzamanlı parola fırtınası anlamına gelir; tanılama zaten agent/anahtar durumunu ayrı ayrı raporladığı için parola istemine ihtiyaç duymaz.
- Tanılama host key kaydını otomatik değiştirmez veya kabul etmez; uçtan uca kontrol `StrictHostKeyChecking=yes` kullanır.
- SSH yardımcı süreçleri, SCP ve SFTP ortak timeout, iptal, çıktı toplama ve hata sınıflandırma katmanını kullanır.
- Başlangıç profilleri `~/Library/Application Support/Terly/startup-flows.json` dosyasında atomik JSON ve `0600` izinleriyle tutulur; `~/.ssh/config` içine yazılmaz.
- Başlangıç metadata'sı parola, token, sudo parolası veya özel anahtar içeriği için bir kasaya dönüşmez. Secret benzeri komutlarda arayüz uyarır; uygulama sudo parolasını yakalamaz ya da saklamaz.
- Uygulama içinden alias değiştirildiğinde profil UUID'si korunur. Config dışarıdan değişip alias kaybolursa profil yetim olarak gösterilir ve güncel bir alias ile yeniden eşleştirilebilir.
- Hızlı erişim favori/son kullanım metadata'sı `~/Library/Application Support/Terly/quick-access.json` dosyasında atomik olarak, dizin `0700` ve dosya `0600` izinleriyle saklanır; başlangıç akışı metadata'sından ayrıdır.
- Anahtar Kurulumu sihirbazı `ssh-copy-id` kullanmaz; sunucuya kopyalama adımında yalnızca `.pub` dosyası okunur ve stdin üzerinden `ssh`'e beslenir, özel anahtarın kendisi hiçbir kod yolunda açılmaz veya okunmaz. Üzerine yazma yalnızca açık kullanıcı onayıyla mümkündür.
- Git senkronizasyonu kendi git kimliği/credential'ını **saklamaz**: sistem git'i (`/usr/bin/git`) argv dizisiyle çağrılır (shell birleştirme yok), kimlik doğrulama tamamen kullanıcının kendi SSH anahtarı/credential helper'ına bırakılır. `GIT_TERMINAL_PROMPT=0` ile headless süreç parola isteminde asılı kalmaz, anlaşılır hatayla döner. Özel anahtarlar, `known_hosts`, transfer geçmişi, workspace düzeni ve secret snippet değerleri senkronizasyon setine hiçbir zaman girmez — snippet `isSecret` değeri zaten JSON'a hiç yazılmıyor (Keychain'de), bu nedenle sync katmanının ayrıca redakte etmesine gerek yok. Fast-forward olmayan pull hiçbir zaman otomatik merge etmez; uzaktan gelen değişiklikler önce yerel dosyalarla karşılaştırılır (diff önizleme), yalnızca açık onaydan sonra uygulanır ve öncesinde mevcut yerel durum otomatik yedeklenir. Çakışmada (diverged) satır-merge yoktur — kullanıcı üç seçimden birini yapar; "uzaktakini yerelle değiştir" seçeneği bile `git push --force` kullanmaz, yeni bir merge commit'i ile ilerler.

## Uygulama içi terminal

Terminal yüzeyi şu anda SwiftTerm kullanır. Terminal oturumu ve SSH süreç planı render motorundan ayrıldığı için ileride `libghostty` tabanlı bir motor aynı sözleşmeye eklenebilir.

`⌘,` ile açılan Ayarlar penceresinden yazı tipi, yazı boyutu ve bir renk teması seçilir (Sistem, Solarized Dark/Light, Dracula, Nord, One Dark, Gruvbox Dark); önizleme örnek metin ve 16 ANSI rengiyle canlı güncellenir. Tema değişikliği açık tüm terminal sekmelerine (gizli/arka plandaki sekmeler dahil) anında uygulanır ve bir sonraki açılışta korunur; tema dosyası içe/dışa aktarma bu sürümde yok.

Başlangıç akışı olmayan veya bir kez atlanan bağlantı doğrudan `/usr/bin/ssh -- <alias>` komutuyla açılır. Otomatik akış etkinse uygulama `-tt` ile tek bir uzak bootstrap komutu gönderir; adımları PTY'ye gecikmeli olarak yazmaz. Terminal sekmesini kapatmak ilgili SSH sürecini de kapatır; uygulama kapatıldığında bağlantılar arka planda devam etmez.

Bağlantı açmadan önce çalışma kopyasının kaydedilmiş olması gerekir; SSH her zaman diskteki `~/.ssh/config` dosyasını kullanır.

### Otomatik yeniden bağlanma

Bir terminal bölmesi beklenmedik biçimde koparsa (uzak taraf kapatırsa, ağ giderse veya uzak shell'e `exit` yazılırsa — bunların hepsi aynı şekilde ele alınır) terminal yüzeyinde bir durum bandı belirir: **"Bağlantı koptu"** başlığı, **Yeniden Bağlan** düğmesi ve **Bölmeyi Kapat** düğmesi. Sekmeyi/bölmeyi sen kendin kapatırsan bu bant hiç görünmez.

Bandın altındaki **"Bu sunucuda otomatik yeniden bağlan"** onay kutusu, bağlantının kurulu olduğu SSH alias'ı için host-başına bir ayardır ve varsayılan olarak **kapalıdır**; `~/Library/Application Support/Terly/auto-reconnect.json` dosyasında (atomik yazım, `0600`/dizin `0700`) saklanır. Açıkken beklenmedik her kopmada artan bekleme ile (2 sn → 4 sn → 8 sn → 16 sn → 32 sn, üst sınır 60 sn) en fazla 5 deneme otomatik olarak yeniden bağlanmayı dener; geri sayım bant üzerinde görünür ve **Vazgeç** ile her an iptal edilebilir. Yeniden bağlanan oturum 15 saniye ayakta kalırsa deneme sayacı sıfırlanır; 5 deneme de başarısız olursa otomatik mod o kopma için durur ve elle "Yeniden Bağlan" gerekir. Ağ bağlantısı geri geldiğinde otomatik modu açık bekleyen bir geri sayım hemen tetiklenir; otomatik modu kapalı bir bölmede ise yalnızca "Ağ geri geldi" önerisi gösterilir — uygulama kullanıcı onayı olmadan kendiliğinden bağlanmaz. Reconnect, mevcut manuel "Yeniden Bağlan" ile aynı başlangıç akışı davranışını kullanır. Uygulama kapatıldığında bekleyen tüm zamanlayıcılar iptal edilir; oturum geri yüklendiğinde eski bir geri sayım asla hortlamaz.

## Bağlantı Başlangıç Akışı

Bağlantı satırındaki dişliden Host ayarlarını açıp **Başlangıç Akışı** bölümünde adımları tanımlayabilirsin. Kullanıcı değiştirme adımı yalnızca ilk sırada ve bir kez kullanılabilir. Dizin ve kullanıcı alanları ayrı doğrulanır; boş veya desteklenmeyen bir sıra sessizce çalıştırılmaz. Dizinler merkezi shell quoting ile korunur, “Komut çalıştır” alanı ise bilerek uzak shell sözdizimi olarak değerlendirilir.

Builder tüm adımları aynı uzak shell bağlamında birleştirir ve sonunda `exec "${SHELL:-/bin/sh}" -l` ile terminali interaktif bırakır. `sudo` parola isterse istem normal terminalde görünür. Akışın çalışan adımı, tamamlanması veya çıkış koduyla başarısızlığı terminal başlığında gösterilir. Manuel tekrar eylemi yalnız aktif bölmeye gönderilir ve senkron giriş üzerinden çoğaltılmaz.

## Hızlı bağlantı bulucu

Uygulamanın herhangi bir yerinde `⌘K` ile hızlı erişimi açabilirsin. Yazmaya başladığında somut Host alias'ları `HostName` ve `User` alanlarıyla, bağlantı grupları ise adlarıyla aranır. `↑`/`↓` seçimi değiştirir, `Enter` varsayılan **Bağlan** eylemini çalıştırır, `Esc` pencereyi kapatır. Wildcard ve negatif Host pattern'leri doğrudan bağlantı sonucu olarak gösterilmez.

Yıldız düğmesi favoriyi değiştirir. Başarılı biçimde açılan tekil ve grup bağlantıları son kullanılanlara eklenir. Bir alias uygulama içinden yeniden adlandırıldığında hızlı erişim kimliği, favorisi ve geçmişi korunur; dışarıdan kaldırılan alias görünmez olur ve güvenli olmayan otomatik yeniden eşleştirme yapılmaz.

## Dosya aktarımı

Bir Host seçiliyken araç çubuğundaki **Dosya aktar** eylemiyle aktarım sayfasını açabilirsin. Yüklemede yerel dosya veya klasörleri Finder'dan, uzak hedef klasörünü uygulama içindeki SFTP tarayıcısından seçersin; dosya adı otomatik doldurulur ve değiştirilebilir. İndirmede uzak dosyayı tarayıcıdan seçtikten sonra standart macOS kayıt penceresi, dosya adını hazır getirir. Son kullanılan yerel ve uzak klasörler hatırlanır.

Aktarımlar bir kuyrukta yürütülür: birden fazla dosya/klasör aynı anda ayarlanabilir eşzamanlılık limitiyle (1-5) aktarılır, sırada bekleyenler ve aktif olanlar canlı yüzde/hız bilgisiyle görünür. Başarısız bir aktarım otomatik olarak birkaç kez yeniden denenir; kalıcı olarak başarısız olan veya iptal edilen aktarımlar kuyruktan elle de yeniden başlatılabilir. Klasör aktarımı SCP (`-r`) veya SFTP üzerinden yapılabilir; SFTP klasör aktarımı ayrı bir çalıştırıcı kullanır. Üzerine yazma onayı yalnızca hedefte aynı adlı dosya bulunduğunda gösterilir.

Bu sürüm parola saklama desteklemez: SSH agent veya anahtar yoksa aktarım sırasında `SSH_ASKPASS` köprüsü üzerinden bir parola diyaloğu açılır (bkz. Güvenlik bölümü); girilen parola hiçbir yerde kalıcı tutulmaz. Aktarım iptal edilirse yerelde veya uzakta kısmi dosya kalmış olabilir; ilgili yolu kontrol et.

Aktarım sayfasındaki **Geçmiş** sekmesi, tamamlanan, kalıcı olarak başarısız olan ve iptal edilen her aktarımı kaydeder (bekleyen/aktif aktarımlar geçmişe yazılmaz). Kayıtlar `~/Library/Application Support/Terly/transfer-history.json` dosyasında (atomik yazım, `0600`/dizin `0700`) en fazla son 200 kayıt olacak şekilde tutulur ve uygulama yeniden başlatıldığında kalıcıdır. Her kayıttaki **"Yeniden aktar"** aynı parametrelerle kuyruğa yeni bir iş ekler; yüklemenin yerel kaynak dosyası artık yoksa bu, kuyruğa hiç girmeden anında anlaşılır bir hata gösterir (indirmelerde kaynak uzak sunucuda olduğundan önceden doğrulanamaz, normal aktarım hata sınıflandırmasına bırakılır). **"Yolları maskele"** işaretliyse yalnızca bu listenin **görünümünde** ana dizin `~` ile kısaltılır ve kullanıcı adı bileşenleri `•••` ile gizlenir — dürüst olmak gerekirse bu salt görsel bir maskeleme: `transfer-history.json` içinde ham (maskesiz) yol saklanmaya devam eder, çünkü "Yeniden aktar" gerçek yola ihtiyaç duyar. **"Geçmişi Temizle"** onay istedikten sonra yalnızca kayıt listesini siler; aktarılan veya kısmi kalan dosyalara dokunmaz.

İptal edilen veya kalıcı olarak başarısız olan **tekil dosya** aktarımlarında geçmiş kaydında **"Kısmi dosyayı sil…"** eylemi belirir; bu yalnızca o aktarımın kendi hedef yolunu hedefler (indirmede yerel dosya `FileManager` ile, yüklemede uzak dosya WP5'teki sftp `rm` ile) ve silmeden önce tam yolu göstererek onay ister. Klasör aktarımlarında bu eylem hiç teklif edilmez — yalnızca elle temizlik gerektiğini belirten bir uyarı metni gösterilir (özyinelemeli silme riski nedeniyle).

Uzak klasör tarayıcısında (aktarım hedefi seçerken) sağ tık menüsünden veya satırdaki "…" düğmesinden **Yeniden Adlandır** ve **Sil** işlemleri yapılabilir; **Yeni Klasör** araç çubuğunda ayrı bir düğmedir. Silme her zaman dosya adı ve tam uzak yol gösteren bir onay ister. Klasör silme yalnızca **boş** klasörlerde çalışır (sftp `rmdir`); bu uygulama klasörleri özyinelemeli (recursive) silmez — boş olmayan bir klasörü silmeye çalışırsan "Klasör boş değil" hatası gösterilir. Seçili bir dosya varken Delete tuşu da silme onayını açar.

## Tünel Yöneticisi

Sidebar'daki **Tüneller** bölümünden Local (`-L`), Remote (`-R`) ve Dynamic (`-D`) forward tanımları oluşturabilirsin. Her tünel bir hedef Host alias'ına bağlanır ve tek tek başlatılıp durdurulabilir; "Otomatik Bağlan" işaretliyse tünel ilgili bağlantı açıldığında kendiliğinden kurulur. Varsayılan yerel bind adresi `127.0.0.1`'dir; `0.0.0.0` veya `::` gibi dışa açık bir adres seçilirse arayüz güvenlik uyarısı gösterir.

## Snippet'ler

Terminaldeyken `⌘S` ile sık kullanılan komut veya metin snippet'lerini arayıp seçili bölmeye ekleyebilirsin. Snippet'ler sidebar'daki **Snippet'ler** bölümünden key/value olarak eklenir, düzenlenir ve silinir.

## Anahtar Kurulumu

Bir host satırının sağ-tık menüsündeki veya host ayarları modalındaki **Anahtar Kurulumu…** eylemi, üç adımlı bir sihirbaz açar:

1. **Üret:** `/usr/bin/ssh-keygen -t ed25519 -f <yol> -C <yorum>` ayrı process argümanlarıyla çalıştırılır. Varsayılan yol `~/.ssh/id_ed25519_<alias>`dir (alias dosya adı için güvenli karakterlere indirgenir); yol ve yorum düzenlenebilir. Passphrase alanı tamamen ssh-keygen'in kendi istemine bırakılır ve `SSH_ASKPASS` köprüsü üzerinden diyalog olarak gösterilir — uygulama passphrase'i hiçbir zaman görmez veya saklamaz. Hedef yolda zaten bir dosya varsa yalnızca açık bir onay diyaloğundan sonra üzerine yazılır; onaysız üzerine yazma mümkün değildir.
2. **Agent'a ekle (opsiyonel):** işaretliyse `/usr/bin/ssh-add <özel anahtar yolu>` çalıştırılır; `ssh-add` anahtar dosyasını kendisi okur, uygulama içeriğe erişmez.
3. **Sunucuya kopyala:** `ssh-copy-id` KULLANILMAZ. Bunun yerine yalnızca `<yol>.pub` dosyası okunur (private key hiçbir kod yolunda okunmaz) ve içeriği `/usr/bin/ssh -- <alias> sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'` komutuna stdin üzerinden beslenir. Çalıştırılmadan önce hedef host, çalışacak uzak komut ve eklenecek public key metni önizleme olarak gösterilir.

Kopyalama başarılı olduktan sonra `ssh -o BatchMode=yes -- <alias> true` ile parolasız girişin çalıştığını doğrulayan bir kontrol otomatik çalışır ve sonucu gösterir. Sihirbaz sonunda host'un `IdentityFile` alanını yeni anahtara güncellemeyi önerir; bu güncelleme yalnızca kullanıcı onayıyla ve mevcut write-through düzenleme yolu üzerinden uygulanır. Bağlantı Tanılama merkezi, agent'ta kullanılabilir anahtar yok ve kimlik doğrulama reddedildi durumlarını birlikte tespit ettiğinde sihirbaza yönlendiren bir öneri gösterir.

## Git ile senkronizasyon

Ayarlar penceresindeki **Senkronizasyon** sekmesinden kendi private git reponu (ör. GitHub) sync backend'i olarak bağlayabilirsin. Aracı sunucu yok, geçmiş bedava: uygulama değişiklikte otomatik commit atar, sen istediğinde push edersin, yeni makinede/format sonrası aynı repoyu bağlayıp geri yüklersin.

**⚠️ Repo private olmalı.** Buraya senkronize edilen her şey (Host tanımları, tünel/snippet/runbook/başlangıç akışı metadata'sı) uzak repoya commit edilir ve **git geçmişi kalıcıdır** — bir dosyayı sonradan repodan "silmek" geçmişteki commit'lerdeki halini otomatik temizlemez (`git filter-repo`/`BFG` gibi araçlar gerekir). Public bir repoya bağlarsan bu bilgiler herkese açık kalır.

**Senkronize edilenler:** `~/.ssh/config` + içindeki `Include` edilen dosyalar (yalnızca `~/.ssh` altında kalanlar; dışına çıkan veya özel anahtar/`known_hosts` benzeri isimli olanlar sessizce atlanır, uyarı listesinde görünür), başlangıç akışları, hızlı erişim favorileri, otomatik yeniden bağlanma ayarları, tüneller, runbook'lar, snippet'ler (secret işaretli snippet **değerleri** hariç — zaten yalnızca Keychain'de tutulur, JSON'a hiç yazılmaz).

**Senkronize edilmeyenler:** özel anahtar içerikleri (asla okunmaz/kopyalanmaz), aktarım geçmişi ve terminal workspace düzeni (makineye özgü), `known_hosts` (sürekli değişir, commit gürültüsü olurdu), yerel yedekler (`Backups/`), Keychain.

**Kadans:** her düzenlemede anında push atılmaz — değişiklikten 30 saniye sonra (debounce) yerel bir commit atılır. Push varsayılan olarak **manuel** ("Şimdi senkronize et"); otomatik push ayrı bir anahtarla açılabilir. Pull uygulama açılışında ve manuel olarak, yalnızca **fast-forward** ile çalışır — hiçbir zaman otomatik merge etmez.

**Uzaktan gelen değişiklikler asla sessizce uygulanmaz:** pull yalnızca senkronizasyon deposunu günceller; ne değişeceği bir önizleme ekranında (mevcut/gelen içerik yan yana) gösterilir, sen onaylamadan gerçek dosyalara dokunulmaz. Onaydan önce mevcut yerel durum otomatik olarak yedeklenir. Önizlemede, gelen config'te bu makinede bulunmayan `IdentityFile` yolları varsa ayrıca listelenir (bu iyi niyetli, salt-metin bir kontrol — `ssh_config` token'ları içeren yollar atlanır; bağlantı anındaki tam çözümleme için Bağlantı Tanılama merkezine bak).

**Çakışma (diverged geçmiş):** satır bazlı otomatik merge yok. Üç seçenek sunulur: (a) yereli yedekle, uzaktakini al, (b) uzaktakini yerelimle değiştir — bu seçenek bile `git push --force` **kullanmaz**, yerel içeriği koruyan yeni bir merge commit'iyle ilerler, (c) iptal. Hangisi seçilirse seçilsin, uygulanmadan önce mevcut yerel durum yedeklenir.

**Bootstrap paradoksu:** yeni bir makinede bu özelliği kullanabilmek için önce GitHub'a (veya remote'a) erişim gerekir — yani bir SSH anahtarı (agent'a eklenmiş) veya HTTPS credential helper'ı zaten kurulu olmalı. Bu, senkronizasyonun kendisiyle çözülemez: **Anahtar Kurulumu** sihirbazını (bkz. yukarıda) kullanarak önce bir anahtar üret/ekle, GitHub hesabına public key'i tanıt, sonra Senkronizasyon sekmesinden remote URL'i bağla.

## Sürümleme ve güncellemeler

Uygulama sürümü `project.yml`'de `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
olarak tutulur; yerel geliştirme derlemesi her zaman ad-hoc (`CODE_SIGN_IDENTITY="-"`)
imzalı kalır, gerçek Developer ID imzası yalnızca `.github/workflows/release.yml`
içinde bir `v*` etiketi push edildiğinde CI'da uygulanır.

Güncellemeler [Sparkle](https://github.com/sparkle-project/Sparkle) ile dağıtılır;
Ayarlar penceresindeki **Güncellemeler** sekmesinden manuel denetim ve otomatik
denetim aç/kapa yapılabilir. `project.yml` içindeki `SUFeedURL` ve `SUPublicEDKey`
şu an **placeholder** değerler — appcast adresi gerçek yayın altyapısına göre
(`https://klc.github.io/terly/appcast.xml`) ve public key
`generate_keys` çıktısına göre değiştirilmesi gereken yerlerdir. Placeholder
public key'i algılayan bir guard, gerçek anahtar girilene kadar denetim
düğmesini "Güncelleme kanalı henüz yapılandırılmadı." uyarısıyla durdurur.

Uçtan uca release süreci, gereken GitHub secret'ları ve Mustafa'nın tek seferlik
yapması gerekenler için bkz. **`docs/RELEASING.md`**.

## Geliştirme

```sh
xcodegen generate
open SSHConfigurator.xcodeproj
swift test
```

`xcodegen generate` komutu, kaynakta tutulan `project.yml` dosyasından Xcode projesini yeniden oluşturur.

## Test ve CI

- Birim testleri iki şekilde çalıştırılabilir: `swift test` (SwiftPM, hızlı) veya
  `xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator test -only-testing:SSHConfigCoreTests -only-testing:SSHConfiguratorTests`
  (Xcode toolchain, `SSHConfiguratorTests`'in `TEST_HOST` ile gerçek `Terly.app`
  içinde koşmasını da kapsar). Her iki test target'ı da `GENERATE_INFOPLIST_FILE: YES`
  kullanır — bu olmadan `xcodebuild test` codesign aşamasında test bundle'ını
  imzalayamadığı için düşer (`swift test` bundle'sız çalıştığından etkilenmez).
- UI smoke testi (`SSHConfiguratorUITests`, `XCUITest`) tek bir senaryoyu kapsar: uygulama
  açılır → sidebar görünür → `⌘K` hızlı erişimi açar/`Esc` kapatır → `⌘,` Ayarlar
  penceresini açar/kapatır. SSH bağlantısı gerektirmez ve yalnızca salt-okunur
  eylemler içerir; kullanıcının gerçek `~/.ssh/config` dosyasına yazmaz. Lokalde:
  `xcodebuild -project SSHConfigurator.xcodeproj -scheme SSHConfigurator -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES test -only-testing:SSHConfiguratorUITests`.
  UI testleri (birim testlerin aksine) `testmanagerd`'in bağlanabilmesi için gerçek
  (ad-hoc olsa da) bir codesign imzası **ve** makinede açık "Developer Mode"
  gerektirir; ikisi de yoksa test çalıştırıcısı "Test crashed with signal kill
  before establishing connection" hatasıyla hemen sonlanır. Developer Mode'u
  bir kere açmak için: `sudo /usr/sbin/DevToolsSecurity -enable`.
- CI (`.github/workflows/ci.yml`) iki job çalıştırır: `build-and-test` (build +
  `swift test` + yukarıdaki `xcodebuild test`) ve ayrı bir `ui-smoke` job'u
  (Developer Mode'u etkinleştirip ad-hoc imzayla UI smoke testini koşar).
- Sahte bir `SSHProcessExecuting`/`ReconnectScheduling` üzerinden aktarım kuyruğu
  (`TransferQueueEngineIntegrationTests`) ve otomatik yeniden bağlanma zinciri
  (`AutoReconnectChainIntegrationTests`) uçtan uca test edilir: gerçek `scp`/`ssh`
  süreci hiç başlatılmadan kuyruğa ekleme → sahte başarı/başarısızlık → durum +
  geçmiş kaydı, ve kopma → backoff → sahte başarı → sayaç sıfırlama yolları.
- `SSHConfigDocumentPerformanceTests` 1000 host'luk sentetik bir config'i parse edip
  gruplar; eşik (5s) CI runner yavaşlığına karşı bilinçli olarak cömerttir (yerelde
  çalışma süresi ~25ms) — amaç mikro-performans izlemek değil, olası bir O(n²)
  regresyonunu yakalamaktır.
