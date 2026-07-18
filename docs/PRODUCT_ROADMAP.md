# Terly Ürün Yol Haritası

## 1. Amaç

Terly artık yalnızca `~/.ssh/config` dosyasını düzenleyen bir araç değildir. Mevcut özellikler uygulamayı aşağıdaki dört alanı bir araya getiren yerel bir macOS SSH çalışma alanına dönüştürmektedir:

- Güvenli ve kayıpsız SSH config yönetimi
- Uygulama içi, sekmeli ve bölünebilir terminal
- Bağlantı grupları ve senkron terminal kullanımı
- SCP/SFTP tabanlı dosya aktarımı ve uzak dosya tarama

Ürün yönü şu şekilde tanımlanmalıdır:

> SSH bağlantılarını yapılandırmak, doğrulamak, açmak, otomatik başlangıç akışlarıyla hazırlamak ve günlük operasyonları tek bir güvenli macOS uygulamasından yürütmek.

Bu yol haritasının amacı yeni özellikleri rastgele eklemek yerine aynı ürün kimliği altında önceliklendirmektir.

## 2. Ürün ilkeleri

Yeni geliştirmelerde aşağıdaki ilkeler korunmalıdır:

1. Özel anahtar içeriği hiçbir zaman okunmamalı veya saklanmamalıdır.
2. Parola ve token gibi sırlar düz metin komut metadata'sına yazılmamalıdır.
3. SSH agent ve anahtar tabanlı kimlik doğrulama birincil akış olarak kalmalıdır.
4. Host key değişiklikleri sessizce kabul edilmemeli veya silinmemelidir.
5. Kullanıcı görmeden birden fazla sunucuda komut çalıştırılmamalıdır.
6. `~/.ssh/config` yalnızca kullanıcının uygulama içindeki açık düzenleme eylemleri sonucunda değişmelidir; her yazım öncesi yedek alınır.
7. Terminal, SCP ve SFTP aynı bağlantı, timeout, iptal ve hata sınıflandırma altyapısını kullanmalıdır.
8. Uygulama metadata dosyaları atomik biçimde ve `0600` izniyle saklanmalıdır.

## 3. Öncelik özeti

| Öncelik | Özellik | Temel değer |
|---|---|---|
| P0 | Bağlantı Tanılama ve Güven Merkezi | Bağlantının neden çalışmadığını güvenli ve anlaşılır biçimde açıklar |
| P0 | Ortak SSH süreç altyapısı | Terminal, SCP, SFTP ve tanılama davranışını birleştirir |
| P1 | Bağlantı Başlangıç Akışı | Bağlantı açıldığında ön tanımlı adımları güvenli biçimde çalıştırır |
| P1 | Hızlı bağlantı bulucu | Çok sayıda bağlantı arasında hızlı geçiş sağlar |
| P1 | Yeniden bağlanma ve workspace saklama | Günlük terminal kullanımını kesintilere karşı dayanıklı hale getirir |
| P2 | Tunnel Manager | Local, remote ve dynamic forwarding yönetimi sağlar |
| P2 | Gelişmiş aktarım yöneticisi | Çoklu dosya, klasör, kuyruk ve yeniden deneme ekler |
| P2 | Güvenli runbook sistemi | Tek veya çoklu sunucuda kontrollü operasyon akışları sağlar |
| P3 | Gelişmiş config editörü | OpenSSH direktiflerini ham metne ihtiyaç duymadan yönetir |
| P3 | Ürünleştirme | İmzalama, güncelleme, CI ve UI testleriyle dağıtıma hazırlar |

## 4. P0 — Bağlantı Tanılama ve Güven Merkezi

### Hedef

Kullanıcıya yalnızca “bağlantı başarısız” mesajı vermek yerine problemin hangi katmanda olduğunu göstermek.

### Kapsam

- `ssh -G` ile çözümlenmiş gerçek bağlantı ayarlarını gösterme
- Ayarların hangi `Host`, `Match` veya `Include` kaynağından geldiğini gösterme
- Hostname/DNS çözümleme kontrolü
- Port erişim kontrolü ve timeout
- ProxyJump zincirini ve zincirdeki başarısız adımı gösterme
- IdentityFile varlık ve dosya izin kontrolü
- SSH agent içindeki anahtarların kullanılabilirliğini kontrol etme
- `known_hosts` kaydını ve sunucu fingerprint bilgisini gösterme
- Host key değişikliğinde açık güvenlik uyarısı gösterme
- SSH/SCP/SFTP hata çıktısını sınıflandırma:
  - DNS hatası
  - Bağlantı timeout'u
  - Connection refused
  - Host key uyuşmazlığı
  - SSH agent içinde uygun anahtar bulunmaması
  - Permission denied
  - ProxyJump problemi
- Hassas alanları temizlenmiş tanılama raporu kopyalama

### Kabul kriterleri

- Her somut bağlantı için “Bağlantıyı test et” eylemi bulunur.
- Tanılama sonucunda başarılı ve başarısız kontroller ayrı ayrı görünür.
- İşlem iptal edilebilir ve her ağ adımı timeout ile sınırlıdır.
- Uygulama host key'i kullanıcı onayı olmadan değiştirmez.
- Tanılama raporunda kullanıcı adı, yerel yol veya hassas komutlar için redaksiyon uygulanır.
- SSH, SCP ve SFTP'nin yaygın hata çıktıları otomatik testlerle sınıflandırılır.

## 5. P0 — Ortak SSH süreç altyapısı

Terminal, SCP, SFTP ve gelecek tanılama/tünel özellikleri doğrudan birbirinden bağımsız `Process` yönetmemelidir. Ortak bir süreç ve bağlantı katmanı oluşturulmalıdır.

Önerilen sorumluluklar:

- Process başlatma ve yaşam döngüsü
- Argümanların shell birleştirmesi yapılmadan iletilmesi
- Ortak environment oluşturma
- Timeout ve iptal
- Standart çıktı/hata toplama
- Yapılandırılmış hata sınıflandırma
- Host güveni ve BatchMode politikası
- Testlerde sahte process çalıştırıcısı kullanabilme

Örnek kavramsal bileşenler:

- `SSHProcessClient`
- `SSHConnectionDiagnostics`
- `SSHErrorClassifier`
- `SSHHostTrustService`
- `SSHAgentInspector`

Bu katman tamamlanmadan tanılama, tünel ve gelişmiş aktarım özellikleri ayrı ayrı process yönetimi eklememelidir.

## 6. P1 — Bağlantı Başlangıç Akışı

### Hedef

Bir SSH bağlantısı açıldığında, o bağlantıya özel hazırlanmış adımları çalıştırarak terminali kullanıcının ihtiyaç duyduğu kullanıcı, dizin ve ortamda hazır hale getirmek.

Örnek kullanıcı isteği:

1. `sudo` ile `xyz` kullanıcısına geç
2. `/home/xyz` dizinine geç
3. Gerekirse ortam dosyasını yükle
4. İnteraktif terminali kullanıcıya bırak

### Kullanıcı deneyimi

Host ayarlarına “Başlangıç Akışı” bölümü eklenmelidir.

İlk sürümde üç yapılandırılmış adım tipi yeterlidir:

1. **Kullanıcı değiştir**
   - Kullanıcı adı
   - Varsayılan davranış: `sudo -iu <kullanıcı>`
2. **Dizine geç**
   - Uzak dizin yolu
3. **Komut çalıştır**
   - Uzak shell komutu
   - Başarısız olursa durdur seçeneği

Arayüzde ayrıca şunlar bulunmalıdır:

- Adım ekleme, silme ve sürükleyerek sıralama
- “Bağlanınca otomatik çalıştır” seçeneği
- Bağlantı öncesinde çalışacak adımları gösterme
- “Bu bağlantıda bir kez atla” seçeneği
- Başlangıç akışını terminalden manuel tekrar çalıştırma
- Akışın çalışıyor, tamamlandı veya başarısız durumunu gösterme
- Başarısız adım ve hata mesajını açıkça gösterme

### Yürütme modeli

Komutlar terminale sabit gecikmelerle körlemesine yazılmamalıdır. Özellikle `sudo su xyz` yeni bir interaktif shell açtığı için sonraki komutun ne zaman gönderileceği güvenilir biçimde belirlenemez.

Mümkün olan adımlar tek bir uzak bootstrap akışına dönüştürülmelidir. Örneğin:

```sh
sudo -iu xyz -- sh -lc 'cd /home/xyz && exec "$SHELL" -l'
```

Uygulama bu komutu ham string birleştirmeyle üretmemeli; kullanıcı adı, dizin ve komut alanlarını ayrı doğrulayıp shell quoting işlemini merkezi ve test edilmiş bir builder üzerinden yapmalıdır.

İlk sürümde desteklenmeyen veya güvenilir biçimde derlenemeyen bir adım varsa uygulama bunu otomatik çalıştırmak yerine kullanıcıya açıkça bildirmelidir.

### Saklama modeli

Başlangıç akışları `~/.ssh/config` içine yazılmamalıdır. Uygulamaya ait metadata olarak aşağıdaki dizin altında saklanmalıdır:

```text
~/Library/Application Support/Terly/
```

Metadata gereksinimleri:

- Atomik JSON yazımı
- Dosya izni `0600`
- Her profil için sabit UUID
- Profil ile mevcut host alias'ı arasında ilişki
- Uygulama içinden alias değiştirildiğinde metadata ilişkisinin taşınması
- Config dışarıdan değiştirilip alias kaybolursa yetim profil uyarısı ve yeniden eşleştirme
- Parola, token veya özel anahtar içeriği saklamama

### Grup ve senkron terminal davranışı

- Bağlantı grubu açıldığında her host kendi başlangıç akışını çalıştırır.
- Bir hosttaki hata diğer bağlantıların terminal süreçlerini otomatik kapatmaz.
- Başlangıç akışları tamamlanana kadar senkron terminal girişi kapalı tutulur.
- Toplu otomatik komut çalıştırılacaksa hedef hostlar bağlantı öncesinde gösterilir.
- Kullanıcı tüm başlangıç akışlarını tek eylemle atlayabilir.

### Güvenlik sınırları

- Parola veya token içerdiği düşünülen komutlarda kalıcı saklama uyarısı gösterilir.
- Uygulama `sudo` parolasını yakalamaz veya saklamaz; gerekiyorsa terminal içindeki normal parola istemi kullanılır.
- Başlangıç komutları tanılama raporuna düz metin olarak eklenmez.
- Host key onayı tamamlanmadan başlangıç akışı çalıştırılmaz.
- Otomatik çalıştırma varsayılan olarak yeni profillerde kapalı olabilir; kullanıcı açıkça etkinleştirir.

### Kabul kriterleri

- Bir host için sıralı başlangıç adımları oluşturulabilir ve kalıcı olarak saklanır.
- Kullanıcı değiştirme ve dizine geçme aynı uzak shell bağlamında çalışır.
- Başlangıç tamamlandıktan sonra terminal interaktif kalır.
- Akış bağlantı bazında atlanabilir veya manuel çalıştırılabilir.
- Alias uygulama içinden değiştirildiğinde profil kaybolmaz.
- Grup bağlantılarında her host doğru profili kullanır.
- Senkron terminal girişi başlangıç sırasında yanlışlıkla komut çoğaltmaz.
- Quoting, özel karakterler, boşluklu yollar ve hatalı kullanıcı girdileri otomatik testlerle kapsanır.

### İleri sürümler

- Çıktıda belirli bir metni veya prompt'u bekleme
- Adım başına timeout
- Koşullu adımlar
- Ortam değişkenleri
- Yeniden kullanılabilir başlangıç profilleri
- Profili birden fazla bağlantıya atama
- Başlangıç akışını yalnızca belirli bağlantı gruplarında çalıştırma

## 7. P1 — Hızlı bağlantı bulucu

### Kapsam

- `Command-K` ile açılan hızlı erişim penceresi
- Alias, HostName, User ve grup adına göre fuzzy arama
- Favori bağlantılar
- Son kullanılan bağlantılar
- İsteğe bağlı kullanıcı etiketleri
- Sonuç üzerinden bağlanma, ayarları açma, dosya aktarımı veya tanılama başlatma

### Kabul kriterleri

- Yüzlerce host içinde klavye kullanarak hızlı arama yapılabilir.
- Wildcard ve negatif pattern'ler doğrudan bağlanılabilir sonuç olarak sunulmaz.
- Son kullanılanlar ve favoriler uygulama metadata'sında güvenli biçimde saklanır.
- Arama sonuçları config dışarıdan değiştirildiğinde yenilenir.

## 8. P1 — Yeniden bağlanma ve workspace saklama

### Kapsam

- Kapanmış terminal bölmesinde “Yeniden bağlan” eylemi
- Aynı alias ile yeni bağlantı açma
- Son sekme ve bölme düzenini saklama
- Bağlantı grubu düzenlerini yeniden oluşturma
- İsteğe bağlı otomatik reconnect ve artan bekleme süresi
- Ağ geri geldiğinde kullanıcı onayıyla yeniden bağlantı

### Güvenlik ve davranış

- Uygulama kapanırken SSH süreçleri arka planda bırakılmaz.
- Uygulama yeniden açıldığında eski süreçlere bağlıymış gibi davranılmaz; yalnızca workspace düzeni yeniden oluşturulur.
- Otomatik reconnect başlangıç akışını tekrar çalıştıracaksa kullanıcı tercihi dikkate alınır.
- Aynı başlangıç komutunun farkında olmadan iki kez çalışması önlenir.

## 9. P2 — Tunnel Manager

### Kapsam

- `LocalForward`
- `RemoteForward`
- `DynamicForward`
- Tünel adı ve açıklaması
- Bağlı host seçimi
- Yerel portun kullanımda olup olmadığını kontrol etme
- Tüneli başlatma/durdurma
- Aktif, bağlanıyor, başarısız ve yeniden bağlanıyor durumları
- Uygulama içinden oluşturulan tüneli kalıcı config direktifine dönüştürme seçeneği

### Güvenlik

- Varsayılan local bind adresi `127.0.0.1` olmalıdır.
- `0.0.0.0` veya dış dünyaya açık bind için açık uyarı gösterilmelidir.
- Tünel süreçleri terminal oturumlarından ayrı izlenmelidir.
- Uygulama kapanırken aktif tünellerin kapatılacağı kullanıcıya bildirilmelidir.

## 10. P2 — Gelişmiş aktarım yöneticisi

### Kapsam

- Birden fazla dosya seçme
- Klasör yükleme ve indirme
- Aktarım kuyruğu
- Eşzamanlı aktarım limiti
- Başarısız aktarımı tekrar deneme
- İptal sonrası kısmi dosyayı bulma ve temizleme seçeneği
- Dosya boyutu, hız, kalan süre ve toplam ilerleme
- İsteğe bağlı checksum doğrulaması
- Aktarım geçmişi; hassas yollar için redaksiyon seçeneği

### Not

README içindeki uzak dizin tarayıcısının desteklendiğini söyleyen bölüm ile desteklenmediğini söyleyen ifade birbiriyle çelişmektedir. Yeni özellik geliştirmesinden bağımsız olarak dokümantasyon güncellenmelidir.

## 11. P2 — Güvenli runbook sistemi

Bağlantı Başlangıç Akışı yalnızca terminali hazırlamak içindir. Runbook sistemi ise kullanıcının daha sonra açıkça başlattığı operasyonel komut dizilerini kapsar.

### Kapsam

- İsimlendirilmiş komut/snippet koleksiyonları
- Parametreli komutlar
- Tek host veya bağlantı grubunda çalıştırma
- Çalıştırmadan önce hedef ve komut önizlemesi
- Host bazında çıktı ve sonuç durumu
- Tehlikeli komutlar için ek onay
- Eşzamanlı çalışma limiti
- Başarısız hostlarda yeniden deneme

### Senkron terminal güvenliği

- Senkron giriş aktifken görünür ve kalıcı bir uyarı bandı gösterilmelidir.
- Yapıştırılan çok satırlı komutlar hedef sayısıyla birlikte onaylanabilir olmalıdır.
- Başlangıç akışı, runbook ve canlı terminal broadcast davranışları birbirinden ayrılmalıdır.

## 12. P3 — Gelişmiş config editörü

### Kapsam

- OpenSSH direktif kataloğu
- Direktif açıklamaları ve beklenen değer tipi
- Otomatik tamamlama
- `LocalForward`, `RemoteForward`, `DynamicForward`, keepalive ve connection multiplexing alanları
- Form ile ham config arasında kayıpsız geçiş
- Bir değerin hangi `Host`, `Match` veya `Include` kaynağından geldiğini gösterme
- Düzenlenen değer ile `ssh -G` sonucunu yan yana karşılaştırma
- Değişiklik önizlemesi ve geri alma

## 13. P3 — Ürünleştirme

### Dağıtım

- Uygulama sürümleme
- Developer ID ile imzalama
- Hardened Runtime
- Notarization
- Güvenli otomatik güncelleme mekanizması
- Release notları

### Kalite

- CI üzerinde Swift testleri
- Xcode build doğrulaması
- Temel UI testleri
- Terminal process ve aktarım entegrasyon testleri
- Büyük config dosyaları için performans testleri
- Accessibility kontrolleri
- Privacy-first, isteğe bağlı hata raporlama

## 14. Teknik düzenleme ihtiyaçları

Yeni özellikler eklenirken ana görünümün tek dosyada büyümesi engellenmelidir. Arayüz feature bazlı parçalara ayrılmalıdır:

```text
Features/
  Connections/
  Diagnostics/
  StartupFlows/
  Terminal/
  Transfers/
  Tunnels/
  Runbooks/
  Settings/
```

Önerilen store/service ayrımı:

- `ConnectionMetadataStore`
- `StartupFlowStore`
- `WorkspaceLayoutStore`
- `FavoriteConnectionStore`
- `TunnelStore`
- `SSHProcessClient`
- `SSHConnectionDiagnostics`

View modelleri doğrudan dosya izni, JSON yazımı veya process çıktı ayrıştırma sorumluluğu taşımamalıdır.

## 15. Önerilen uygulama sırası

### Faz 1 — Güvenilir bağlantı temeli

1. Ortak SSH process katmanı
2. Hata sınıflandırma
3. Bağlantı Tanılama ve Güven Merkezi
4. README tutarsızlıklarının giderilmesi

### Faz 2 — Günlük kullanım verimliliği

1. Bağlantı Başlangıç Akışı
2. Hızlı bağlantı bulucu
3. Favoriler ve son kullanılanlar
4. Yeniden bağlanma
5. Workspace düzenini saklama

### Faz 3 — Operasyon özellikleri

1. Tunnel Manager
2. Gelişmiş aktarım kuyruğu
3. Güvenli runbook sistemi
4. Gelişmiş senkron terminal güvenlikleri

### Faz 4 — İleri config ve dağıtım

1. Direktif kataloğu ve gelişmiş form editörü
2. İmzalama ve notarization
3. Otomatik güncelleme
4. CI, UI testleri ve performans testleri

## 16. Şimdilik kapsam dışında tutulacaklar

- Özel anahtar içeriğini uygulama içinde görüntüleme veya yönetme
- SSH parolalarını uygulama metadata'sında saklama
- Host key değişikliğini otomatik kabul etme
- Kullanıcı önizlemesi olmadan bağlantı grubunda komut çalıştırma
- Uygulama kapandıktan sonra gizlice çalışan SSH/tünel süreçleri
- Sabit gecikmelerle terminale körlemesine komut yazan otomasyon

Bu sınırlar ürünün güvenlik modelini sade ve anlaşılır tutar.
