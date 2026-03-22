$repo = "rito1998/zig-wol"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"

$latestRelease = Invoke-RestMethod -Uri $apiUrl
$latestTag = $latestRelease.tag_name

switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64"  { $arch = "x86_64" }
    "ARM64"  { $arch = "aarch64" }
    default  {
        Write-Host "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)"
        exit 1
    }
}

$assetName = "zig-wol-$arch-windows.tar.gz"
$downloadUrl = "https://github.com/$repo/releases/download/$latestTag/$assetName"

$homeDir = [System.Environment]::GetFolderPath("UserProfile")
$installDir = "$homeDir\.zig-wol"
$tempTarGz = "$installDir\$assetName"

if (Test-Path $installDir) {
    Write-Host "Existing installation detected in: $installDir"
    $response = Read-Host "Do you want to proceed with a fresh install? Existing configurations will be lost. (y/n)"
    if ($response -ne "y") {
        Write-Host "Installation aborted."
        exit 0
    }
    Write-Host "Removing existing installation..."
    Remove-Item -Recurse -Force $installDir
}

Write-Host "Creating installation directory: $installDir"
New-Item -ItemType Directory -Path $installDir | Out-Null

Write-Host "Detected architecture: $arch"
Write-Host "Downloading latest release ($latestTag) from $downloadUrl..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempTarGz

Write-Host "Extracting archive..."
tar -xzf $tempTarGz -C $installDir

Remove-Item $tempTarGz

Write-Host "Installation completed! Files are in: $installDir"
Write-Host "To use 'zig-wol', consider adding '$installDir' to your PATH."

$response = Read-Host "Do you want to add $installDir to your PATH? (y/n)"
if ($response -eq "y") {
    $currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -notlike "*$installDir*") {
        $newPath = "$currentPath;$installDir"
        [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Host "Added $installDir to PATH. Restart your terminal or log out/in for changes to take effect."
    } else {
        Write-Host "$installDir is already in PATH."
    }
} else {
    Write-Host "To use 'zig-wol', manually add '$installDir' to your PATH."
}
