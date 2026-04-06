$ErrorActionPreference = 'Stop'

Write-Host "Validating environment..." -ForegroundColor Cyan
powershell -ExecutionPolicy Bypass -File .\scripts\validate_env.ps1
if ($LASTEXITCODE -ne 0) {
    throw "Environment is not ready. Run scripts/bootstrap_windows.ps1 as Administrator first."
}

if (-not (Test-Path "custom_client.json")) {
    throw "custom_client.json not found in repository root."
}

Write-Host "Updating submodules..." -ForegroundColor Cyan
git submodule update --init --recursive

Write-Host "Fetching Flutter dependencies..." -ForegroundColor Cyan
Push-Location flutter
flutter pub get
Pop-Location

Write-Host "Building HubDesk (Flutter Windows)..." -ForegroundColor Cyan
python .\build.py --portable --hwcodec --flutter --vram --skip-portable-pack

$releaseDir = "flutter\build\windows\x64\runner\Release"
if (-not (Test-Path $releaseDir)) {
    throw "Build output not found at $releaseDir"
}

Copy-Item -Force .\custom_client.json "$releaseDir\custom_client.json"

Write-Host "Build completed successfully." -ForegroundColor Green
Write-Host "Output: $releaseDir" -ForegroundColor Green
Write-Host "Config copied: $releaseDir\custom_client.json" -ForegroundColor Green
