#Requires -Version 5.1
<#
  Odysseus - native Windows launcher (no Docker).

  One command to: create a virtualenv, install dependencies, run first-time
  setup (prints an admin password on first run), and start the server.
  Safe to re-run - it skips whatever already exists.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\launch-windows.ps1
    powershell -ExecutionPolicy Bypass -File .\launch-windows.ps1 -Port 7000 -BindHost 127.0.0.1

  Tip: bind 127.0.0.1 (default) for local-only use. Use 0.0.0.0 only when you
  intentionally want other devices on your LAN to reach it.
#>
param(
    [int]$Port = 7000,
    [string]$BindHost = "127.0.0.1",
    [string]$DepsRoot = "",
    [switch]$SetupOnly
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

if (-not $DepsRoot) { $DepsRoot = $env:ODYSSEUS_DEPS_ROOT }
if (-not $DepsRoot) { $DepsRoot = "D:\Personale\deps" }
$DepsRoot = [System.IO.Path]::GetFullPath($DepsRoot)
$ProjectDeps = Join-Path $DepsRoot "odysseus"
$VenvDir = Join-Path $ProjectDeps "venv"
$venvPy = Join-Path $VenvDir "Scripts\python.exe"

# Some Windows/dev shells expose DEBUG=release. Pydantic expects DEBUG to be a
# boolean, so keep explicit boolean values and neutralize unrelated ones.
if ($env:DEBUG -and $env:DEBUG -notmatch '^(true|false|1|0|yes|no|on|off)$') {
    Write-Host ("Ignoring non-boolean DEBUG={0} for Odysseus startup." -f $env:DEBUG) -ForegroundColor Yellow
    $env:DEBUG = "false"
}

function Write-Step($msg) { Write-Host ""; Write-Host ("==> " + $msg) -ForegroundColor Cyan }
function Fail($msg) {
    Write-Host ""
    Write-Host ("ERROR: " + $msg) -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

function Set-DependencyEnvironment {
    $paths = @{
        "PIP_CACHE_DIR" = Join-Path $DepsRoot "pip-cache"
        "PYTHONUSERBASE" = Join-Path $DepsRoot "python-user"
        "HF_HOME" = Join-Path $DepsRoot "huggingface"
        "HUGGINGFACE_HUB_CACHE" = Join-Path $DepsRoot "huggingface\hub"
        "FASTEMBED_CACHE_PATH" = Join-Path $DepsRoot "fastembed"
        "PLAYWRIGHT_BROWSERS_PATH" = Join-Path $DepsRoot "playwright-browsers"
        "TORCH_HOME" = Join-Path $DepsRoot "torch"
        "XDG_CACHE_HOME" = Join-Path $DepsRoot "xdg-cache"
        "NPM_CONFIG_CACHE" = Join-Path $DepsRoot "npm-cache"
        "TEMP" = Join-Path $DepsRoot "tmp"
        "TMP" = Join-Path $DepsRoot "tmp"
        "TMPDIR" = Join-Path $DepsRoot "tmp"
    }
    New-Item -ItemType Directory -Force -Path $ProjectDeps | Out-Null
    foreach ($p in $paths.Values) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
    $env:ODYSSEUS_DEPS_ROOT = $DepsRoot
    foreach ($entry in $paths.GetEnumerator()) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
    }
    $env:npm_config_cache = $env:NPM_CONFIG_CACHE
    $env:HF_HUB_DISABLE_SYMLINKS = "1"
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
    $env:VIRTUAL_ENV = $VenvDir
    $env:ODYSSEUS_PYTHON = $venvPy
    $scriptsDir = Join-Path $VenvDir "Scripts"
    $userScriptsDir = Join-Path $env:PYTHONUSERBASE "Scripts"
    $prepend = @($scriptsDir, $userScriptsDir) | Where-Object { $_ }
    $current = @()
    if ($env:PATH) { $current = $env:PATH -split ";" }
    $prependReverse = @($prepend)
    [array]::Reverse($prependReverse)
    foreach ($p in $prependReverse) {
        if ($current -notcontains $p) {
            $env:PATH = "$p;$env:PATH"
        }
    }
}

function Ensure-NodeDependencies {
    if (-not (Test-Path (Join-Path $PSScriptRoot "package.json"))) { return }
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Write-Host "npm not found - skipping Node dependencies." -ForegroundColor Yellow
        return
    }
    $target = Join-Path $ProjectDeps "node_modules"
    $link = Join-Path $PSScriptRoot "node_modules"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "package.json") -Destination (Join-Path $ProjectDeps "package.json") -Force
    if (Test-Path (Join-Path $PSScriptRoot "package-lock.json")) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "package-lock.json") -Destination (Join-Path $ProjectDeps "package-lock.json") -Force
    }
    $marker = Join-Path $ProjectDeps "package-lock.sha256"
    $lock = Join-Path $PSScriptRoot "package-lock.json"
    $hash = if (Test-Path $lock) { (Get-FileHash $lock -Algorithm SHA256).Hash } else { "" }
    $oldHash = if (Test-Path $marker) { (Get-Content -Raw $marker).Trim() } else { "" }
    if ($hash -and $hash -eq $oldHash -and (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Write-Host "Node dependencies already installed in $target - skipping."
        Ensure-NodeModulesJunction $link $target
        return
    }
    Write-Step "Installing Node dependencies into $target"
    & $npm.Source ci --prefix $ProjectDeps --cache $env:NPM_CONFIG_CACHE
    if ($LASTEXITCODE -ne 0) { Fail "Node dependency install failed. Scroll up for the npm error." }
    if ($hash) { Set-Content -Path $marker -Value $hash -Encoding ASCII }
    Ensure-NodeModulesJunction $link $target
}

function Ensure-NodeModulesJunction($link, $target) {
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $existingTarget = @($item.Target)[0]
            if ($existingTarget -and ([System.IO.Path]::GetFullPath($existingTarget) -eq [System.IO.Path]::GetFullPath($target))) {
                return
            }
            $item.Delete()
        } elseif (Get-ChildItem -LiteralPath $link -Force -ErrorAction SilentlyContinue | Select-Object -First 1) {
            Write-Host "Existing local node_modules is not a junction; leaving it unchanged." -ForegroundColor Yellow
            return
        } else {
            Remove-Item -LiteralPath $link -Force
        }
    }
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}

Set-DependencyEnvironment

function Find-GitBash {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @()
    foreach ($name in @("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)", "LocalAppData")) {
        $base = [Environment]::GetEnvironmentVariable($name)
        if ($base) { $roots += (Join-Path $base "Git") }
    }
    $roots += @("C:\Program Files\Git", "C:\Program Files (x86)\Git")

    foreach ($root in ($roots | Select-Object -Unique)) {
        foreach ($relative in @("bin\bash.exe", "usr\bin\bash.exe")) {
            $candidate = Join-Path $root $relative
            if (Test-Path $candidate) { return $candidate }
        }
    }
    return $null
}

# 1. Locate a Python interpreter (3.11+ required)
Write-Step "Checking for Python"
function Get-PythonVersionText($launcher, $launcherArgs) {
    try {
        return (& $launcher @launcherArgs -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null).Trim()
    } catch {
        return $null
    }
}

$pyExe = $null
$pyArgs = @()
$pyVersion = $null

$pyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($pyLauncher) {
    foreach ($v in @("-3.13", "-3.12", "-3.11")) {
        $ver = Get-PythonVersionText $pyLauncher.Source @($v)
        if ($ver) {
            $pyExe = $pyLauncher.Source
            $pyArgs = @($v)
            $pyVersion = $ver
            break
        }
    }
}

if (-not $pyExe) {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $ver = Get-PythonVersionText $pythonCmd.Source @()
        if ($ver) {
            $versionParts = $ver.Split('.')
            $major = [int]$versionParts[0]
            $minor = [int]$versionParts[1]
            if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 11)) {
                $pyExe = $pythonCmd.Source
                $pyVersion = $ver
            }
        }
    }
}

if (-not $pyExe) {
    Fail "Couldn't find Python 3.11+ for Windows setup. Install Python 3.11+ (or open the Python launcher with 'py -3.11') from https://www.python.org/downloads/, then re-run this script."
}
$pythonLabel = ("Using Python {0}: {1} {2}" -f $pyVersion, $pyExe, ($pyArgs -join ' ')).TrimEnd()
Write-Host $pythonLabel

# 2. Create the virtualenv if missing
if (-not (Test-Path $venvPy)) {
    Write-Step "Creating virtual environment in $VenvDir"
    & $pyExe @pyArgs -m venv $VenvDir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPy)) { Fail "Failed to create the virtual environment." }
} else {
    Write-Host "venv already exists at $VenvDir - skipping creation."
}
Set-DependencyEnvironment

# 3. Install / update dependencies
Write-Step "Installing Python dependencies into $VenvDir (first run can take a few minutes)"
& $venvPy -m pip install --upgrade pip --quiet
& $venvPy -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { Fail "Dependency install failed. Scroll up for the pip error." }
Ensure-NodeDependencies

# 4. First-time setup (creates data dirs, DB, .env, admin user)
Write-Step "Running first-time setup"
& $venvPy setup.py
if ($LASTEXITCODE -ne 0) { Fail "setup.py failed." }

if ($SetupOnly) {
    Write-Step "Setup complete"
    Write-Host "Dependency root: $DepsRoot"
    Write-Host "Python venv:     $VenvDir"
    Write-Host "Node modules:    $(Join-Path $ProjectDeps 'node_modules')"
    exit 0
}

# 5. Friendly note about Git Bash (full Cookbook / agent-shell parity)
if (-not (Find-GitBash)) {
    Write-Host ""
    Write-Host "NOTE: Git Bash (bash.exe) was not found on PATH." -ForegroundColor Yellow
    Write-Host "      The core app works without it. For full Cookbook background" -ForegroundColor Yellow
    Write-Host "      downloads and the agent shell tool, install Git for Windows:" -ForegroundColor Yellow
    Write-Host "      https://git-scm.com/download/win" -ForegroundColor Yellow
}

# 6. Start the server (use `python -m uvicorn` - bare `uvicorn` may not be on PATH)
Write-Step ("Starting Odysseus at http://{0}:{1}" -f $BindHost, $Port)
Write-Host "Press Ctrl+C to stop."
Write-Host ""
& $venvPy -m uvicorn app:app --host $BindHost --port $Port
