#!/bin/bash
# Koe.app に署名するための自己署名証明書をログインキーチェーンに作る。
# 署名の要件が証明書に紐づくので、作り直してもアクセシビリティなどの許可が外れなくなる。
set -euo pipefail

NAME="${KOE_SIGN_IDENTITY:-Koe Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# build-app.sh と同じく、秘密鍵もある (署名に使える) ものを名前の完全一致で探す
if security find-identity -p codesigning | grep -qF "\"$NAME\""; then
  echo "already exists: $NAME"
  exit 0
fi
# 証明書だけが残っていると、作り直しても同じ名前の証明書が並ぶ
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "error: '$NAME' の証明書はあるが、署名に使える秘密鍵がない。キーチェーンアクセスで証明書を削除してから作り直す" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:koe -name "$NAME"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P koe -T /usr/bin/codesign
echo "created: $NAME"
