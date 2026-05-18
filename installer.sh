#!/usr/bin/env bash
set -e

echo "Starting Sylvia installation..."

# Detect OS and Arch
OS="$(uname -s)"
ARCH="$(uname -m)"

TARGET=""

if [ "$OS" = "Linux" ]; then
    if [ "$ARCH" = "x86_64" ]; then
        TARGET="x86_64-linux-musl"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        TARGET="aarch64-linux-musl"
    fi
elif [ "$OS" = "Darwin" ]; then
    if [ "$ARCH" = "x86_64" ]; then
        TARGET="x86_64-macos"
    elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
        TARGET="aarch64-macos"
    fi
fi

if [ -z "$TARGET" ]; then
    echo "Error: Unsupported OS ($OS) or architecture ($ARCH)"
    exit 1
fi

echo "Detected target: $TARGET"

# Fetch latest release
echo "Fetching latest release from divijg19/sylvia..."
LATEST_RELEASE=$(curl -fsSL https://api.github.com/repos/divijg19/sylvia/releases/latest)
TAG_NAME=$(echo "$LATEST_RELEASE" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1)

if [ -z "$TAG_NAME" ]; then
    echo "Error: Failed to fetch latest version tag."
    exit 1
fi

echo "Latest version is $TAG_NAME"

DOWNLOAD_URL="https://github.com/divijg19/sylvia/releases/download/${TAG_NAME}/sylvia-${TAG_NAME}-${TARGET}.tar.gz"
TEMP_DIR=$(mktemp -d)

# Cleanup trap
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Downloading $DOWNLOAD_URL..."
if ! curl -fsSL "$DOWNLOAD_URL" -o "${TEMP_DIR}/sylvia.tar.gz"; then
    echo "Error: Failed to download Sylvia. Please verify the release exists for your target."
    exit 1
fi

echo "Extracting..."
tar -xzf "${TEMP_DIR}/sylvia.tar.gz" -C "$TEMP_DIR"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "Error: Root privileges required for installation to /usr/local/bin. Please run as root or install sudo."
        exit 1
    fi
fi

echo "Installing to /usr/local/bin/sylvia..."
$SUDO mv "${TEMP_DIR}/sylvia" /usr/local/bin/sylvia
$SUDO chmod +x /usr/local/bin/sylvia

echo "Sylvia $TAG_NAME installed successfully! Run 'sylvia help' to start."
