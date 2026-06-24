from pathlib import Path

import qrcode


APP_DOWNLOAD_URL = "https://api2.dansmagazin.net/app-download"
OUTPUT_PATH = Path("/home/ubuntu/mobil_backend/media/app_download_qr.png")


def main() -> None:
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=16,
        border=4,
    )
    qr.add_data(APP_DOWNLOAD_URL)
    qr.make(fit=True)
    image = qr.make_image(fill_color="black", back_color="white")
    image.save(OUTPUT_PATH)
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
