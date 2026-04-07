param(
    [switch]$SkipFlutter,
    [switch]$SkipVcpkgDeps
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$RequiredFlutterVersion = '3.24.5'

function Ensure-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script in PowerShell as Administrator."
    }
}

function Install-WingetPackage($id) {
    Write-Host "Installing $id ..." -ForegroundColor Cyan
    $out = winget install --id $id -e --accept-package-agreements --accept-source-agreements 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        # winget may return non-zero even when package is already installed/up to date.
        $installedOut = winget list --id $id 2>&1 | Out-String
        $alreadyInstalled = $installedOut -match [Regex]::Escape($id)
        if ($alreadyInstalled) {
            Write-Host "$id already installed and up to date" -ForegroundColor Green
            return
        }
        Write-Host $out
        throw "winget failed to install package: $id"
    }
}

function Add-SessionPathIfExists($pathToAdd) {
    if (Test-Path $pathToAdd) {
        if ($env:Path -notlike "*$pathToAdd*") {
            $env:Path = "$env:Path;$pathToAdd"
            Write-Host "Added to current session PATH: $pathToAdd" -ForegroundColor Green
        }
    }
}

function Ensure-Tool($toolName, $packageId) {
    if (Get-Command $toolName -ErrorAction SilentlyContinue) {
        if ($toolName -eq 'python') {
            try {
                $out = (& python --version 2>&1 | Out-String)
                if ($out -match 'Python was not found|Python n') {
                    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
                    if ($null -ne $pyCmd) {
                        try {
                            $pyOut = (& py -3 --version 2>&1 | Out-String)
                            if ($pyOut -match 'Python 3') {
                                Write-Host "python available via py launcher" -ForegroundColor Green
                                return
                            }
                        } catch {}
                    }
                    Install-WingetPackage $packageId
                    return
                }
            } catch {
                Install-WingetPackage $packageId
                return
            }
        } else {
            Write-Host "$toolName already installed" -ForegroundColor Green
            return
        }
    }
    Install-WingetPackage $packageId
}

function Ensure-VSBuildTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not [string]::IsNullOrWhiteSpace($installPath)) {
            Write-Host "Visual Studio Build Tools already installed" -ForegroundColor Green
            return
        }
    }
    Write-Host "Installing Visual Studio Build Tools with C++ workload ..." -ForegroundColor Cyan
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Visual Studio Build Tools with C++ workload"
    }
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
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to bootstrap vcpkg"
    }
    [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $vcpkgRoot, 'Machine')
    $env:VCPKG_ROOT = $vcpkgRoot
    Write-Host "Set VCPKG_ROOT=$vcpkgRoot" -ForegroundColor Green

    if (-not $SkipVcpkgDeps) {
        # RustDesk overlay port supports this fallback and CI relies on it in some setups.
        $env:USE_AOM_391 = '1'
        [Environment]::SetEnvironmentVariable('USE_AOM_391', '1', 'User')
        $manifestFile = Join-Path $RepoRoot "vcpkg.json"
        if (Test-Path $manifestFile) {
            Write-Host "Installing vcpkg dependencies using project manifest..." -ForegroundColor Cyan
            Push-Location $RepoRoot
            & "$vcpkgRoot\vcpkg.exe" install --triplet x64-windows-static --x-install-root "$vcpkgRoot\installed"
            $exitCode = $LASTEXITCODE
            Pop-Location
            if ($exitCode -ne 0) {
                throw "Failed to install vcpkg dependencies from manifest"
            }
        } else {
            Write-Host "Installing vcpkg dependencies using classic mode..." -ForegroundColor Cyan
            & "$vcpkgRoot\vcpkg.exe" install --classic libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to install vcpkg dependencies"
            }
        }
    }
}

Ensure-Admin

Ensure-Tool git Git.Git
Ensure-Tool python Python.Python.3.12
Ensure-Tool cmake Kitware.CMake
Ensure-Tool rustup Rustlang.Rustup
Ensure-Tool clang LLVM.LLVM

# Try to repair PATH in current session for newly installed tooling.
Add-SessionPathIfExists "C:\\Program Files\\CMake\\bin"
Add-SessionPathIfExists "$env:USERPROFILE\\.cargo\\bin"
Add-SessionPathIfExists "C:\\Program Files\\LLVM\\bin"

# bindgen/hwcodec requires libclang.dll
$libclangDir = "C:\\Program Files\\LLVM\\bin"
if (Test-Path (Join-Path $libclangDir "libclang.dll")) {
    [Environment]::SetEnvironmentVariable('LIBCLANG_PATH', $libclangDir, 'Machine')
    $env:LIBCLANG_PATH = $libclangDir
    Write-Host "Set LIBCLANG_PATH=$libclangDir" -ForegroundColor Green
} else {
    Write-Host "WARN: libclang.dll not found at $libclangDir" -ForegroundColor Yellow
}

# Visual Studio Build Tools (contains cl/msvc)
Ensure-VSBuildTools

if (-not $SkipFlutter) {
    $flutterRoot = 'C:\dev\flutter'
    if (-not (Test-Path $flutterRoot)) {
        New-Item -ItemType Directory -Force -Path 'C:\dev' | Out-Null
        git clone https://github.com/flutter/flutter.git -b $RequiredFlutterVersion $flutterRoot
    } else {
        Push-Location $flutterRoot
        git fetch --tags --quiet
        Pop-Location
    }
    Push-Location $flutterRoot
    git checkout $RequiredFlutterVersion
    if ($LASTEXITCODE -ne 0) {
        Pop-Location
        throw "Failed to checkout Flutter $RequiredFlutterVersion at $flutterRoot"
    }
    Pop-Location
    Write-Host "Flutter SDK pinned to $RequiredFlutterVersion" -ForegroundColor Green
    Add-PathIfMissing "$flutterRoot\bin"
    Add-SessionPathIfExists "$flutterRoot\bin"
}

Ensure-Vcpkg

Write-Host "Bootstrap completed. Close/reopen terminal, then run scripts/validate_env.ps1" -ForegroundColor Green
