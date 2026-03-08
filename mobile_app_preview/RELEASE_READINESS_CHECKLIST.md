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

## 4) Android Yayın Kontrolü

- [ ] `google-services.json` doğru paket adına ait.
- [ ] Bildirim izin/teslim testi tamam.
- [ ] Google giriş (mevcut + yeni kullanıcı) test edildi.
- [ ] Play Store Data Safety formu dolduruldu.

## 5) iOS Yayın Kontrolü

- [ ] `GoogleService-Info.plist` doğru bundle id’ye ait.
- [ ] Xcode Signing & Capabilities tamam.
- [ ] Google giriş (mevcut + yeni kullanıcı) test edildi.
- [ ] APNs/Push production testi tamam.

## 6) Store İçerikleri

- [ ] Uygulama açıklaması (TR/EN)
- [ ] Ekran görüntüleri
- [ ] İkon ve feature graphic
- [ ] Destek e-postası ve gizlilik URL’si

## 7) Sürüm Sabitleme

- [x] Test edilmiş sürüm tag’i: `mobile-tested-20260306-google-native`
- [ ] Mağazaya gönderilecek sürüm için ayrı release tag aç.
