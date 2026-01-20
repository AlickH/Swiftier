#!/bin/bash
set -e

# Configuration
CRATE_DIR="EasyTierCore"
OUTPUT_LIB_NAME="libeasytier_ios.a" # Matches what Xcode expects (keeping ios name for compat)
FINAL_FAT_LIB_path="EasyTierCore/target/universal/release/$OUTPUT_LIB_NAME"

# Ensure Environment is Loaded
if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env"
elif [ -f "$HOME/.bash_profile" ]; then
    source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc"
fi

# Fallback explicit Export
export PATH="$HOME/.cargo/bin:$PATH"

# Set deployment target to avoid linker warnings (built for newer macOS)
export MACOSX_DEPLOYMENT_TARGET=13.0

echo "🚀 Starting Universal Rust Build..."
echo "Using cargo: $(which cargo)"

# 1. Ensure Rust targets are installed
echo "Checking/Installing Rust targets..."
rustup target add aarch64-apple-darwin
rustup target add x86_64-apple-darwin

# 2. Build for ARM64 (Apple Silicon)
echo "----------------------------------------"
echo "🛠️ Building for arm64 (aarch64-apple-darwin)..."
cd "$CRATE_DIR"
cargo build --release --target aarch64-apple-darwin
cd ..

# 3. Build for x86_64 (Intel)
echo "----------------------------------------"
echo "🛠️ Building for x86_64 (x86_64-apple-darwin)..."
cd "$CRATE_DIR"
cargo build --release --target x86_64-apple-darwin
cd ..

# 4. Create Directory for Universal Lib
mkdir -p "$CRATE_DIR/target/universal/release"

# 5. Fuse architectures with lipo
echo "----------------------------------------"
echo "🔗 Creating Universal Binary (Lipo)..."
lipo -create -output "$FINAL_FAT_LIB_path" \
    "$CRATE_DIR/target/aarch64-apple-darwin/release/$OUTPUT_LIB_NAME" \
    "$CRATE_DIR/target/x86_64-apple-darwin/release/$OUTPUT_LIB_NAME"

echo "✅ Universal Library created at: $FINAL_FAT_LIB_path"
echo "ℹ️  Architectures in library:"
lipo -info "$FINAL_FAT_LIB_path"

# 6. Copy to the location Xcode expects linked
mkdir -p "$CRATE_DIR/target/release"
cp "$FINAL_FAT_LIB_path" "$CRATE_DIR/target/release/$OUTPUT_LIB_NAME"

echo "🎉 Done! The fat library is ready and supports Any Mac (arm64, x86_64)."
