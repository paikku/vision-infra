#!/bin/sh
# Edge nginx TLS cert validator.
#
# /certs is mounted :ro from /appdata/certs/vip/sso (docker-compose.yml).
# create_host_path:false on that bind already fails compose-up when the
# host dir itself is absent — by the time this script runs the dir is
# guaranteed to exist. The remaining cases:
#
#   - fullchain.pem and privkey.pem both present and non-empty → exit 0
#     and let nginx come up.
#   - either file missing or empty → log an actionable error and exit
#     non-zero. nginx (depends_on: completed_successfully) refuses to start.
#
# There is no self-signed fallback in any environment; operators (or local
# dev) must place a real cert (or generate one with the openssl command
# printed below) before `compose up`.

set -e

CRT="/certs/fullchain.pem"
KEY="/certs/privkey.pem"

if [ -s "$CRT" ] && [ -s "$KEY" ]; then
    echo "[cert-init] cert present at /certs, OK"
    exit 0
fi

cat >&2 <<EOF
[cert-init] missing cert at /certs (fullchain.pem and/or privkey.pem absent or empty).
[cert-init] place real certs at /appdata/certs/vip/sso/{fullchain,privkey}.pem,
[cert-init] or generate a self-signed pair for local dev:
[cert-init]
[cert-init]   sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365 \\
[cert-init]       -subj '/CN=localhost' \\
[cert-init]       -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \\
[cert-init]       -keyout /appdata/certs/vip/sso/privkey.pem \\
[cert-init]       -out    /appdata/certs/vip/sso/fullchain.pem
EOF
exit 1
