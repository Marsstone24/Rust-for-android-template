#!/usr/bin/env bash
# install.sh - one-shot setup for a Rust (macroquad/miniquad) -> Android project.
#
# What it does (all steps are idempotent, safe to re-run):
#   1. checks system tools (java 17+, curl, unzip, python3, rustup/cargo)
#   2. installs Rust android targets + cargo-ndk
#   3. installs Android SDK cmdline-tools, platform, build-tools, NDK
#   4. writes env vars into ~/.bashrc (managed block, removed by uninstall.sh)
#   5. generates ./android (Gradle project) using the Java files shipped with miniquad
#   6. creates the Gradle wrapper
#   7. optionally creates a release keystore + ~/.gradle/gradle.properties entries
#   8. writes a ./compile script that builds the release APK
#
# Configure through environment variables, e.g.:
#   PACKAGE=com.me.mygame ABIS="arm64-v8a x86_64" ./install.sh

set -euo pipefail

# ----------------------------- configuration -------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
PLATFORM="${PLATFORM:-35}"
BUILD_TOOLS="${BUILD_TOOLS:-35.0.0}"
AGP_VERSION="${AGP_VERSION:-8.7.3}"
GRADLE_VERSION="${GRADLE_VERSION:-8.9}"
CMDLINE_TOOLS_BUILD="${CMDLINE_TOOLS_BUILD:-11076708}"
ABIS="${ABIS:-arm64-v8a}"                       # space separated: arm64-v8a x86_64 ...
KEYSTORE_DIR="${KEYSTORE_DIR:-$HOME/.android/keystores}"

MARK_BEGIN="# >>> rust-android >>>"
MARK_END="# <<< rust-android <<<"

# ------------------------------- helpers -----------------------------------
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. $2"; }
setup_cargo() {
  info "Cargo.toml not found! Setting up project..."
  cargo init 
  cargo add macroquad
  rm src/main.rs
  cat > src/lib.rs <<'EOF'
use macroquad::prelude::*;

async fn entry() {
    loop {
        clear_background(DARKBLUE);
        draw_text("Hello from Rust on Android!", 40.0, 80.0, 40.0, WHITE);
        next_frame().await
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn quad_main() {
    macroquad::Window::new("Hello", entry());
}
EOF
}

abi_to_triple() {
  case "$1" in
    arm64-v8a)   echo aarch64-linux-android ;;
    armeabi-v7a) echo armv7-linux-androideabi ;;
    x86_64)      echo x86_64-linux-android ;;
    x86)         echo i686-linux-android ;;
    *) die "Unknown ABI: $1" ;;
  esac
}

# ---------------------------- 1. prerequisites -----------------------------
info "Checking prerequisites"
need curl    "Debian/Ubuntu: sudo apt install curl"
need unzip   "Debian/Ubuntu: sudo apt install unzip"
need python3 "Debian/Ubuntu: sudo apt install python3"
need cargo   "Install Rust first: https://rustup.rs"
need rustup  "Install Rust first: https://rustup.rs"
need java    "Debian/Ubuntu: sudo apt install openjdk-17-jdk"
need keytool "Install a full JDK: sudo apt install openjdk-17-jdk"
[ -f Cargo.toml ] || setup_cargo

JAVA_MAJOR="$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+)(\.[0-9]+)*.*/\1/')"
[ "${JAVA_MAJOR:-0}" -ge 17 ] || die "JDK 17+ required (found $JAVA_MAJOR). Debian/Ubuntu: sudo apt install openjdk-17-jdk"

CRATE_NAME="$(sed -n 's/^name *= *"\(.*\)"/\1/p' Cargo.toml | head -1)"
[ -n "$CRATE_NAME" ] || die "Could not read package name from Cargo.toml"
LIB_NAME="$(echo "$CRATE_NAME" | tr '-' '_')"
PACKAGE="${PACKAGE:-com.example.$LIB_NAME}"
APP_LABEL="${APP_LABEL:-$CRATE_NAME}"
PACKAGE_PATH="${PACKAGE//./\/}"
info "Crate: $CRATE_NAME  | lib: lib$LIB_NAME.so  | Android package: $PACKAGE"

# ------------------------- 2. rust targets + cargo-ndk ---------------------
info "Installing Rust Android targets"
TRIPLES=()
for abi in $ABIS; do TRIPLES+=("$(abi_to_triple "$abi")"); done
rustup target add "${TRIPLES[@]}"

if ! command -v cargo-ndk >/dev/null 2>&1; then
  info "Installing cargo-ndk"
  cargo install cargo-ndk
else
  info "cargo-ndk already installed"
fi

# ------------------------- 3. Android SDK + NDK ----------------------------
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
if [ ! -x "$SDKMANAGER" ]; then
  info "Installing Android cmdline-tools into $ANDROID_HOME"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  TMP="$(mktemp -d)"
  curl -fL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip" -o "$TMP/cmdline.zip"
  unzip -q "$TMP/cmdline.zip" -d "$TMP"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$TMP/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$TMP"
fi

info "Accepting SDK licenses"
set +o pipefail
yes | "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
set -o pipefail

PKGS=()
[ -d "$ANDROID_HOME/platform-tools" ]                || PKGS+=("platform-tools")
[ -d "$ANDROID_HOME/platforms/android-$PLATFORM" ]   || PKGS+=("platforms;android-$PLATFORM")
[ -d "$ANDROID_HOME/build-tools/$BUILD_TOOLS" ]      || PKGS+=("build-tools;$BUILD_TOOLS")
[ -d "$ANDROID_HOME/ndk/$NDK_VERSION" ]              || PKGS+=("ndk;$NDK_VERSION")
if [ "${#PKGS[@]}" -gt 0 ]; then
  info "Installing SDK packages: ${PKGS[*]}"
  "$SDKMANAGER" --sdk_root="$ANDROID_HOME" "${PKGS[@]}"
else
  info "All SDK packages already present"
fi

export ANDROID_HOME
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$NDK_VERSION"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"

# ------------------------- 4. shell environment ----------------------------
if ! grep -qF "$MARK_BEGIN" "$HOME/.bashrc" 2>/dev/null; then
  info "Adding environment variables to ~/.bashrc"
  cat >> "$HOME/.bashrc" <<EOF

$MARK_BEGIN
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_NDK_HOME"
export ANDROID_NDK_ROOT="\$ANDROID_NDK_HOME"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"
$MARK_END
EOF
else
  info "~/.bashrc already configured"
fi

# ------------------------- 5. cargo project fixes --------------------------
info "Checking Cargo.toml"
if ! grep -q 'cdylib' Cargo.toml; then
  if grep -q '^\[lib\]' Cargo.toml; then
    warn "Cargo.toml has a [lib] section without cdylib. Add: crate-type = [\"cdylib\"]"
  else
    printf '\n[lib]\ncrate-type = ["cdylib"]\n' >> Cargo.toml
    info "Added [lib] crate-type = [\"cdylib\"] to Cargo.toml"
  fi
fi
[ -f src/lib.rs ] || warn "src/lib.rs not found - Android needs the entry point in a library crate."

info "Locating miniquad's Java sources (cargo metadata)"
MINIQUAD_MANIFEST="$(cargo metadata --format-version 1 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(next((p["manifest_path"] for p in d["packages"] if p["name"] == "miniquad"), ""))
')"
[ -n "$MINIQUAD_MANIFEST" ] || die "miniquad is not in your dependency tree. Run: cargo add macroquad"
MINIQUAD_JAVA="$(dirname "$MINIQUAD_MANIFEST")/java"
[ -f "$MINIQUAD_JAVA/MainActivity.java" ] || die "MainActivity.java not found in $MINIQUAD_JAVA"

# ------------------------- 6. Gradle project -------------------------------
info "Generating ./android project"
JAVA_DIR="android/app/src/main/java"
mkdir -p "$JAVA_DIR/$PACKAGE_PATH"
cp -r "$MINIQUAD_JAVA/." "$JAVA_DIR/"
mv -f "$JAVA_DIR/MainActivity.java" "$JAVA_DIR/$PACKAGE_PATH/MainActivity.java"
sed -i "s/TARGET_PACKAGE_NAME/$PACKAGE/; s/LIBRARY_NAME/$LIB_NAME/" "$JAVA_DIR/$PACKAGE_PATH/MainActivity.java"

ABI_FILTERS=""
for abi in $ABIS; do ABI_FILTERS+="\"$abi\", "; done
ABI_FILTERS="${ABI_FILTERS%, }"

cat > android/settings.gradle <<EOF
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "$CRATE_NAME"
include ':app'
EOF

cat > android/build.gradle <<EOF
plugins {
    id 'com.android.application' version '$AGP_VERSION' apply false
}
EOF

echo "sdk.dir=$ANDROID_HOME" > android/local.properties
echo "org.gradle.jvmargs=-Xmx2g" > android/gradle.properties

cat > android/app/build.gradle <<EOF
plugins { id 'com.android.application' }

android {
    namespace '$PACKAGE'
    compileSdk $PLATFORM
    buildToolsVersion "$BUILD_TOOLS"

    defaultConfig {
        applicationId "$PACKAGE"
        minSdk 23
        targetSdk $PLATFORM
        versionCode 1
        versionName "0.1.0"
        ndk { abiFilters $ABI_FILTERS }
    }

    // Signing values come from ~/.gradle/gradle.properties (created by install.sh)
    if (project.hasProperty('RELEASE_STORE_FILE')) {
        signingConfigs {
            release {
                storeFile file(RELEASE_STORE_FILE)
                storePassword RELEASE_STORE_PASSWORD
                keyAlias RELEASE_KEY_ALIAS
                keyPassword RELEASE_KEY_PASSWORD
            }
        }
    }

    buildTypes {
        release {
            minifyEnabled false
            if (project.hasProperty('RELEASE_STORE_FILE')) {
                signingConfig signingConfigs.release
            }
        }
    }
}
EOF

cat > android/app/src/main/AndroidManifest.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-feature android:glEsVersion="0x00020000" android:required="true" />
    <application android:label="$APP_LABEL" android:hasCode="true">
        <activity android:name=".MainActivity"
            android:exported="true"
            android:configChanges="orientation|screenSize|keyboardHidden">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# ------------------------- 7. Gradle wrapper -------------------------------
if [ ! -x android/gradlew ]; then
  info "Creating Gradle wrapper ($GRADLE_VERSION)"
  GTMP="$(mktemp -d)"
  trap 'rm -rf "$GTMP"' EXIT
  curl -fL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o "$GTMP/gradle.zip"
  unzip -q "$GTMP/gradle.zip" -d "$GTMP"
  (cd android && "$GTMP/gradle-${GRADLE_VERSION}/bin/gradle" wrapper --gradle-version "$GRADLE_VERSION")
else
  info "Gradle wrapper already exists"
fi

# ------------------------- 8. signing keystore -----------------------------
GRADLE_PROPS="$HOME/.gradle/gradle.properties"
KEYSTORE="$KEYSTORE_DIR/$CRATE_NAME-release.keystore"

if grep -q '^RELEASE_STORE_FILE=' "$GRADLE_PROPS" 2>/dev/null; then
  info "Release signing already configured in $GRADLE_PROPS"
elif [ -t 0 ]; then
  read -r -p "Create a release keystore for signing? [Y/n] " ans
  if [[ "${ans:-Y}" =~ ^[Yy]$ ]]; then
    mkdir -p "$KEYSTORE_DIR" "$HOME/.gradle"
    if [ -f "$KEYSTORE" ]; then
      info "Keystore $KEYSTORE already exists, reusing it"
    fi
    read -r -s -p "Keystore password (min 6 chars): " KSPASS; echo
    [ "${#KSPASS}" -ge 6 ] || die "Password too short."
    if [ ! -f "$KEYSTORE" ]; then
      keytool -genkeypair -v -keystore "$KEYSTORE" -alias "$CRATE_NAME" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$KSPASS" -keypass "$KSPASS" \
        -dname "CN=$CRATE_NAME, O=Personal, C=XX"
    fi
    {
      echo "RELEASE_STORE_FILE=$KEYSTORE"
      echo "RELEASE_STORE_PASSWORD=$KSPASS"
      echo "RELEASE_KEY_ALIAS=$CRATE_NAME"
      echo "RELEASE_KEY_PASSWORD=$KSPASS"
    } >> "$GRADLE_PROPS"
    chmod 600 "$GRADLE_PROPS"
    warn "BACK UP $KEYSTORE - you cannot update your app later without it."
  fi
else
  warn "Non-interactive shell: skipping keystore. Release APK will be unsigned."
fi

# ------------------------- 9. compile script -------------------------------
if [ ! -f compile ]; then
  info "Writing ./compile"
  cat > compile <<'EOF'
#!/usr/bin/env bash
# generated by install.sh
set -euo pipefail
cd "$(dirname "$0")"

export ANDROID_HOME="${ANDROID_HOME:-@ANDROID_HOME@}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-@ANDROID_NDK_HOME@}"
NDK_TARGETS=(@NDK_TARGETS@)

DEBUG=false
RELEASE=false

help() {
  cat <<'HELP'

USAGE:
  ./compile [options]

Options (short flags can be combined, e.g. -rd):
  -h | --help      show this list
  -d | --debug     compile debug apk (default)
  -r | --release   compile release apk

HELP
}

# translate long options to short ones so getopts can handle everything
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --help)    ARGS+=("-h") ;;
    --debug)   ARGS+=("-d") ;;
    --release) ARGS+=("-r") ;;
    *)         ARGS+=("$arg") ;;
  esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
  printf "\nNo arguments, compiling debug apk as default.\n"
  printf "Look up -h or --help to see options.\n\n"
  sleep 4
  ARGS+=("-d")
fi

set -- "${ARGS[@]}"

while getopts "hdr" opt; do
  case "$opt" in
    h) help; exit 0 ;;
    d) DEBUG=true ;;
    r) RELEASE=true ;;
    *) echo "Invalid option given, see help with -h or --help" >&2; exit 1 ;;
  esac
done

if $DEBUG; then
  cargo ndk "${NDK_TARGETS[@]}" -o android/app/src/debug/jniLibs build
  (cd android && ./gradlew assembleDebug)
  echo "Debug APK:   android/app/build/outputs/apk/debug/app-debug.apk"
fi
if $RELEASE; then
  cargo ndk "${NDK_TARGETS[@]}" -o android/app/src/release/jniLibs build --release
  (cd android && ./gradlew assembleRelease)
  echo "Release APK: android/app/build/outputs/apk/release/app-release.apk"
fi
EOF
  NDK_TARGETS=""
  for abi in $ABIS; do NDK_TARGETS+="-t $abi "; done
  sed -i "s|@ANDROID_HOME@|$ANDROID_HOME|; s|@ANDROID_NDK_HOME@|$ANDROID_NDK_HOME|; s|@NDK_TARGETS@|$NDK_TARGETS|" compile
  chmod +x compile
else
  info "./compile already exists, leaving it alone"
fi
# ------------------------- 10. .gitignore ----------------------------------
touch .gitignore
for line in "/target" "android/.gradle/" "android/app/build/" "android/local.properties" "android/app/src/*/jniLibs/"; do
  grep -qxF "$line" .gitignore || echo "$line" >> .gitignore
done

cat <<EOF

Done!

  Open a new terminal (or: source ~/.bashrc), then build with:

      ./compile

  Look up option flags of ./compile with ./compile -h

  Install on a connected phone:

      adb install -r android/app/build/outputs/apk/release/app-release.apk
      adb install -r android/app/build/outputs/apk/debug/app-debug.apk
      adb logcat -s SAPP RustStdoutStderr AndroidRuntime DEBUG

EOF