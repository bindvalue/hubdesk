$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "..")
$RequiredFlutterVersion = '3.24.5'

# Normalize current session PATH/VCPKG using persisted values.
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
        return $false
    }

    $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        return $false
    }

    $vsDevCmd = Join-Path $installPath "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        return $false
    }

    $cmdLine = ('"{0}" -arch=x64 -host_arch=x64 >nul && set' -f $vsDevCmd)
    $envDump = & cmd.exe /s /c $cmdLine
    foreach ($line in $envDump) {
        if ($line -match '^(.*?)=(.*)$') {
            Set-Item -Path ("Env:{0}" -f $matches[1]) -Value $matches[2]
        }
    }
    return $true
}

function Test-Tool($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        if ($name -eq 'python') {
            try {
                $out = (& python --version 2>&1 | Out-String)
                if ($out -match 'Python was not found|Python n') {
                    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
                    if ($null -ne $pyCmd) {
                        try {
                            $pyOut = (& py -3 --version 2>&1 | Out-String)
                            if ($pyOut -match 'Python 3') {
                                Write-Host "[OK] python => py -3 ($pyOut)" -ForegroundColor Green
                                return $true
                            }
                        } catch {}
                    }
                    Write-Host "[MISSING] python (Windows Store alias detected)" -ForegroundColor Yellow
                    return $false
                }
            } catch {
                Write-Host "[MISSING] python" -ForegroundColor Yellow
                return $false
            }
        }
        Write-Host "[OK] $name => $($cmd.Source)" -ForegroundColor Green
        return $true
    }
    Write-Host "[MISSING] $name" -ForegroundColor Yellow
    return $false
}

function Test-VSBuildTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Write-Host "[MISSING] Visual Studio Build Tools (vswhere not found)" -ForegroundColor Yellow
        return $false
    }
    $installPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($installPath)) {
        Write-Host "[MISSING] Visual Studio Build Tools (C++ tools not found)" -ForegroundColor Yellow
        return $false
    }
    Write-Host "[OK] MSVC Build Tools => $installPath" -ForegroundColor Green
    return $true
}

function Test-MsvcCompileEnv {
    $cl = Get-Command cl -ErrorAction SilentlyContinue
    if ($null -eq $cl) {
        Write-Host "[MISSING] cl.exe in current environment" -ForegroundColor Yellow
        return $false
    }

    $probeFile = Join-Path $env:TEMP "hubdesk_msvc_probe.cpp"
    $probeObj = Join-Path $env:TEMP "hubdesk_msvc_probe.obj"
    Set-Content -Path $probeFile -Value "#include <stdio.h>`nint main(){return 0;}" -Encoding ASCII
    & $cl.Source /nologo /c $probeFile *> $null
    $ok = ($LASTEXITCODE -eq 0)

    try { [System.IO.File]::Delete($probeFile) } catch {}
    try { [System.IO.File]::Delete($probeObj) } catch {}

    if ($ok) {
        Write-Host "[OK] MSVC include/lib environment initialized" -ForegroundColor Green
        return $true
    }

    Write-Host "[MISSING] MSVC include/lib environment (run via scripts/build_hubdesk.ps1)" -ForegroundColor Yellow
    return $false
}

function Test-Libclang {
    $candidates = @(
        $env:LIBCLANG_PATH,
        'C:\\Program Files\\LLVM\\bin',
        'C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin',
        'C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\Llvm\\x64\\bin'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($dir in $candidates) {
        if (Test-Path (Join-Path $dir 'libclang.dll')) {
            Write-Host "[OK] libclang => $dir" -ForegroundColor Green
            return $true
        }
    }
    Write-Host "[MISSING] libclang.dll (install LLVM and set LIBCLANG_PATH)" -ForegroundColor Yellow
    return $false
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

function Test-FlutterVersion {
    $current = Get-FlutterVersion
    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Host "[MISSING] could not detect Flutter version" -ForegroundColor Yellow
        return $false
    }
    if ($current -ne $RequiredFlutterVersion) {
        Write-Host "[MISSING] Flutter version $current (required: $RequiredFlutterVersion)" -ForegroundColor Yellow
        return $false
    }
    Write-Host "[OK] Flutter version => $current" -ForegroundColor Green
    return $true
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
        Write-Host "[OK] symlink support enabled" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[MISSING] symlink support not available (enable Windows Developer Mode)" -ForegroundColor Yellow
        return $false
    } finally {
        try { if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot } } catch {}
    }
}

Write-Host "=== HubDesk Build Environment Validation ===" -ForegroundColor Cyan

$preferredVcpkgRoot = $env:VCPKG_ROOT
$importedVsEnv = Import-VsDevEnv
if (-not [string]::IsNullOrWhiteSpace($preferredVcpkgRoot)) {
    $env:VCPKG_ROOT = $preferredVcpkgRoot
}
if ($importedVsEnv) {
    Write-Host "[OK] Visual Studio developer environment loaded" -ForegroundColor Green
} else {
    Write-Host "[WARN] Could not load VsDevCmd environment" -ForegroundColor Yellow
}

$allOk = $true
$requiredTools = @('git', 'python', 'cmake', 'rustc', 'cargo', 'flutter')

foreach ($tool in $requiredTools) {
    $ok = Test-Tool $tool
    if (-not $ok) { $allOk = $false }
}

$vsOk = Test-VSBuildTools
if (-not $vsOk) { $allOk = $false }

$msvcEnvOk = Test-MsvcCompileEnv
if (-not $msvcEnvOk) { $allOk = $false }

$clangOk = Test-Libclang
if (-not $clangOk) { $allOk = $false }

$flutterVersionOk = Test-FlutterVersion
if (-not $flutterVersionOk) { $allOk = $false }

$symlinkOk = Test-SymlinkSupport
if (-not $symlinkOk) { $allOk = $false }

Write-Host ""
Write-Host "=== Versions ===" -ForegroundColor Cyan
try { git --version } catch {}
try { python --version } catch {}
try { cmake --version } catch {}
try { rustc --version } catch {}
try { cargo --version } catch {}
try { flutter --version } catch {}
try {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
} catch {}

Write-Host ""
Write-Host "=== Environment Variables ===" -ForegroundColor Cyan
Write-Host "VCPKG_ROOT=$env:VCPKG_ROOT"
Write-Host "LIBCLANG_PATH=$env:LIBCLANG_PATH"

if ([string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
    Write-Host "[MISSING] VCPKG_ROOT is not set" -ForegroundColor Yellow
    $allOk = $false
} elseif (-not (Test-Path $env:VCPKG_ROOT)) {
    Write-Host "[MISSING] VCPKG_ROOT path does not exist: $env:VCPKG_ROOT" -ForegroundColor Yellow
    $allOk = $false
} else {
    Write-Host "[OK] VCPKG_ROOT exists" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Repo Checks ===" -ForegroundColor Cyan
if (Test-Path (Join-Path $RepoRoot "libs/hbb_common/Cargo.toml")) {
    Write-Host "[OK] submodule libs/hbb_common initialized" -ForegroundColor Green
} else {
    Write-Host "[MISSING] submodule libs/hbb_common not initialized" -ForegroundColor Yellow
    $allOk = $false
}

if (Test-Path (Join-Path $RepoRoot "custom_client.json")) {
    Write-Host "[OK] custom_client.json present" -ForegroundColor Green
} else {
    Write-Host "[WARN] custom_client.json missing" -ForegroundColor Yellow
}

Write-Host ""
if ($allOk) {
    Write-Host "Environment is ready for build." -ForegroundColor Green
    exit 0
}

Write-Host "Environment is NOT ready yet. Run scripts/bootstrap_windows.ps1 first." -ForegroundColor Yellow
exit 1
