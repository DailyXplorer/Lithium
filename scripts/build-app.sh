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
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for bundle in "$bin_path"/*.bundle; do
  ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done

xattr -cr "$app"
codesign --force --sign - "$app"
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
