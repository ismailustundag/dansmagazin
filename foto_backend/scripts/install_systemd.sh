#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_SRC="$ROOT_DIR/deploy/systemd/foto-app.service"
ENV_EXAMPLE="$ROOT_DIR/deploy/systemd/foto-app.env.example"
SERVICE_DST="/etc/systemd/system/foto-app.service"
ENV_DST="/etc/default/foto-app"

if [[ ! -f "$SERVICE_SRC" ]]; then
  echo "Hata: service dosyasi bulunamadi: $SERVICE_SRC"
  exit 1
fi

echo "[1/6] Service dosyasi kopyalaniyor..."
sudo cp "$SERVICE_SRC" "$SERVICE_DST"

if [[ ! -f "$ENV_DST" ]]; then
  echo "[2/6] Env dosyasi olusturuluyor..."
  sudo cp "$ENV_EXAMPLE" "$ENV_DST"
else
  echo "[2/6] Env dosyasi zaten var, dokunulmadi: $ENV_DST"
fi

echo "[3/6] systemd reload"
sudo systemctl daemon-reload

echo "[4/6] Eski uvicorn processleri temizleniyor"
sudo systemctl stop foto-app >/dev/null 2>&1 || true
for p in $(pgrep -f "/home/ubuntu/etkinlik_fotograf_projesi/venv/bin/uvicorn main:app" || true); do
  sudo kill -9 "$p" >/dev/null 2>&1 || true
done

echo "[5/6] Servis enable + restart"
sudo systemctl enable foto-app
sudo systemctl restart foto-app

echo "[6/6] Servis durumu"
sudo systemctl --no-pager --full status foto-app | sed -n '1,40p'

echo "Tamamlandi. Log: tail -f /home/ubuntu/etkinlik_fotograf_projesi/uvicorn.log"
