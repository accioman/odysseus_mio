[CmdletBinding()]
param(
  [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DepsRoot = $env:ODYSSEUS_DEPS_ROOT
if (-not $DepsRoot) { $DepsRoot = "D:\Personale\deps" }
$DepsRoot = [System.IO.Path]::GetFullPath($DepsRoot)
$ProjectDeps = Join-Path $DepsRoot "odysseus"
$VenvDir = Join-Path $ProjectDeps "venv"
$Port = 7000
$Url = "http://127.0.0.1:$Port"
$Python = Join-Path $VenvDir "Scripts\python.exe"
$LogDir = Join-Path $ProjectRoot "logs"
$StdoutLog = Join-Path $LogDir "odysseus-shortcut.out.log"
$StderrLog = Join-Path $LogDir "odysseus-shortcut.err.log"

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
  $env:ODYSSEUS_PYTHON = $Python
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

Set-DependencyEnvironment

function Test-OdysseusListening {
  try {
    $conn = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
  } catch {
    return $false
  }
}

function Get-ChromePath {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }
  return $null
}

if (-not (Test-Path -LiteralPath $Python)) {
  throw "Python venv not found: $Python"
}

if (-not (Test-OdysseusListening)) {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $env:DEBUG = "false"
  Start-Process `
    -FilePath $Python `
    -ArgumentList @("-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", "$Port") `
    -WorkingDirectory $ProjectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog | Out-Null

  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    if (Test-OdysseusListening) { break }
    Start-Sleep -Milliseconds 500
  }
}

if (-not $NoOpen) {
  $Chrome = Get-ChromePath
  if ($Chrome) {
    Start-Process -FilePath $Chrome -ArgumentList @($Url)
  } else {
    Start-Process $Url
  }
}
