#!/usr/bin/env bash
set -euo pipefail

sudo systemctl restart foto-app.service
sudo systemctl status foto-app.service --no-pager -l
