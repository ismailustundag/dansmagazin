# Release Readiness Checklist

## 1) Hesap ve Yetki

- [ ] Google Play Console hesabı aktif.
- [ ] Apple Developer Program aktif (iOS push ve production release için gerekli).

## 2) Yasal Metinler (Uygulama içi)

- [x] Gizlilik Politikası: `https://www.dansmagazin.net/gizlilik-politikasi/`
- [x] KVKK Aydınlatma: `https://www.dansmagazin.net/kvkk/`
- [x] Kullanım Şartları: `https://www.dansmagazin.net/sartlar-ve-kosullar/`
- [x] Destek: `https://www.dansmagazin.net/`

Not: Linkler `lib/services/legal_links.dart` dosyasından yönetilir.

## 3) Build Standardı

- [x] Her build komutunda aynı API kullan:
  - `--dart-define=API_BASE_URL=https://api2.dansmagazin.net`
- [x] Her build’de commit SHA göm:
  - `--dart-define=APP_BUILD_SHA=$(git rev-parse --short HEAD)`
- [x] Google native login define değerleri:
  - `--dart-define=GOOGLE_SERVER_CLIENT_ID=715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com`
  - `--dart-define=GOOGLE_IOS_CLIENT_ID=715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com`

## 3.0) Güncel Proje Değerleri

- Checklist son güncelleme tarihi: `2026-06-24`
- Geçerli branch: `main`
- Checklist güncellenirken görülen HEAD: `f3f673a`
- `pubspec.yaml` sürümü: `1.0.24+38`
- Google Play mevcut sürüm: `1.0.20` (`versionCode 34`)
- Apple mevcut sürüm: `1.0.21` (`build 35`)
- Yeni public update için önerilen Flutter sürümü: `1.0.24+38`
- Sadece iOS TestFlight rebuild gerekiyorsa alternatif: `1.0.24+38`
- Android package / applicationId: `net.dansmagazin.mobile`
- Android Firebase OAuth type=1 SHA-1: `12:FB:D0:FA:C9:4A:C7:98:35:C9:6E:F0:D5:6C:15:EC:0C:1D:78:F1`
- iOS bundle id: `com.example.mobilAppPreview`
- iOS Google client id: `715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com`
- Xcode Team ID: `2ZC7F7WS8W`
- iOS deployment target: `13.0`

## 3.1) Build Almadan Önce Zorunlu Kontrol

- [ ] Build öncesi repo çalışma alanı temiz.
  - Zorunlu kontrol: `./scripts/release_guard.sh`
  - Not: Script varsayılan olarak dirty worktree ile release build'i durdurur. Bilinçli local test build gerekiyorsa sadece istisnai olarak `ALLOW_DIRTY_RELEASE=1` ile geç.
- [x] `pubspec.yaml` içindeki `version:` yeni build için artırıldı (`1.0.23+37`).
- [ ] Android yüklemesi yapılacaksa yeni `versionCode` daha önce Play Console'a yüklenen hiçbir build ile çakışmıyor.
- [x] `android/app/google-services.json` içinde `net.dansmagazin.mobile` bloğu var.
- [x] `android/app/google-services.json` içinde Android OAuth client var:
  - `client_type: 1`
  - `package_name: net.dansmagazin.mobile`
  - `certificate_hash: 12fbd0fac94ac79835c96ef0d56c15ec0c1d78f1`
- [ ] Firebase `Authentication > Sign-in method > Google` açık.
- [ ] Firebase Android app için SHA fingerprint'ler doğru.
  - Yerel/release keystore SHA-1 kayıtlı:
    - `12:FB:D0:FA:C9:4A:C7:98:35:C9:6E:F0:D5:6C:15:EC:0C:1D:78:F1`
  - Google Play App Signing SHA-1 kayıtlı:
    - `92:31:60:D7:90:F4:15:F1:08:00:30:C1:DE:BF:25:74:DB:55:07:C0`
  - Not: Yerel APK ile Play'den kurulan build ayni sertifikayla imzalanmaz. Google login icin iki SHA-1 de Firebase'te ayni Android app altinda tanimli olmali.
- [ ] Android'de mağazaya çıkmadan önce en az bir yerel APK testinde Google giriş denendi.
- [ ] Android'de yeni AAB yuklendikten sonra, tester cihazinda eski uygulama silinip kapali test linkinden temiz kurulumla Google giris tekrar denendi.
- [x] iOS için `ios/GoogleService-Info.plist` doğru app/bundle'a ait.
- [ ] iOS'ta mağazaya çıkmadan önce en az bir gerçek cihaz testinde Google giriş denendi.
- [ ] Build komutu çalıştırmadan önce `git rev-parse --short HEAD` ile kullanılacak commit not edildi.
- [ ] Release amacıyla yapılan özellik düzeltmeleri gerçekten commit içinde.
  - Hızlı kontrol: `git show --stat --oneline -1`
  - Kritik dosya değişiklikleri çalışma alanında kalmış ama commit'e girmemiş olmamalı.

## 3.2) Sabit Build Sırası

### Android AAB (Play Console)

```bash
cd ~/dansmagazin/mobile_app_preview
git fetch origin
git rev-parse --short origin/main
./scripts/build_android_appbundle.sh
```

Alternatif tek komut:

```bash
./scripts/build_android_appbundle.sh
```

Not:
- Script her çalışmada tek kullanımlık temiz bir release workspace açar.
- `android/app/google-services.json`, `ios/Runner/GoogleService-Info.plist` ve varsa Android signing dosyalarını mevcut klasörden otomatik kopyalar.
- Mevcut repo kirli olsa bile build temiz worktree üzerinden alınır.

### Android APK (Yerel Doğrulama)

```bash
cd ~/dansmagazin/mobile_app_preview
git fetch origin
git rev-parse --short origin/main
./scripts/build_android_release.sh
```

Alternatif tek komut:

```bash
./scripts/build_android_release.sh
```

### iOS TestFlight / Archive

```bash
cd ~/dansmagazin/mobile_app_preview
git fetch origin
git rev-parse --short origin/main
./scripts/prepare_ios_archive.sh
```

Alternatif tek komut:

```bash
./scripts/prepare_ios_archive.sh
```

Not:
- Script build işlemini tek kullanımlık temiz release workspace içinde yapar.
- Xcode archive ekranı bu temiz workspace üzerinden açılır; iş bitince ilgili workspace klasörü silinebilir.

Not:
- Play Console'a yanlış build yüklenirse `versionCode` tekrar kullanılamaz.
- Bu yüzden Android'de önce yerel APK doğrulaması, sonra AAB yüklemesi tercih edilir.
- Google login sorunu varsa önce cihazdan Play build sertifikasi doğrulanır:

```bash
adb devices
adb shell pm path net.dansmagazin.mobile
APK_PATH=$(adb shell pm path net.dansmagazin.mobile | sed -n '1s/package://p')
adb pull "$APK_PATH" ~/Desktop/dansmagazin-play-base.apk
APKSIGNER=$(find "$HOME/Library/Android/sdk/build-tools" -name apksigner | sort | tail -n 1)
"$APKSIGNER" verify --print-certs ~/Desktop/dansmagazin-play-base.apk
```

- Beklenen Play signing SHA-1:
  - `92:31:60:D7:90:F4:15:F1:08:00:30:C1:DE:BF:25:74:DB:55:07:C0`

## 4) Android Yayın Kontrolü

- [x] `google-services.json` doğru paket adına ait (`net.dansmagazin.mobile` bloğu mevcut).
- [ ] Bildirim izin/teslim testi tamam.
- [ ] Mesaj geldiğinde push bildirimi ("Yeni bir mesajın var") testi tamam.
- [ ] Google giriş (mevcut + yeni kullanıcı) test edildi.
- [ ] Play Store Data Safety formu dolduruldu.

## 5) iOS Yayın Kontrolü

- [x] `GoogleService-Info.plist` doğru bundle id’ye ait (`com.example.mobilAppPreview`).
- [ ] Xcode Signing & Capabilities tamam.
- [ ] Google giriş (mevcut + yeni kullanıcı) test edildi.
- [ ] APNs/Push production testi tamam.
- [ ] Mesaj geldiğinde push bildirimi ("Yeni bir mesajın var") testi tamam.

## 6) Store İçerikleri

- [ ] Uygulama açıklaması (TR/EN)
- [ ] Ekran görüntüleri
- [ ] İkon ve feature graphic
- [ ] Destek e-postası ve gizlilik URL’si

## 7) Sürüm Sabitleme

- [x] Test edilmiş sürüm tag’i: `mobile-tested-20260306-google-native`
- [ ] Mağazaya gönderilecek sürüm için ayrı release tag aç.

## 8) Ürün İçi Son Dokunuşlar

- [x] Etkinlik detayında `Takvime Ekle` aksiyonu var.
- [x] Bildirim kartı route içeriyorsa tıklanınca ilgili hedefe gider.
- [x] Deep link yönlendirme (`/events/:id`, `/messages/:id`, `/profile/notifications`) genişletildi.
- [ ] Etkinlik paylaşım akışı gerçek cihazda doğrulandı.
  - `Link paylaş`: `https://api2.dansmagazin.net/share/events/{id}` formatında olmalı.
  - `Akışa ekle`: paylaşım öncesi not/metin penceresi açılmalı.
  - `Görsel olarak paylaş`: etkinliğin yüklenen afişi paylaşılmalı; turuncu şablon sadece afiş indirilemezse fallback olmalı.
- [ ] Bilet için gerçek `Apple Wallet` / `Google Wallet` pass üretimi aktif (backend imzalama + wallet linkleri).

## 9) iOS App Store Uyum

- [x] `Sign in with Apple` kod ve entitlement tarafında eklendi.
- [ ] `Sign in with Apple` gerçek cihazda test edildi (Google login ile birlikte zorunluluk riski için kritik).
- [ ] App Store Connect > App Privacy alanları eksiksiz dolduruldu.
- [ ] TestFlight internal + external test turu tamamlandı.
- [ ] Production APNs tokenlarıyla gerçek cihaz testi tamamlandı.

## 10) Android Play Store Uyum

- [ ] AAB çıktısı alındı ve Play App Signing aktif.
- [ ] Play Console Data Safety formu eksiksiz dolduruldu.
- [ ] Account deletion policy ve uygulama içi hesap silme akışı doğrulandı.
