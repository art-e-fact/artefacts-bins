# Detect and remove artefacts CLI installs.

param(
  [Alias('a')] [switch]$All,
  [Alias('y')] [switch]$Yes,
  [Alias('h')] [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Help {
  Write-Host @'
Usage: uninstall.ps1 [options]

Detect and remove artefacts CLI installs.

Options:
  -y, --yes      Proceed without confirmation: remove the first detected
                 install only (all detected installs with -All).
  -a, --all      Remove all detected installs without confirmation.
  -h, --help     Show this help.

With one install, confirmation is a simple yes/no prompt. With several, an
option list is shown. If none are found under the default PREFIX, an
alternative can be entered. PREFIX defaults to %ProgramFiles%\artefacts
and can be set in the environment.
'@
}

if ($Help) {
  Show-Help
  exit 0
}

$script:Code = 1
$DefaultPrefix = -not $env:PREFIX
$Prefix = if ($env:PREFIX) { $env:PREFIX } else {
  Join-Path $env:ProgramFiles 'artefacts'
}
$Bin = $null
$Share = $null

# ------------------------------------------------------------------ messages

function Fail([string]$message) {
  $script:Code = 1
  throw $message
}

function Log([string]$message) {
  Write-Host "artefacts: $message"
}

# ------------------------------------------------------------------- prefix
# Package managers are checked first, then binaries under the current prefix.

function Set-Prefix([string]$path) {
  $script:Prefix = [IO.Path]::GetFullPath($path).TrimEnd('\')
  $script:Bin = Join-Path $script:Prefix 'bin'
  $script:Share = Join-Path $script:Prefix 'share\artefacts'
}

# ----------------------------------------------------------------- privileges
# Restart once, elevated, only when a requested removal needs it.

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
  if ($All) { $args += '-All' }
  if ($Yes) { $args += '-Yes' }
  $p = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -Verb RunAs -ArgumentList $args -Wait -PassThru
  exit $p.ExitCode
}

# ------------------------------------------------------------------ detection

function Find-Packages {
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'artefacts' -and $_.PSChildName }

  $items = @()
  foreach ($app in $apps) {
    $version = $app.DisplayVersion
    if (-not $version) { $version = 'unknown' }
    $items += [pscustomobject]@{
      Kind    = 'package'
      Version = $version
      Path    = $app.PSChildName
    }
  }
  return $items
}

function Find-Binaries {
  $items = @()
  if (-not (Test-Path -LiteralPath $Share)) { return $items }

  $files = Get-ChildItem -LiteralPath $Share -File `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'artefacts-*' }
  foreach ($f in $files) {
    $version = $f.Name -replace '^artefacts-', ''
    $version = $version -replace '\.exe$', ''
    $items += [pscustomobject]@{
      Kind    = 'binary'
      Version = $version
      Path    = $f.FullName
    }
  }
  return $items
}

function Detect {
  $items = @()
  $items += Find-Packages
  $items += Find-Binaries
  return $items
}

# -------------------------------------------------------------------- prompts

function Test-Interactive {
  if ($All -or $Yes) { return $false }
  if ([Console]::IsInputRedirected) { return $false }
  return [Environment]::UserInteractive
}

function Ask-Prefix {
  Write-Host "artefacts: checked the native package manager and $Prefix."
  $answer = Read-Host 'No install found. Try a different PREFIX? [y/N]'
  if ($answer -notmatch '^(y|yes)$') { return $false }
  $new = Read-Host 'PREFIX'
  if ([string]::IsNullOrWhiteSpace($new)) { return $false }
  Set-Prefix $new
  return $true
}

function Confirm-One($item) {
  $line = 'artefacts: detected: {0} {1}' -f $item.Kind, $item.Version
  if ($item.Path) { $line += "  $($item.Path)" }
  Write-Host $line
  $answer = Read-Host 'Uninstall this install? [y/N]'
  return ($answer -match '^(y|yes)$')
}

function Choose([object[]]$items) {
  if (-not (Test-Interactive)) {
    if ($All) {
      Log 'no confirmation requested; uninstalling all installs'
      return $items
    }
    Log 'no confirmation requested; uninstalling first install'
    return @($items[0])
  }

  if ($items.Count -eq 1) {
    if (-not (Confirm-One $items[0])) { return @() }
    return @($items[0])
  }

  Write-Host 'artefacts: detected installations:'
  for ($i = 0; $i -lt $items.Count; $i++) {
    $item = $items[$i]
    $line = '  {0}) {1,-7} {2}' -f ($i + 1), $item.Kind, $item.Version
    if ($item.Path) { $line += "  $($item.Path)" }
    Write-Host $line
  }
  Write-Host '  a) all'
  Write-Host '  q) quit'

  $answer = Read-Host 'Select [q]'
  if ($answer -match '^(q|quit)?$') { return @() }
  if ($answer -match '^(a|all)$') { return $items }
  if ($answer -notmatch '^\d+$') { Fail 'invalid selection' }
  $n = [int]$answer
  if ($n -lt 1 -or $n -gt $items.Count) { Fail 'selection out of range' }
  return @($items[$n - 1])
}

# -------------------------------------------------------------------- removal

function Remove-Package($item) {
  Ask-Elevation 'removing the system-registered artefacts package'
  $p = Start-Process msiexec.exe -ArgumentList `
    @('/x', $item.Path, '/qn', '/norestart') -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Fail "msiexec failed (exit $($p.ExitCode))"
  }
}

function Remove-Binary($item) {
  if (Test-Path -LiteralPath $item.Path) {
    Remove-Item -LiteralPath $item.Path -Force
  }
}

function Set-Launcher([string]$target) {
  $exe = Join-Path $Bin 'artefacts.exe'
  $cmd = Join-Path $Bin 'artefacts.cmd'

  if (-not (Test-Path -LiteralPath $exe) -and `
      -not (Test-Path -LiteralPath $cmd)) { return }

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
    [IO.File]::WriteAllText(
      $cmd, "@echo off`r`n`"$target`" %*`r`n")
  }
}

function Sync-Launcher {
  $remaining = @()
  if (Test-Path -LiteralPath $Share) {
    $remaining = @(Get-ChildItem -LiteralPath $Share -File |
      Where-Object { $_.Name -like 'artefacts-*' })
  }
  if ($remaining.Count -eq 0) {
    $exe = Join-Path $Bin 'artefacts.exe'
    $cmd = Join-Path $Bin 'artefacts.cmd'
    Remove-Item -LiteralPath $exe, $cmd -Force `
      -ErrorAction SilentlyContinue
    return
  }
  Set-Launcher (Join-Path $Share $remaining[0].Name)
}

# ----------------------------------------------------------------------- main

$askedPrefix = $false
try {
  Set-Prefix $Prefix
  $items = @(Detect)

  while ($items.Count -eq 0) {
    if ($DefaultPrefix -and -not $askedPrefix -and `
        (Test-Interactive) -and (Ask-Prefix)) {
      $askedPrefix = $true
      $items = @(Detect)
      continue
    }
    Log "nothing to uninstall (checked the native package manager and $Prefix)"
    $code = 0
    break
  }

  if ($items.Count -gt 0) {
    $chosen = @(Choose $items)
    if ($chosen.Count -eq 0) {
      Log 'nothing uninstalled'
    } else {
      if ($chosen | Where-Object { $_.Kind -eq 'binary' }) {
        $why = "removing files under $Prefix requires administrator rights"
        Ask-Elevation $why
      }
      foreach ($item in $chosen) {
        if ($item.Kind -eq 'package') {
          Remove-Package $item
        } else {
          Remove-Binary $item
          Log "removed binary artefacts $($item.Version)"
        }
      }
      Sync-Launcher
      if ((Test-Path -LiteralPath $Share) -and `
          -not (Get-ChildItem -LiteralPath $Share -Force)) {
        Remove-Item -LiteralPath $Share
      }
      Log 'artefacts uninstalled'
    }
    $code = 0
  }
} catch {
  [Console]::Error.WriteLine("artefacts: error: $($_.Exception.Message)")
  $code = $script:Code
}

exit $code
