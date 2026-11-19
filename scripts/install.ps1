# Install the artefacts CLI from GitHub releases.
# Usage: ./scripts/install.ps1 [version]

param(
  [Parameter(Position = 0)] [string]$Version = 'latest',
  [Alias('h')] [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Help {
  Write-Host @'
Usage: install.ps1 [options] [version]

Install the artefacts CLI from GitHub releases.

Arguments:
  version        Release tag to install (default: latest)

Options:
  -h, --help     Show this help.

PREFIX defaults to %ProgramFiles%\artefacts and can be overridden
with the PREFIX environment variable.
'@
}

if ($Help) {
  Show-Help
  exit 0
}

[Net.ServicePointManager]::SecurityProtocol =
  [Net.SecurityProtocolType]::Tls12

$script:Code = 1
$Repo = 'art-e-fact/artefacts-bins'
$Prefix = if ($env:PREFIX) { $env:PREFIX } else {
  Join-Path $env:ProgramFiles 'artefacts'
}
$Prefix = [IO.Path]::GetFullPath($Prefix).TrimEnd('\')
$Bin = Join-Path $Prefix 'bin'
$Share = Join-Path $Prefix 'share\artefacts'
$envArch = if ($env:PROCESSOR_ARCHITEW6432) {
  $env:PROCESSOR_ARCHITEW6432
} else {
  $env:PROCESSOR_ARCHITECTURE
}

# ------------------------------------------------------------------ messages

function Fail([string]$message, [int]$code = 1) {
  $script:Code = $code
  throw $message
}

function Log([string]$message) {
  Write-Host "artefacts: $message"
}

function Warn([string]$message) {
  Write-Host "artefacts: warning: $message" -ForegroundColor Yellow
}

# ----------------------------------------------------------------- privileges
# Restart once, elevated, only when a requested write needs it.

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = [Security.Principal.WindowsPrincipal] $identity
  return $p.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ask-Elevation([string]$why) {
  if ($env:ARTEFACTS_ELEVATED -or (Test-Admin)) { return }
  Log "elevation needed: $why"
  $env:ARTEFACTS_ELEVATED = '1'
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$PSCommandPath`""
  )
  if ($Version -ne 'latest') { $args += "`"$Version`"" }
  $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -Verb RunAs -ArgumentList $args -Wait -PassThru
  exit $p.ExitCode
}

# ------------------------------------------------------------------- helpers

function Test-OnPath {
  $dirs = $env:PATH -split ';' |
    ForEach-Object { $_.TrimEnd('\') }
  return ($dirs -contains $Bin)
}

function New-Dir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Get-Release([string]$tag) {
  $uri = if ($tag -eq 'latest') {
    "https://api.github.com/repos/$Repo/releases/latest"
  } else {
    "https://api.github.com/repos/$Repo/releases/tags/$tag"
  }
  try {
    return Invoke-RestMethod -Uri $uri `
      -Headers @{ 'User-Agent' = 'artefacts-installer' }
  } catch {
    Fail "release '$tag' not found or GitHub is unreachable"
  }
}

function Find-Asset($release, [string[]]$names) {
  foreach ($name in $names) {
    $match = $release.assets |
      Where-Object { $_.name -eq $name } |
      Select-Object -First 1
    if ($match) { return $match }
  }
  return $null
}

function Save-Asset($asset, [string]$path) {
  $opts = @{
    Uri     = $asset.browser_download_url
    OutFile = $path
    Headers = @{ 'User-Agent' = 'artefacts-installer' }
  }
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $opts['UseBasicParsing'] = $true
  }
  Invoke-WebRequest @opts
  $expected = ($asset.digest -replace '^sha256:', '').ToLowerInvariant()
  $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256
  $actual = $hash.Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    Fail "checksum mismatch: $($asset.name)"
  }
}

function Set-Launcher([string]$target) {
  $exe = Join-Path $Bin 'artefacts.exe'
  $cmd = Join-Path $Bin 'artefacts.cmd'

  if (Test-Path -LiteralPath $exe) {
    $item = Get-Item -LiteralPath $exe
    if ($item.LinkType -eq 'SymbolicLink' -and `
        $item.Target -eq $target) { return }
  }
  if ((Test-Path -LiteralPath $cmd) -and `
      (Get-Content -LiteralPath $cmd -Raw) -match `
      [regex]::Escape($target)) { return }

  Ask-Elevation "updating $exe (linking the CLI binary into $Bin)"
  foreach ($p in @($exe, $cmd)) {
    if (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Force
    }
  }
  try {
    New-Item -ItemType SymbolicLink -Path $exe -Target $target `
      -ErrorAction Stop | Out-Null
  } catch {
    # A shim is the portable equivalent when symlinks are not permitted.
    [IO.File]::WriteAllText(
      $cmd, "@echo off`r`n`"$target`" %*`r`n")
  }
}

# ----------------------------------------------------------------------- main

$tmp = $null
try {
  if ($Version -ne 'latest') {
    $Version = $Version -replace '^v', ''
    if ($Version -notmatch '^[A-Za-z0-9._-]+$') {
      Fail "invalid version: $Version"
    }
  }
  $release = Get-Release $Version
  $Version = $release.tag_name

  $arch = switch -Regex ($envArch) {
    'AMD64|x86_64' { 'x64'; break }
    'ARM64'        { 'arm64'; break }
    default        { Fail "unsupported architecture: $envArch" }
  }

  # Native packages take priority wherever they are published.
  $pkg = Find-Asset $release @("artefacts_${Version}_${arch}.msi")
  if ($pkg) {
    Ask-Elevation "installing $($pkg.name) into system directories"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) `
      ('artefacts-' + [guid]::NewGuid().ToString('N'))
    New-Dir $tmp
    $file = Join-Path $tmp $pkg.name
    Save-Asset $pkg $file
    $p = Start-Process msiexec.exe -ArgumentList `
      @('/i', "`"$file`"", '/qn', '/norestart') -Wait -PassThru
    if ($p.ExitCode -ne 0) {
      Fail "msiexec failed (exit $($p.ExitCode))"
    }
    Log "installed artefacts $Version via $($pkg.name)"
  } else {
    $names = @(
      "artefacts_windows-$arch.exe",
      "artefacts_windows-$arch",
      "artefacts_win32-$arch.exe"
    )
    $asset = Find-Asset $release $names
    if (-not $asset) {
      Fail "no installer or binary for windows-$arch in release $Version" 3
    }

    $target = Join-Path $Share "artefacts-$Version.exe"
    if (Test-Path -LiteralPath $target) {
      Set-Launcher $target
      Log "artefacts $Version is already installed at $target"
    } else {
      if (-not (Test-OnPath)) { Warn "$Bin is not on PATH" }
      Ask-Elevation "writing to $Prefix requires administrator rights"
      New-Dir $Share
      New-Dir $Bin
      Save-Asset $asset $target
      Set-Launcher $target
      Log "installed artefacts $Version at $target"
    }
    if (-not (Test-OnPath)) {
      Warn "$Bin is still not on PATH; add it to PATH to use 'artefacts'"
    }
  }
  $code = 0
} catch {
  [Console]::Error.WriteLine("artefacts: error: $($_.Exception.Message)")
  $code = $script:Code
} finally {
  if ($tmp -and (Test-Path -LiteralPath $tmp)) {
    Remove-Item -LiteralPath $tmp -Recurse -Force `
      -ErrorAction SilentlyContinue
  }
}

exit $code
