#!/bin/bash
# =============================================================================
# Zed Custom Build Script
# Builds Zed from source with MCP timeout fix + auto-update disabled
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ZED_REPO="$(cd "$(dirname "$0")" && pwd)"
OFFICIAL_ZED="/Applications/Zed.app"
INSTALL_DIR="/Applications/Zed Custom.app"

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ── Step 1: Check Xcode ──────────────────────────────────────────────────────
check_xcode() {
    info "Checking build environment..."
    # This custom build uses runtime_shaders feature — no Xcode/Metal compiler needed.
    # Only Xcode Command Line Tools are required.
    if xcrun --find cc &>/dev/null; then
        ok "Build environment ready (runtime_shaders enabled, no Xcode needed)"
    else
        info "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        ok "Command Line Tools installed"
    fi
}

# ── Step 2: Check Rust ───────────────────────────────────────────────────────
check_rust() {
    info "Checking Rust toolchain..."

    if ! command -v rustup &>/dev/null; then
        info "Installing rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi

    source "$HOME/.cargo/env"

    local required_toolchain
    required_toolchain=$(grep 'channel' "$ZED_REPO/rust-toolchain.toml" | sed 's/channel = "\(.*\)"/\1/')
    info "Required toolchain: $required_toolchain"

    if ! rustup toolchain list | grep -q "$required_toolchain"; then
        info "Installing toolchain $required_toolchain..."
        rustup install "$required_toolchain"
    fi

    ok "Rust toolchain ready ($(rustc --version))"
}

# ── Step 3: Check cmake ──────────────────────────────────────────────────────
check_cmake() {
    if ! command -v cmake &>/dev/null; then
        info "Installing cmake via brew..."
        command -v brew &>/dev/null || fail "Homebrew not found. Install cmake manually."
        brew install cmake
    fi
    ok "cmake ready"
}

# ── Step 4: Build ────────────────────────────────────────────────────────────
build_zed() {
    info "Building Zed (release mode)..."
    info "This will take 10-30 minutes depending on your machine."
    echo ""

    cd "$ZED_REPO"
    source "$HOME/.cargo/env"

    # webrtc-sys downloads a ~242MB prebuilt WebRTC binary from GitHub at build
    # time; its bundled HTTP client (rustls) rejects the GitHub cert on some
    # setups ("invalid peer certificate: UnknownIssuer"), breaking the build.
    # If a prebuilt archive is present at ~/webrtc-prebuilt/mac-arm64-release,
    # use it via LK_CUSTOM_WEBRTC and skip the download entirely.
    WEBRTC_CUSTOM="$HOME/webrtc-prebuilt/mac-arm64-release"
    if [ -d "$WEBRTC_CUSTOM" ]; then
        export LK_CUSTOM_WEBRTC="$WEBRTC_CUSTOM"
        info "Using local WebRTC prebuilt (LK_CUSTOM_WEBRTC) — skipping download"
    fi

    cargo build --release -p zed

    if [ ! -f "$ZED_REPO/target/release/zed" ]; then
        fail "Build failed - binary not found at target/release/zed"
    fi

    local bin_size
    bin_size=$(du -h "$ZED_REPO/target/release/zed" | cut -f1)
    ok "Build complete (binary: $bin_size)"
}

# ── Step 5: Create .app bundle ───────────────────────────────────────────────
create_app_bundle() {
    info "Creating application bundle..."

    local bundle_dir="$ZED_REPO/target/release/Zed Custom.app"

    # Clean old bundle
    rm -rf "$bundle_dir"

    if [ -d "$OFFICIAL_ZED" ]; then
        info "Copying bundle structure from official Zed..."
        cp -R "$OFFICIAL_ZED" "$bundle_dir"

        # Replace binary with our custom build
        cp "$ZED_REPO/target/release/zed" "$bundle_dir/Contents/MacOS/zed"
        chmod +x "$bundle_dir/Contents/MacOS/zed"

        # Also copy cli helper if it exists in our build
        if [ -f "$ZED_REPO/target/release/cli" ]; then
            cp "$ZED_REPO/target/release/cli" "$bundle_dir/Contents/MacOS/cli"
            chmod +x "$bundle_dir/Contents/MacOS/cli"
        fi

        # Patch Info.plist to distinguish from official
        local plist="$bundle_dir/Contents/Info.plist"
        if [ -f "$plist" ]; then
            sed -i '' 's/<string>dev.zed.Zed<\/string>/<string>dev.zed.custom<\/string>/' "$plist"
            sed -i '' 's/<string>Zed<\/string>/<string>Zed Custom<\/string>/' "$plist"
            sed -i '' 's/<key>CFBundleDisplayName<\/key>/<key>CFBundleDisplayName<\/key>/' "$plist"
        fi
    else
        warn "Official Zed not found at $OFFICIAL_ZED"
        info "Creating minimal bundle from scratch..."

        local contents="$bundle_dir/Contents"
        local macos="$contents/MacOS"
        local resources="$contents/Resources"

        mkdir -p "$macos" "$resources"

        cp "$ZED_REPO/target/release/zed" "$macos/Zed"
        chmod +x "$macos/Zed"

        cat > "$contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Zed</string>
    <key>CFBundleIdentifier</key>
    <string>dev.zed.custom</string>
    <key>CFBundleName</key>
    <string>Zed Custom</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1-custom</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15.7</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
    fi

    # Remove quarantine and code signature issues
    xattr -cr "$bundle_dir" 2>/dev/null || true

    ok "App bundle: $bundle_dir"
}

# ── Step 6: Install ──────────────────────────────────────────────────────────
install_zed() {
    local bundle_dir="$ZED_REPO/target/release/Zed Custom.app"

    if [ ! -d "$bundle_dir" ]; then
        fail "App bundle not found. Run: $0 build"
    fi

    info "Installing to $INSTALL_DIR..."

    # Quit running instance
    pkill -f "Zed Custom" 2>/dev/null || true
    sleep 1

    # Remove old installation
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi

    # Copy to Applications
    cp -R "$bundle_dir" "$INSTALL_DIR"
    xattr -cr "$INSTALL_DIR" 2>/dev/null || true

    ok "Installed: $INSTALL_DIR"
}

# ── Step 7: Run ──────────────────────────────────────────────────────────────
run_zed() {
    if [ ! -d "$INSTALL_DIR" ]; then
        fail "Not installed. Run: $0 all"
    fi
    open "$INSTALL_DIR"
}

# ── Step 8: Cleanup build artifacts ───────────────────────────────────────────
# After install, target/ is pure dead weight (binary already copied into the .app).
# Override with KEEP_TARGET=1 to keep it for fast incremental rebuilds.
cleanup_target() {
    if [ "${KEEP_TARGET:-0}" = "1" ]; then
        warn "KEEP_TARGET=1 set — keeping target/ for incremental builds"
        return 0
    fi

    local target_dir="$ZED_REPO/target"
    if [ ! -d "$target_dir" ]; then
        info "No target/ to clean."
        return 0
    fi

    local target_size
    target_size=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
    info "Removing target/ ($target_size) — binary is already in '$INSTALL_DIR'..."
    rm -rf "$target_dir"
    ok "Freed $target_size. target/ removed."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  Zed Custom Build"
    echo "  MCP timeout fix + auto-update disabled"
    echo "═══════════════════════════════════════════════════"
    echo "  Branch: custom/mcp-fix"
    echo "  Repo:   $ZED_REPO"
    echo ""

    local step="${1:-all}"

    case "$step" in
        check)
            check_xcode
            check_rust
            check_cmake
            ;;
        build)
            check_xcode
            check_rust
            check_cmake
            build_zed
            create_app_bundle
            ;;
        install)
            install_zed
            ;;
        run)
            run_zed
            ;;
        clean)
            info "Cleaning build artifacts..."
            cd "$ZED_REPO"
            source "$HOME/.cargo/env"
            cargo clean
            ok "Cleaned"
            ;;
        rebuild)
            # Quick rebuild (skip checks, just build + install + cleanup)
            build_zed
            create_app_bundle
            install_zed
            cleanup_target
            ;;
        all)
            check_xcode
            check_rust
            check_cmake
            build_zed
            create_app_bundle
            install_zed
            cleanup_target
            echo ""
            ok "Done! Launch with: open '$INSTALL_DIR'"
            echo "  Or: $0 run"
            ;;
        *)
            echo "Usage: $0 {check|build|install|run|clean|rebuild|all}"
            echo ""
            echo "  check   - Verify prerequisites (Xcode, Rust, cmake)"
            echo "  build   - Full build + create app bundle"
            echo "  install - Copy app bundle to /Applications"
            echo "  run     - Launch installed app"
            echo "  clean   - Remove build artifacts (cargo clean)"
            echo "  rebuild - Quick: build + bundle + install + cleanup (no checks)"
            echo "  all     - Check + Build + Install + cleanup (default)"
            echo ""
            echo "Env:"
            echo "  KEEP_TARGET=1   Skip target/ cleanup (for fast incremental rebuilds)"
            exit 1
            ;;
    esac
}

main "${1:-all}"
