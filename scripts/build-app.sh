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
# One folder per checkout: shared, another checkout's build between this build and the copy
# below swapped the binary that ships. A link to the old shared folder or to another checkout's (a
# copied checkout keeps the original's) is moved; one of your own stays.
cache="$HOME/Library/Caches/Lithium"
build_dir="$cache/builds/$(pwd -P | shasum | cut -c1-12)"
if [ ! -L .build ] || case $(readlink .build) in "$build_dir") false ;; "$cache/build" | "$cache/builds/"*) true ;; *) false ;; esac; then
  rm -rf .build
  mkdir -p "$build_dir"
  ln -s "$build_dir" .build
fi
# The caches folder may be emptied at any time: the link then leads nowhere, and the build
# fails on it.
[ "$(readlink .build 2>/dev/null)" = "$build_dir" ] && mkdir -p "$build_dir"

# A missing, half-written or outdated set (FilterSources.json changed since) is built again.
if ! python3 scripts/update-filters.py --check; then
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
  # A test target's resources (Lithium_LithiumTests.bundle, left by a test build) aren't the app's.
  case "$(basename "$bundle")" in *Tests.bundle) continue ;; esac
  ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done

# Ad-hoc signatures pin the designated requirement to the cdhash, so every rebuild looks like
# a new app to the keychain and WebKit's items (WebCrypto master key…) prompt for the password
# again. A self-signed identity keeps the requirement stable, but it has no team ID: the login
# keychain's partition list then names each build by its cdhash, and "Always Allow" only holds
# until the next build. A certificate with a team ID (a free "Apple Development" one from Xcode's
# Accounts settings) makes the partition the team, the same for every build, so it is preferred.
# LITHIUM_SIGN_IDENTITY picks one explicitly.
team_identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
identity="${LITHIUM_SIGN_IDENTITY:-${team_identity:-Lithium Local Code Signing}}"
if [ "$identity" = "Lithium Local Code Signing" ] && ! security find-identity -p codesigning | grep -q "\"$identity\""; then
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

# Only a build that installs or opens the app quits the running one: the bundle id also names
# the installed copy the user may be browsing in.
if [ "$install" -eq 1 ] || [ "$run" -eq 1 ]; then
  osascript -e 'tell application id "app.lithium.browser" to quit' >/dev/null 2>&1 || true
  # A sheet or dialog can veto the quit. Forcing it would skip the app's own save at quit and
  # lose what that sheet holds, so after 3 s the build stops instead.
  attempt=0
  while pgrep -x Lithium >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -eq 30 ]; then
      printf 'Lithium did not quit; close its open dialogs, quit it, and run this again.\n' >&2
      exit 1
    fi
    sleep 0.1
  done
fi

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
