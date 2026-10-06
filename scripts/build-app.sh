#!/bin/sh
# Builds .build/Lithium.app. Flags: --install copies it to /Applications, --run opens it.
set -eu

install=0
run=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --run) run=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

# iCloud-synced folders tag build products with xattrs that break codesign; build outside them.
if [ ! -L .build ]; then
  rm -rf .build
  mkdir -p "$HOME/Library/Caches/Lithium/build"
  ln -s "$HOME/Library/Caches/Lithium/build" .build
fi

if [ ! -f Sources/Lithium/Resources/Filters/manifest.json ]; then
  python3 scripts/update-filters.py
fi

swift build -c release
bin_path=$(swift build -c release --show-bin-path)

# Assemble and sign outside Documents: file-provider xattrs there break codesign.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/Lithium.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/Lithium" "$app/Contents/MacOS/Lithium"
# The stdio bridge agents start, at a path that stays put across updates.
cp "$bin_path/lithium-mcp" "$app/Contents/MacOS/lithium-mcp"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for bundle in "$bin_path"/*.bundle; do
  ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done

# Ad-hoc signatures pin the designated requirement to the cdhash, so every rebuild looks like
# a new app to the keychain and WebKit's items (WebCrypto master key…) prompt for the password
# again. A stable self-signed identity keeps the requirement identical across builds.
identity="Lithium Local Code Signing"
if ! security find-identity -p codesigning | grep -q "\"$identity\""; then
  certdir="$stage/cert"
  mkdir "$certdir"
  cat > "$certdir/cfg" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$identity
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -config "$certdir/cfg" \
    -keyout "$certdir/key.pem" -out "$certdir/cert.pem" 2>/dev/null
  openssl pkcs12 -export -legacy -inkey "$certdir/key.pem" -in "$certdir/cert.pem" \
    -name "$identity" -out "$certdir/id.p12" -passout pass:lithium 2>/dev/null \
    || openssl pkcs12 -export -inkey "$certdir/key.pem" -in "$certdir/cert.pem" \
      -name "$identity" -out "$certdir/id.p12" -passout pass:lithium
  security import "$certdir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P lithium -T /usr/bin/codesign >/dev/null
  rm -rf "$certdir"
fi
sign_hash=$(security find-identity -p codesigning | grep "\"$identity\"" | awk '{ print $2; exit }')

xattr -cr "$app"
# Nested code first: the app's signature seals the bridge's. Same identity, so neither asks for
# the keychain, and the app's designated requirement stays what it was.
codesign --force --sign "$sign_hash" --identifier app.lithium.browser.mcp "$app/Contents/MacOS/lithium-mcp"
codesign --force --sign "$sign_hash" "$app"
codesign --verify --deep --strict "$app"

osascript -e 'tell application id "app.lithium.browser" to quit' >/dev/null 2>&1 || true
# A sheet or dialog can veto the quit; give it 3 s, then force it.
attempt=0
while pgrep -x Lithium >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -eq 30 ]; then pkill -x Lithium || true; fi
  sleep 0.1
done

output="$project_dir/.build/Lithium.app"
rm -rf "$output"
ditto --norsrc --noextattr "$app" "$output"
app="$output"

if [ "$install" -eq 1 ]; then
  rm -rf /Applications/Lithium.app
  ditto --norsrc --noextattr "$app" /Applications/Lithium.app
  app=/Applications/Lithium.app
fi

printf '%s\n' "$app"
if [ "$run" -eq 1 ]; then
  open "$app"
fi
