#!/usr/bin/env bash
# Build a release APK from this repository and publish it to GitHub Releases.
# Usage: scripts/build-release.sh [tag]   (default tag: 1.0)
#
# Environment overrides:
#   ANDROID_HOME      Android SDK path (default: /opt/android-sdk)
#   JAVA_HOME         JDK 17 path (auto-detected from mise when unset)
#   GH_TOKEN          GitHub token (default: read from git credential store)
#   ANDROID_SIGNING_DIR  Keystore directory (default: ~/.android-signing)

set -euo pipefail

TAG="${1:-1.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------- preflight ----------
if ! ls "$ROOT"/settings.gradle "$ROOT"/settings.gradle.kts >/dev/null 2>&1; then
  echo "ERROR: no Android Gradle project found in $ROOT (only README.md?)." >&2
  echo "Add the Android sources first, then re-run: $0 $TAG" >&2
  exit 1
fi

# ---------- toolchain ----------
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

java_major() {
  if [ -x "$1/bin/java" ]; then
    "$1/bin/java" -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1
  fi
}
MAJOR="$(java_major "${JAVA_HOME:-/nonexistent}")"
if [ -z "$MAJOR" ] || [ "$MAJOR" -lt 17 ] || [ "$MAJOR" -gt 24 ]; then
  JAVA_HOME="$(mise where java@17.0.20+101 2>/dev/null || true)"
  if [ -z "$JAVA_HOME" ]; then
    JAVA_HOME="$(ls -d "$HOME"/.local/share/mise/installs/java/17* 2>/dev/null | head -1 || true)"
  fi
fi
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
  echo "ERROR: compatible JDK (17-24) not found. Install it or set JAVA_HOME." >&2
  exit 1
fi
export JAVA_HOME
BUILD_TOOLS="$(ls -d "$ANDROID_HOME"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:${BUILD_TOOLS:+$BUILD_TOOLS:}$PATH"

# ---------- build ----------
cd "$ROOT"
if [ -f gradlew ]; then
  chmod +x gradlew
  GRADLE="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE="gradle"
else
  echo "ERROR: neither gradlew nor gradle found." >&2
  exit 1
fi

[ -f local.properties ] || echo "sdk.dir=$ANDROID_HOME" > local.properties

echo "==> Building release APK (tag $TAG)"
"$GRADLE" --no-daemon assembleRelease

UNSIGNED="$(find "$ROOT" -path '*/build/outputs/apk/release/*-unsigned.apk' -type f | head -1 || true)"
SIGNED="$(find "$ROOT" -path '*/build/outputs/apk/release/*.apk' -type f ! -name '*-unsigned.apk' | head -1 || true)"

if [ -z "$SIGNED" ] && [ -z "$UNSIGNED" ]; then
  echo "ERROR: no release APK produced under build/outputs/apk/release." >&2
  exit 1
fi

# ---------- signing ----------
if [ -z "$SIGNED" ]; then
  SIGNING_DIR="${ANDROID_SIGNING_DIR:-$HOME/.android-signing}"
  KEYSTORE="$SIGNING_DIR/release.jks"
  PASS_FILE="$SIGNING_DIR/password.txt"
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  if [ ! -f "$KEYSTORE" ]; then
    echo "==> Generating release keystore at $KEYSTORE"
    PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    printf '%s' "$PASS" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    keytool -genkeypair -keystore "$KEYSTORE" -storepass "$PASS" -keypass "$PASS" \
      -alias release -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Release,O=GHS-Studio,C=CN" >/dev/null
  fi
  PASS="$(cat "$PASS_FILE")"
  SIGNED="$ROOT/build-release-${TAG}.apk"
  ALIGNED="$SIGNED.aligned"
  echo "==> Signing $UNSIGNED"
  zipalign -f -p 4 "$UNSIGNED" "$ALIGNED"
  apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$PASS" --key-pass "pass:$PASS" \
    --out "$SIGNED" "$ALIGNED"
  rm -f "$ALIGNED"
  apksigner verify --verbose "$SIGNED" | head -5
fi

DIST="$ROOT/dist"
mkdir -p "$DIST"
ASSET="$DIST/$(basename "$ROOT")-${TAG}.apk"
cp -f "$SIGNED" "$ASSET"
echo "==> APK ready: $ASSET"

# ---------- publish ----------
REMOTE="$(git -C "$ROOT" remote get-url origin)"
SLUG="$(echo "$REMOTE" | sed -E 's#^(git@|https://|ssh://git@)github\.com[:/]##; s#\.git$##')"
TOKEN="${GH_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TOKEN="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p')"
fi
if [ -z "$TOKEN" ]; then
  echo "ERROR: no GitHub token available (set GH_TOKEN)." >&2
  exit 1
fi

API="https://api.github.com/repos/$SLUG"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json")

EXISTING="$(curl -sS "${AUTH[@]}" "$API/releases/tags/$TAG" || true)"
RELEASE_ID="$(printf '%s' "$EXISTING" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("id",""))
except Exception: print("")' 2>/dev/null || true)"

if [ -z "$RELEASE_ID" ]; then
  echo "==> Creating release $TAG"
  BODY="$(curl -sS -X POST "${AUTH[@]}" "$API/releases" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":\"Android APK build for tag $TAG.\"}")"
  RELEASE_ID="$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  echo "==> Reusing existing release $TAG (id $RELEASE_ID)"
fi

ASSET_NAME="$(basename "$ASSET")"
OLD_ASSET_ID="$(curl -sS "${AUTH[@]}" "$API/releases/$RELEASE_ID/assets" | python3 -c 'import json,sys
name=sys.argv[1]
for a in json.load(sys.stdin):
    if a.get("name")==name: print(a["id"]); break' "$ASSET_NAME")"
if [ -n "$OLD_ASSET_ID" ]; then
  echo "==> Replacing existing asset $ASSET_NAME"
  curl -sS -X DELETE "${AUTH[@]}" "$API/releases/assets/$OLD_ASSET_ID" >/dev/null
fi

echo "==> Uploading $ASSET_NAME"
curl -sS -X POST "${AUTH[@]}" \
  -H "Content-Type: application/vnd.android.package-archive" \
  --data-binary @"$ASSET" \
  "https://uploads.github.com/repos/$SLUG/releases/$RELEASE_ID/assets?name=$ASSET_NAME" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("==> Published:", d.get("browser_download_url") or d)'
