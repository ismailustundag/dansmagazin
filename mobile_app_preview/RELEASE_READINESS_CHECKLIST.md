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

## 3.1) Build Almadan Önce Zorunlu Kontrol

- [ ] `pubspec.yaml` içindeki `version:` yeni build için artırıldı.
- [ ] Android yüklemesi yapılacaksa yeni `versionCode` daha önce Play Console'a yüklenen hiçbir build ile çakışmıyor.
- [ ] `android/app/google-services.json` içinde `net.dansmagazin.mobile` bloğu var.
- [ ] `android/app/google-services.json` içinde Android OAuth client var:
  - `client_type: 1`
  - `package_name: net.dansmagazin.mobile`
  - `certificate_hash: ...`
- [ ] Firebase `Authentication > Sign-in method > Google` açık.
- [ ] Firebase Android app için SHA fingerprint'ler doğru.
  - Yerel/release keystore SHA-1 kayıtlı:
    - `12:FB:D0:FA:C9:4A:C7:98:35:C9:6E:F0:D5:6C:15:EC:0C:1D:78:F1`
  - Google Play App Signing SHA-1 kayıtlı:
    - `92:31:60:D7:90:F4:15:F1:08:00:30:C1:DE:BF:25:74:DB:55:07:C0`
  - Not: Yerel APK ile Play'den kurulan build ayni sertifikayla imzalanmaz. Google login icin iki SHA-1 de Firebase'te ayni Android app altinda tanimli olmali.
- [ ] Android'de mağazaya çıkmadan önce en az bir yerel APK testinde Google giriş denendi.
- [ ] Android'de yeni AAB yuklendikten sonra, tester cihazinda eski uygulama silinip kapali test linkinden temiz kurulumla Google giris tekrar denendi.
- [ ] iOS için `ios/GoogleService-Info.plist` doğru app/bundle'a ait.
- [ ] iOS'ta mağazaya çıkmadan önce en az bir gerçek cihaz testinde Google giriş denendi.
- [ ] Build komutu çalıştırmadan önce `git rev-parse --short HEAD` ile kullanılacak commit not edildi.

## 3.2) Sabit Build Sırası

### Android AAB (Play Console)

```bash
cd ~/dansmagazin/mobile_app_preview
git stash -u -m autosync_tmp
git pull --rebase origin main
git stash pop || true
git rev-parse --short HEAD
grep -n '"package_name"' android/app/google-services.json
grep -n '"client_type"' android/app/google-services.json
grep -n '"certificate_hash"' android/app/google-services.json
flutter pub get
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://api2.dansmagazin.net \
  --dart-define=APP_BUILD_SHA=$(git rev-parse --short HEAD) \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com
cp build/app/outputs/bundle/release/app-release.aab ~/Desktop/dansmagazin-release-$(git rev-parse --short HEAD).aab
```

### Android APK (Yerel Doğrulama)

```bash
cd ~/dansmagazin/mobile_app_preview
flutter pub get
flutter build apk --release \
  --dart-define=API_BASE_URL=https://api2.dansmagazin.net \
  --dart-define=APP_BUILD_SHA=$(git rev-parse --short HEAD) \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com
cp build/app/outputs/flutter-apk/app-release.apk ~/Desktop/dansmagazin-release-$(git rev-parse --short HEAD).apk
```

### iOS TestFlight / Archive

```bash
cd ~/dansmagazin/mobile_app_preview
git stash -u -m autosync_tmp
git pull --rebase origin main
git stash pop || true
git rev-parse --short HEAD
flutter pub get
cd ios
pod install
cd ..
flutter build ios --release --no-codesign \
  --dart-define=API_BASE_URL=https://api2.dansmagazin.net \
  --dart-define=APP_BUILD_SHA=$(git rev-parse --short HEAD) \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=715936767290-0urophgn1ao2e9rsiibhg2lnao96n9af.apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=715936767290-bfqnn4arpk5vkka6f703i0ippnfhr9bs.apps.googleusercontent.com
open ios/Runner.xcworkspace
```

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

- [ ] `google-services.json` doğru paket adına ait.
- [ ] Bildirim izin/teslim testi tamam.
- [ ] Mesaj geldiğinde push bildirimi ("Yeni bir mesajın var") testi tamam.
- [ ] Google giriş (mevcut + yeni kullanıcı) test edildi.
- [ ] Play Store Data Safety formu dolduruldu.

## 5) iOS Yayın Kontrolü

- [ ] `GoogleService-Info.plist` doğru bundle id’ye ait.
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
- [ ] Bilet için gerçek `Apple Wallet` / `Google Wallet` pass üretimi aktif (backend imzalama + wallet linkleri).

## 9) iOS App Store Uyum

- [ ] `Sign in with Apple` eklendi ve test edildi (Google login ile birlikte zorunluluk riski için kritik).
- [ ] App Store Connect > App Privacy alanları eksiksiz dolduruldu.
- [ ] TestFlight internal + external test turu tamamlandı.
- [ ] Production APNs tokenlarıyla gerçek cihaz testi tamamlandı.

## 10) Android Play Store Uyum

- [ ] AAB çıktısı alındı ve Play App Signing aktif.
- [ ] Play Console Data Safety formu eksiksiz dolduruldu.
- [ ] Account deletion policy ve uygulama içi hesap silme akışı doğrulandı.
