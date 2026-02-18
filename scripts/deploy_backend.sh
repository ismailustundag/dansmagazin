#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/ubuntu/dansmagazin_repo"
SRC_DIR="$REPO_DIR/mobil_backend"
APP_DIR="/home/ubuntu/mobil_backend"

cd "$REPO_DIR"
git pull origin main

if [ ! -d "$SRC_DIR" ]; then
  echo "HATA: $SRC_DIR bulunamadı. Önce repo'ya mobil_backend eklenmeli."
  exit 1
fi

mkdir -p "$APP_DIR"

# Repo'daki backend kodunu canlı app klasörüne kopyala
rsync -av --delete \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude '.env' \
  --exclude 'media/' \
  "$SRC_DIR"/ "$APP_DIR"/

cd "$APP_DIR"

# Venv yoksa oluştur
if [ ! -f ".venv/bin/activate" ]; then
  python3 -m venv .venv
fi

source .venv/bin/activate
pip install -r requirements.txt

sudo systemctl restart mobil-backend
sudo systemctl status mobil-backend --no-pager -l | sed -n '1,30p'

curl -sS http://127.0.0.1:8100/health
