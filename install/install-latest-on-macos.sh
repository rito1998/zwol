#!/bin/bash

repo="rito1998/zig-wol"
apiUrl="https://api.github.com/repos/$repo/releases/latest"

latestRelease=$(curl -s $apiUrl)
latestTag=$(echo "$latestRelease" | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

arch=$(uname -m)
case "$arch" in
    arm64) arch="aarch64" ;;
    x86_64) arch="x86_64" ;;
    *) echo "Unsupported architecture: $arch"; exit 1 ;;
esac

assetName="zig-wol-$arch-macos.tar.gz"
downloadUrl="https://github.com/$repo/releases/download/$latestTag/$assetName"

homeDir=$HOME
installDir="$homeDir/.zig-wol"
tempTar="$installDir/$assetName"

if [ -d "$installDir" ]; then
    echo "Existing installation detected in: $installDir"
    read -p "Do you want to proceed with a fresh install? Existing configurations will be lost. (y/n): " response
    
    if [ "$response" != "y" ]; then
        echo "Installation aborted."
        exit 0
    fi
    echo "Removing existing installation..."
    rm -rf "$installDir"
fi

echo "Creating installation directory: $installDir"
mkdir -p "$installDir"

echo "Detected architecture: $arch"
echo "Downloading latest release ($latestTag) from $downloadUrl..."
curl -L "$downloadUrl" -o "$tempTar"

echo "Extracting archive..."
tar -xzvf "$tempTar" -C "$installDir" --strip-components=1

rm "$tempTar"

echo "Installation completed! Files are in: $installDir"

if [[ $SHELL == *zsh ]]; then
    shellrc="$HOME/.zshrc"
else
    shellrc="$HOME/.bashrc"
fi

if ! echo "$PATH" | grep -q "$installDir"; then
    read -p "Do you want to add $installDir to your PATH in $shellrc? (y/n): " response
    if [ "$response" == "y" ]; then
        echo "Adding $installDir to PATH..."

        if ! grep -q "$installDir" "$shellrc"; then
            echo -e "\n# zig-wol" >> "$shellrc"
            echo "export PATH=\"$installDir:\$PATH\"" >> "$shellrc"
            echo "Added $installDir to PATH. Restart your terminal or run 'source $shellrc' to update your PATH."
        else
            echo "$installDir is already in $shellrc."
        fi
    else
        echo "To use 'zig-wol', manually add '$installDir' to your PATH."
    fi
else
    echo "$installDir is already in PATH."
fi
