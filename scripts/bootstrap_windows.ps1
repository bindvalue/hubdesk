param(
    [switch]$SkipFlutter,
    [switch]$SkipVcpkgDeps
)

$ErrorActionPreference = 'Stop'

function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script in PowerShell as Administrator."
    }
}

function Install-WingetPackage($id) {
    Write-Host "Installing $id ..." -ForegroundColor Cyan
    winget install --id $id -e --accept-package-agreements --accept-source-agreements
}

function Ensure-Tool($toolName, $packageId) {
    if (Get-Command $toolName -ErrorAction SilentlyContinue) {
        Write-Host "$toolName already installed" -ForegroundColor Green
        return
    }
    Install-WingetPackage $packageId
}

function Add-PathIfMissing($pathToAdd) {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$pathToAdd*") {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$pathToAdd", 'Machine')
        Write-Host "Added to machine PATH: $pathToAdd" -ForegroundColor Green
    } else {
        Write-Host "PATH already contains: $pathToAdd" -ForegroundColor Green
    }
}

function Ensure-Vcpkg {
    $vcpkgRoot = 'C:\vcpkg'
    if (-not (Test-Path $vcpkgRoot)) {
        git clone https://github.com/microsoft/vcpkg $vcpkgRoot
    }

    & "$vcpkgRoot\bootstrap-vcpkg.bat"
    [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $vcpkgRoot, 'Machine')
    Write-Host "Set VCPKG_ROOT=$vcpkgRoot" -ForegroundColor Green

    if (-not $SkipVcpkgDeps) {
        & "$vcpkgRoot\vcpkg.exe" install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
    }
}

Ensure-Admin

Ensure-Tool git Git.Git
Ensure-Tool python Python.Python.3.12
Ensure-Tool cmake Kitware.CMake
Ensure-Tool rustup Rustlang.Rustup

# Visual Studio Build Tools (contains cl/msvc)
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    Install-WingetPackage Microsoft.VisualStudio.2022.BuildTools
}

if (-not $SkipFlutter) {
    $flutterRoot = 'C:\dev\flutter'
    if (-not (Test-Path $flutterRoot)) {
        New-Item -ItemType Directory -Force -Path 'C:\dev' | Out-Null
        git clone https://github.com/flutter/flutter.git -b stable $flutterRoot
    }
    Add-PathIfMissing "$flutterRoot\bin"
}

Ensure-Vcpkg

Write-Host "Bootstrap completed. Close/reopen terminal, then run scripts/validate_env.ps1" -ForegroundColor Green
