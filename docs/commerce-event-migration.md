# Guvenli ticaret ve etkinlik yonetimi gecisi

## Kapsam

Web sitesi, mobil uygulama ve yonetim paneli; kullanici, urun, siparis, odeme, bilet ve etkinlik verisini ortak mobil backend API'sinden okuyacak. Mevcut odeme saglayicisi korunacak. WooCommerce gecis boyunca geri donus ve tarihsel mutabakat kaynagi olarak tutulacak.

## Faz 0 - Koruma ve gozlem

- Canli veritabanisi ve sunucu dosyalari zaman damgali yedeklenir.
- Siparis, bilet, kullanici ve etkinlik sayilari mutabakat raporuna alinır.
- Woo callback olaylari loglanir; ayni olay tekrar geldiginde tek kez islenir.
- Supheli mesajlarda hesap silmek yerine oran limiti, ayni icerik parmak izi, alici bazli limit ve yonetici engellemesi uygulanir.
- Mevcut WooCommerce satisi, webhook ve bilet akisi kapatilmaz.

## Faz 1 - Ortak model ve API

Asagidaki modeller backend tarafinda olusturulur:

- `commerce_products`
- `commerce_variations`
- `commerce_orders`
- `commerce_order_items`
- `payment_transactions`
- `payment_events`
- `event_change_log`

API yuzeyi:

- `GET /commerce/products`
- `GET /commerce/products/{id}`
- `POST /commerce/orders`
- `POST /commerce/orders/{id}/payment`
- `GET /commerce/payment/return`
- `POST /commerce/payment/callback`
- `GET /admin/commerce/orders`
- `GET /admin/commerce/orders/{id}`
- `PATCH /admin/commerce/products/{id}`

### 2026-10-13 durum notu

- Ortak katalogdaki mevcut ürünler web yönetiminde okunuyor ve düzenleniyor.
- Yeni ürün ve varyasyonları tek veritabanı işleminde **taslak** olarak kaydeden yönetici API'si eklendi; görseller ayrı yüklenip optimize ediliyor.
- Yeni ürün formu artık tarayıcıya özel kayıt oluşturmuyor. Daha önce tarayıcıda tutulan ürünler otomatik taşınmadı ve listede ayrı işaretleniyor.
- Yeni dahili ürünleri yayımlama hem web arayüzünde hem API'de kapalı. Bu kayıtlar ödeme kimliği eşleştirmesi doğrulanmadan mağaza ve mobilin açık kataloğuna girmiyor.
- Sunucu birim testleri, yönetici yetkisi kontrolü ve canlı katalog okuma kontrol edildi. Gerçek ödeme, sipariş ve bilet üretimi bu adımda test edilmedi veya değiştirilmedi.
- Canlı salt-okunur kontrolde 2 etkinlik ürünü ve 1 etkin dahili test ürünü bulundu; varyasyon kaynak kimliği çakışması yok. Dahili test ürününün kaynak varyasyon kimliği sayısal değil, mevcut ödeme doğrulaması ise sayısal varyasyon kimliği bekliyor. Bu ürünün güvenle satın alınabildiği henüz doğrulanmış sayılmaz.

### Sonraki kontrollü kapı

1. Dahili varyasyon kimliği ile Woo kaynaklı varyasyon kimliğini ödeme doğrulamasında açıkça ayır; mevcut fiyatın her iki yolda da sunucudan alındığını test et.
2. Taslak ürünün web ve mobilde aynı ürün/fiyat/görselle görünmesini ayrı test ortamında doğrula. Eski tarayıcı kayıtlarını ancak kimlik ve fiyat karşılaştırmasından sonra taşı.
3. Düşük tutarlı gerçek satışta ödeme, sipariş, kullanıcı hesabı ve tekil QR bilet mutabakatını yap. Başarısızlıkta yeni ürün yayını kapalı kalsın; Woo akışını değiştirme.

### 2026-10-14 ilerleme ve kalan kapı

- Web mağazası artık etkin dahili ürünleri ortak katalog API'sinden okuyor; 1 TL test ürünü listede ve detayda görünüyor. Eski Woo ürünleri korunuyor. Canlı web detayında satın alma hâlâ kapalı.
- Yerel ödeme değişikliği dahili varyasyonu veritabanı kimliğiyle, Woo varyasyonunu eski kaynak kimliğiyle ayırıyor. İstemci fiyatı sunucuda yeniden doğrulanıyor; stok ve ürün aktifliği denetleniyor. Dahili ürünler Woo bilet senkronuna gönderilmiyor.
- Bu ödeme kodu canlıya yedek alınarak dağıtıldı. `ENABLE_INTERNAL_COMMERCE_PAYMENTS` varsayılan olarak kapalı; canlı dahili ödeme başlangıcı 409, sağlık ve katalog kontrolleri 200 verdi. Geri dönüş dosyası: `/home/ubuntu/mobil_backend/backups/payments.py.before-internal-commerce-20261014T094744Z`.
- Sonraki güvenlik düzeltmesi, dahili siparişi yalnızca süresi geçmemiş ve e-postası eşleşen uygulama oturumuna bağlar; ödeme formundaki e-posta tek başına hesap kanıtı değildir. Canlı yedeği: `/home/ubuntu/mobil_backend/backups/payments.py.before-verified-buyer-20261014T095243Z`. Yeni ödeme anahtarı hâlâ kapalıdır.
- Web sepeti ve ödeme özeti yerel önizlemede test edildi; bu yeni istemci kodu henüz canlıya dağıtılmadı. Mobil mağazanın ortak katalog bölümü ve API testi yerelde hazır, mağaza sürümüne yayımlanmadı. Gerçek ödeme yapılmadı.
- 1 TL deneme ürünü etkinliğe bağlı değil; satın alınırsa QR bilet üretmesi beklenmez. Etkinlik bileti için ürün-etkinlik-bilet türü eşleştirmesi ve ayrı uçtan uca test gerekir.
- Sıradaki kapı: ödeme dönüşündeki sipariş/kullanıcı eşleştirmesini ve hata telafisini test ortamında doğrula; mobil derleme ve dağıtımı yap; düşük tutarlı gerçek ödemeyi kullanıcıyla birlikte gerçekleştirip sipariş mutabakatını kontrol et. Bunlar bitmeden ödeme anahtarını açma veya Woo akışını kaldırma.

### 2026-10-14 1 TL kontrollu satis acilisi

- Canli magaza, sepet ve odeme sayfalari ayni guncel JS/CSS surumune alindi. `commerce-3` detayinda `Sepete ekle` gorunuyor; canli tarayici testinde 1 TL satiri sepete ve odeme ozetine tasindi. Test satiri sonradan sepetten kaldirildi.
- Dahili odeme genel urun yayini icin degil, yalnizca `codex-test-1tl-20261013` kaynak kimligi icin acildi. `deploy/internal-commerce-canary.conf` bu siniri tanimlar. Giris yapmayan 1 TL istegi 401, izin verilmeyen urun 409 dondu. Diger urunler ve Woo akisi degistirilmedi.
- Dahili odeme donusu, tarayicidan gelebilen basari parametresini tek basina kabul etmez; saglayici `checkstatus` dogrulamasi gerekir. Birim testleri 11 dahili odeme + 7 mevcut ticaret testi olarak gecti.
- Geri donus yedekleri: `/home/ubuntu/mobil_backend/backups/commerce-canary-20261014/payments.py` ve ayni dizindeki `static/` dosyalari. Acil kapatma icin once `internal-commerce-canary.conf` devre disi birakilip servis yeniden baslatilir; statik dosyalar gerekirse yedekten geri konur.
- Gercek kart islemi, basarili odeme, siparis mutabakati ve mobil magaza surumu henuz dogrulanmadi. Test urunu bir etkinlik bileti degildir ve QR bilet olusturmaz. Canli dusuk tutarli odeme kullanici tarafindan yapildiktan sonra siparis/eslesme kontrolu gerekir.

### 2026-10-15 oturum ve ADF bilet olayi

- Web oturumu artik son kullanma zamaninda yerel olarak temizleniyor; `/auth/me` de suresi bitmis token icin 401 donuyor. Sepet korunarak yeniden giris akisi aciliyor. Gecerli ve gecersiz oturumlar canlida sirasiyla 200 ve 401 verdi.
- ADF etkinlik urunu 205, biletin eski urun kimligi 3761 ile eslesti. Odeme sorgusu urun ve varyasyon kimligini birlikte dogruluyor; 3761 kullanan eski baglantilar yalnizca dogrulanmis etkinlik eslemesiyle kabul ediliyor.
- U. Konca'nin dogrulanmis odemesi `DM-372a19a2e4724713ad6ad92d71895db9` icin 674 numarali hesaba tek QR bilet (`mobile_tickets.id=1362`) olusturuldu. Ayni bilete ait e-posta SSL/465 uzerinden SMTP sunucusu tarafindan kabul edildi (`sent=1`); alici kutusuna teslim ayrica dogrulanamiyor.
- Yonetim API'si eski odeme payload'ini degistirmeden etkinlik urun eslemesini okuma sirasinda ekliyor. U. Konca siparisi canli API'de bilet urunu 3761 olarak donuyor; web yonetimi yeni JS surumunu kullaniyor.
- Canli geri donus kopyalari `/home/ubuntu/mobil_backend/backups/commerce-session-ticket-20261015/` altinda. Postgres mantiksal yedegi `adf-ugur-before-replay.dump`; `pg_restore -l` ile okunabildigi dogrulandi. Bu is icin 18 odakli test gecti.
- Ayrica barindirilan ADF siparis defterine aktarim sadece `dry_run` ile test edildi (1 uygun kayit). O defterin yazma oncesi yedegi alinmadigindan canli aktarim yapilmadi; ADF defteriyle mutabakat ayri kontrollu adimdir.
- Her yeni ucretli bilet siparisinde musteri bilet e-postasina ek olarak `info@dansmagazin.net` adresine siparis, musteri, etkinlik, bilet ve tutar bilgilerini iceren satis bildirimi gonderilir. Ayni sipariste birden fazla bilet varsa yonetici bildirimi siparis basina bir kez gider; davetli/ucretsiz biletler satis bildirimi uretmez. SMTP ayari `SALES_NOTIFICATION_EMAIL` ile acikca tanimlandi.
- Ankara Dans Festivali ortak katalog kaynagi 205 ile eski Woo urunu 3761, `saas_events.external_event_id` eslemesi uzerinden ayni `mobile_event_submissions.id=205` kaydina baglidir. Canli havuzda 16 eski Woo ve 4 yeni odeme bileti ayni etkinlik kimligi altindadir. QR kontrolu urun kimligini degil `submission_id=205` degerini kullandigi icin iki satis kaynagi ayni kapida ve ayni raporlarda birlikte calisir.

## Faz 2 - Urun, etkinlik ve bilet eslestirmesi

Woo product/variation ID, mobil etkinlik ID, bilet turu, fiyat ve aktiflik tek bir eslestirme kaydinda tutulur. Etkinlik duzenleme; tarih, tekrar kurali, konum, aciklama, bilet satis durumu ve urun eslestirmesini ayni transaction icinde gunceller. Her degisiklik `event_change_log` kaydina yazilir.

## Faz 3 - Paralel odeme dogrulamasi

Kendi siparis kaydi ve mevcut Woo siparisi bir sure birlikte tutulur. Odeme saglayici callback/API dogrulamasi `paid` olmadan bilet uretilmez. Callback idempotency anahtariyla tekrarli bilet uretimi engellenir. En az test, dusuk tutarli canli satis, iptal ve iade senaryolari dogrulanir.

## Faz 4 - Istemci gecisi

Web yonetimi ve mobil uygulama urunleri ortak API'den okur. Web `localStorage` siparis kaynagi olmaktan cikar. Urun duzenleme formu, varyasyon duzenleme, etkinlik baglantisi ve audit kaydi eklenir.

## Faz 5 - Woo bagimliligini azaltma

Yeni satislar kendi siparis API'sine alinir. WooCommerce salt-okunur tarihsel kaynaga indirilir. Mutabakat raporlari ve geri donus testi basarili olmadan Woo webhook'u veya urunleri silinmez.

## Geri donus kosulu

Her fazda eski endpoint, webhook, veritabani tablolari ve Woo urunleri korunur. Tutarsizlikta yeni satis akisi durdurulur, eski dogrulanmis akisa donulur; mevcut biletler silinmez.
