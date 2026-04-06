$ErrorActionPreference = 'Continue'

function Test-Tool($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        Write-Host "[OK] $name => $($cmd.Source)" -ForegroundColor Green
        return $true
    }
    Write-Host "[MISSING] $name" -ForegroundColor Yellow
    return $false
}

Write-Host "=== HubDesk Build Environment Validation ===" -ForegroundColor Cyan

$allOk = $true
$requiredTools = @('git', 'python', 'cmake', 'rustc', 'cargo', 'flutter', 'cl')

foreach ($tool in $requiredTools) {
    $ok = Test-Tool $tool
    if (-not $ok) { $allOk = $false }
}

Write-Host ""
Write-Host "=== Versions ===" -ForegroundColor Cyan
try { git --version } catch {}
try { python --version } catch {}
try { cmake --version } catch {}
try { rustc --version } catch {}
try { cargo --version } catch {}
try { flutter --version } catch {}

Write-Host ""
Write-Host "=== Environment Variables ===" -ForegroundColor Cyan
Write-Host "VCPKG_ROOT=$env:VCPKG_ROOT"

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
if (Test-Path "libs/hbb_common/Cargo.toml") {
    Write-Host "[OK] submodule libs/hbb_common initialized" -ForegroundColor Green
} else {
    Write-Host "[MISSING] submodule libs/hbb_common not initialized" -ForegroundColor Yellow
    $allOk = $false
}

if (Test-Path "custom_client.json") {
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
