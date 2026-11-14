# Android OTA

DansMagazin Android OTA yamalari Shorebird ile yayinlanir. iOS kod
guncellemeleri App Store uzerinden yayinlanmaya devam eder.

## Temel surum

Temel surum Play Store'a yuklenmeden o surum OTA yamasi alamaz.

```bash
cd /Users/ismailustundag/dansmagazin/mobile_app_preview
RELEASE_REF=<commit> ./scripts/build_android_ota_release.sh
```

## Yama

Once staging kanalina yayinla ve fiziksel Android cihazda dogrula:

```bash
cd /Users/ismailustundag/dansmagazin/mobile_app_preview
RELEASE_REF=<commit> SHOREBIRD_RELEASE_VERSION=1.0.30+44 ./scripts/patch_android_ota.sh
```

Uretim icin ayni dogrulanmis commit ile `SHOREBIRD_TRACK=stable` kullanilir.
Native Android kodu, yeni eklenti, izin veya asset degisiklikleri OTA ile
gonderilmez; bunlar icin yeni Play Store surumu gerekir.
