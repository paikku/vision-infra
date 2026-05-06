#!/bin/sh
# Edge nginx TLS bootstrap. If no cert is mounted into /certs, write a
# self-signed pair so :443 still answers. Production deployments should
# mount real certs (Let's Encrypt, internal CA) — the [ -s ] check below
# means this script is a no-op once a real cert is in place.
#
# Mirrors the cert-generation step from vision/docker/entrypoint.sh so
# the dev experience stays "compose up just works".

set -e

CRT="/certs/fullchain.pem"
KEY="/certs/privkey.pem"

if [ -s "$CRT" ] && [ -s "$KEY" ]; then
    echo "[cert-init] real cert already present at /certs, skipping"
    exit 0
fi

echo "[cert-init] no cert at /certs, generating a self-signed pair"
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
echo "[cert-init] wrote self-signed cert (CN=localhost, 365 days)"
