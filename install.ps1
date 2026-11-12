# ==========================================
# Tasker CLI Windows Installer Script
# ==========================================
# Optional: .\install.ps1 -DbUrl "postgresql://user:pass@host:5432/tasker_db"
param(
    # NOTE: "?schema=public" is a Prisma-style option that the Postgres driver
    # rejects, so it is intentionally left out.
    [string]$DbUrl = "postgres://postgres:postgres@10.10.10.10:5432/tasker_db"
)

$AppName = "tasker"
$ExeName = "$AppName.exe"
$SourceExe = Join-Path $PSScriptRoot "dist\$ExeName"

# 1. Check if the compiled executable exists
if (-not (Test-Path $SourceExe)) {
    Write-Host "❌ Error: Could not find '$SourceExe'." -ForegroundColor Red
    Write-Host "Build it first (on the build machine):" -ForegroundColor Yellow
    Write-Host "  pip install pyinstaller psycopg2-binary" -ForegroundColor Yellow
    Write-Host "  pyinstaller --onefile --name tasker work.py" -ForegroundColor Yellow
    exit 1
}

# 2. Define target installation directory in Documents
$TargetDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Tasker"
$TargetExe = Join-Path $TargetDir $ExeName

Write-Host "📁 Setting up installation directory at: $TargetDir" -ForegroundColor Cyan
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir | Out-Null
}

# 3. Copy the executable to the Documents folder
Write-Host "📦 Copying $ExeName to $TargetDir..." -ForegroundColor Cyan
Copy-Item -Path $SourceExe -Destination $TargetExe -Force

# 4. Add to User PATH if not already present
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

if ($UserPath -notlike "*$TargetDir*") {
    Write-Host "⚙️ Adding $TargetDir to your User PATH..." -ForegroundColor Cyan
    $NewPath = if ($UserPath) { "$UserPath;$TargetDir" } else { $TargetDir }
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    Write-Host "✅ Successfully added to PATH!" -ForegroundColor Green
} else {
    Write-Host "ℹ️ Target directory is already in your PATH." -ForegroundColor Yellow
}

# 5. Configure the server connection (used by --push, --create-user, etc.)
Write-Host "🔌 Configuring server connection..." -ForegroundColor Cyan
[Environment]::SetEnvironmentVariable("WORK_DATABASE_URL", $DbUrl, "User")
$env:WORK_DATABASE_URL = $DbUrl
Write-Host "✅ WORK_DATABASE_URL saved to your user environment." -ForegroundColor Green

Write-Host "`n🎉 Installation complete!" -ForegroundColor Green
Write-Host "👉 Open a **brand new** terminal window and type: tasker --help" -ForegroundColor Yellow
Write-Host "👉 First time? Onboard yourself:  tasker --create-user YOUR_STAFF_ID -u YOUR_USERNAME" -ForegroundColor Yellow