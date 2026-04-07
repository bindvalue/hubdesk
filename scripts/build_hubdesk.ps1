$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$RequiredFlutterVersion = '3.24.5'
Push-Location $RepoRoot

# Normalize current session PATH/VCPKG from persisted values.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = "$machinePath;$userPath"
    } else {
        $env:Path = $machinePath
    }
}
if ([string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
    $machineVcpkg = [Environment]::GetEnvironmentVariable('VCPKG_ROOT', 'Machine')
    if (-not [string]::IsNullOrWhiteSpace($machineVcpkg)) {
        $env:VCPKG_ROOT = $machineVcpkg
    }
}

function Import-VsDevEnv {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio Build Tools."
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        throw "Visual Studio Build Tools with C++ workload not found."
    }

    $vsDevCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        throw "VsDevCmd.bat not found at $vsDevCmd"
    }

    # Import toolchain variables (INCLUDE/LIB/WindowsSdkDir/etc.) into this PowerShell session.
    $cmdLine = ('"{0}" -arch=x64 -host_arch=x64 >nul && set' -f $vsDevCmd)
    $envDump = & cmd.exe /s /c $cmdLine
    foreach ($line in $envDump) {
        if ($line -match '^(.*?)=(.*)$') {
            Set-Item -Path ("Env:{0}" -f $matches[1]) -Value $matches[2]
        }
    }
}

function Get-FlutterVersion {
    try {
        $raw = (& flutter --version 2>&1 | Out-String)
        $m = [regex]::Match($raw, 'Flutter\s+([0-9]+\.[0-9]+\.[0-9]+)')
        if ($m.Success) {
            return $m.Groups[1].Value
        }
    } catch {}
    return $null
}

function Test-SymlinkSupport {
    $probeRoot = Join-Path $env:TEMP "hubdesk_symlink_probe"
    $probeTarget = Join-Path $probeRoot "target.txt"
    $probeLink = Join-Path $probeRoot "link.txt"
    try {
        if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot }
        New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
        Set-Content -Path $probeTarget -Value "probe" -Encoding ASCII
        New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        try { if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot } } catch {}
    }
}

$PythonExe = "python"
try {
    $pyCheck = (& python --version 2>&1 | Out-String)
    if ($pyCheck -match 'Python was not found|Python n') {
        $PythonExe = "py"
    }
} catch {
    $PythonExe = "py"
}

# bindgen/hwcodec needs libclang.dll
if ([string]::IsNullOrWhiteSpace($env:LIBCLANG_PATH)) {
    $libclangCandidates = @(
        'C:\\Program Files\\LLVM\\bin',
        'C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin',
        'C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin'
    )
    foreach ($d in $libclangCandidates) {
        if (Test-Path (Join-Path $d 'libclang.dll')) {
            $env:LIBCLANG_PATH = $d
            break
        }
    }
}

$preferredVcpkgRoot = $env:VCPKG_ROOT
Import-VsDevEnv
if (-not [string]::IsNullOrWhiteSpace($preferredVcpkgRoot)) {
    $env:VCPKG_ROOT = $preferredVcpkgRoot
}
if ([string]::IsNullOrWhiteSpace($env:INCLUDE) -or [string]::IsNullOrWhiteSpace($env:LIB)) {
    Pop-Location
    throw "MSVC environment not initialized (INCLUDE/LIB missing)."
}

$flutterVersion = Get-FlutterVersion
if ([string]::IsNullOrWhiteSpace($flutterVersion)) {
    Pop-Location
    throw "Unable to detect Flutter SDK version. Ensure flutter is installed and in PATH."
}
if ($flutterVersion -ne $RequiredFlutterVersion) {
    Pop-Location
    throw "Incompatible Flutter SDK version $flutterVersion detected. Required version is $RequiredFlutterVersion for this repository. Run scripts/bootstrap_windows.ps1 to align Flutter and retry."
}
if (-not (Test-SymlinkSupport)) {
    Pop-Location
    throw "Symlink support is required for Flutter Windows plugins. Enable Windows Developer Mode and retry."
}

$staticFfmpegHeader = Join-Path $env:VCPKG_ROOT "installed\x64-windows-static\include\libavutil\pixfmt.h"
$enableHwcodec = Test-Path $staticFfmpegHeader
$enableVram = $enableHwcodec
if (-not $enableHwcodec) {
    Write-Host "Static ffmpeg headers not found; building without --hwcodec and --vram." -ForegroundColor Yellow
}

Write-Host "Validating environment..." -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File (Join-Path $ScriptDir "validate_env.ps1")
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    throw "Environment is not ready. Run scripts/bootstrap_windows.ps1 as Administrator first."
}

if (-not (Test-Path "custom_client.json")) {
    Pop-Location
    throw "custom_client.json not found in repository root."
}

Write-Host "Updating submodules..." -ForegroundColor Cyan
git submodule update --init --recursive

Write-Host "Fetching Flutter dependencies..." -ForegroundColor Cyan
Push-Location flutter
flutter pub get
Pop-Location

Write-Host "Building HubDesk (Flutter Windows)..." -ForegroundColor Cyan
$buildArgs = @('.\build.py', '--portable', '--flutter', '--skip-portable-pack')
if ($enableHwcodec) {
    $buildArgs += '--hwcodec'
}
if ($enableVram) {
    $buildArgs += '--vram'
}

if ($PythonExe -eq "py") {
    & py -3 @buildArgs
} else {
    & python @buildArgs
}

$releaseDir = "flutter\build\windows\x64\runner\Release"
if (-not (Test-Path $releaseDir)) {
    Pop-Location
    throw "Build output not found at $releaseDir"
}

Copy-Item -Force .\custom_client.json "$releaseDir\custom_client.json"

Write-Host "Build completed successfully." -ForegroundColor Green
Write-Host "Output: $releaseDir" -ForegroundColor Green
Write-Host "Config copied: $releaseDir\custom_client.json" -ForegroundColor Green

Pop-Location
