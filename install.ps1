#Requires -Version 5.1
<#
.SYNOPSIS
  Installs Git, Helix and a Nerd Font, then clones this Helix setup into
  %APPDATA%\helix and generates config.toml for this platform.

.DESCRIPTION
  Uses winget when it is available and falls back to portable GitHub builds,
  so it also works on Windows Server without the App Installer.

  config.toml is not used as committed: it is regenerated from keys\*.toml by
  build-config.ps1, which also picks the platform-specific fragment
  (keys\99-local-windows.toml here, keys\99-local-unix.toml on Linux).

.EXAMPLE
  irm https://raw.githubusercontent.com/ezonius/helix/master/install.ps1 | iex

.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ezonius/helix/master/install.ps1))) -NoFont

.EXAMPLE
  .\install.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [string]$Repo = "https://github.com/ezonius/helix.git",
  # empty = use the remote's default branch
  [string]$Branch = "",
  [string]$Destination = (Join-Path $env:APPDATA "helix"),
  [string]$FontFamily = "FiraCode",
  [switch]$NoFont,
  [switch]$NoEditor,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:DryRunMode = $DryRun.IsPresent

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host "warn: $Message" -ForegroundColor Yellow }

function Test-Tool([string]$Command) {
  return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Update-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
}

function Add-ToUserPath([string]$Directory) {
  if ($script:DryRunMode) { Write-Note "[dry-run] add to user PATH: $Directory"; return }
  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($current) { $parts = @($current -split ";" | Where-Object { $_ }) }
  if ($parts -notcontains $Directory) {
    [Environment]::SetEnvironmentVariable("Path", (@($parts) + $Directory) -join ";", "User")
  }
  if (($env:Path -split ";") -notcontains $Directory) { $env:Path = "$Directory;$env:Path" }
}

function Install-WingetPackage([string]$Id) {
  if (-not (Test-Tool "winget")) { return $false }
  Write-Step "winget: installing $Id"
  if ($script:DryRunMode) { Write-Note "[dry-run] winget install --id $Id"; return $true }
  & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
    ForEach-Object { Write-Note "$_" }
  Update-PathFromRegistry
  return $true
}

function Get-ReleaseAssetUrl([string]$Repository, [string]$AssetPattern) {
  $headers = @{ "User-Agent" = "helix-installer" }
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
  $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
  if (-not $asset) { throw "no release asset matching /$AssetPattern/ in $Repository" }
  return $asset.browser_download_url
}

function Install-Portable {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$AssetPattern,
    # keep one level of folder from the archive instead of the folder holding the exe
    [switch]$KeepRoot
  )

  $dest = Join-Path $env:LOCALAPPDATA "Programs\$Name"
  Write-Step "$Name -> $dest (portable download)"
  if ($script:DryRunMode) { Write-Note "[dry-run] asset /$AssetPattern/ from $Repository"; return }

  $url = Get-ReleaseAssetUrl -Repository $Repository -AssetPattern $AssetPattern
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("helix-install-" + $Name + "-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    Write-Note $url
    $archive = Join-Path $tmp "download.zip"
    Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    $extract = Join-Path $tmp "extract"
    Expand-Archive -Path $archive -DestinationPath $extract -Force

    $source = (Get-ChildItem -Path $extract -Filter $Exe -Recurse -File | Select-Object -First 1)
    if (-not $source) { throw "$Exe not found in the $Name archive" }
    $source = $source.Directory.FullName
    if ($KeepRoot) {
      $first = Get-ChildItem -Path $extract -Directory | Select-Object -First 1
      if ($first) { $source = $first.FullName }
    }

    if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -Path $source -Destination $dest -Recurse -Force

    $installed = Get-ChildItem -Path $dest -Filter $Exe -Recurse -File | Select-Object -First 1
    if (-not $installed) { throw "$Exe missing after copying to $dest" }
    Add-ToUserPath $installed.Directory.FullName
  }
  finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-Tool {
  param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$DisplayName,
    [string]$WingetId,
    [scriptblock]$Portable,
    [string]$Hint
  )

  if (Test-Tool $Command) {
    Write-Step "$DisplayName already installed ($(& $Command --version 2>$null | Select-Object -First 1))"
    return $true
  }

  Write-Step "$DisplayName missing"
  if ($WingetId) { Install-WingetPackage $WingetId | Out-Null }
  if (-not (Test-Tool $Command) -and $Portable) {
    Write-Step "winget route unavailable, using a portable build"
    & $Portable
  }

  if ($script:DryRunMode) { return $true }
  if (-not (Test-Tool $Command)) {
    Write-Warn "$DisplayName is still not on PATH. $Hint"
    return $false
  }
  return $true
}

function Register-FontForCurrentSession([string[]]$Paths) {
  try {
    if (-not ("HelixSetup.FontNative" -as [type])) {
      Add-Type -Namespace HelixSetup -Name FontNative -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("gdi32.dll", EntryPoint = "AddFontResourceW", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int AddFontResource(string lpFileName);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
"@
    }
    foreach ($path in $Paths) { [void][HelixSetup.FontNative]::AddFontResource($path) }
    $result = [System.IntPtr]::Zero
    [void][HelixSetup.FontNative]::SendMessageTimeout([System.IntPtr]0xffff, 0x001D, [System.IntPtr]::Zero, [System.IntPtr]::Zero, 2, 1000, [ref]$result)
  }
  catch {
    Write-Note "registered for the next login only ($($_.Exception.Message))"
  }
}

function Install-NerdFont([string]$Family) {
  $fontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
  Write-Step "installing Nerd Font '$Family' into $fontDir"
  if ($script:DryRunMode) {
    Write-Note "[dry-run] download $Family.zip from ryanoasis/nerd-fonts and register it for the current user"
    return
  }

  $url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$Family.zip"
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("helix-font-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    Write-Note "downloading $url (FiraCode is ~29 MB, Hack ~19 MB, JetBrainsMono ~130 MB)"
    $zip = Join-Path $tmp "font.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    $extract = Join-Path $tmp "font"
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    New-Item -ItemType Directory -Path $fontDir -Force | Out-Null

    $fonts = @(Get-ChildItem -Path $extract -Recurse -File | Where-Object { $_.Extension -in ".ttf", ".otf" })
    if ($fonts.Count -eq 0) { throw "no .ttf/.otf files inside $Family.zip" }

    $registry = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    if (-not (Test-Path $registry)) { New-Item -Path $registry -Force | Out-Null }

    $installed = @()
    foreach ($font in $fonts) {
      $target = Join-Path $fontDir $font.Name
      Copy-Item -Path $font.FullName -Destination $target -Force
      $kind = if ($font.Extension -eq ".otf") { "OpenType" } else { "TrueType" }
      New-ItemProperty -Path $registry -Name "$($font.BaseName) ($kind)" -Value $target -PropertyType String -Force | Out-Null
      $installed += $target
    }

    Register-FontForCurrentSession -Paths $installed
    Write-Note "$($installed.Count) font files installed - restart your terminal and pick '$Family Nerd Font'"
  }
  finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# config.toml is generated, not hand-edited: rebuild it for this platform.
function Invoke-BuildConfig([string]$ConfigDir) {
  Write-Step "generating config.toml from keys\*.toml"
  if ($script:DryRunMode) {
    Write-Note "[dry-run] powershell -NoProfile -ExecutionPolicy Bypass -File $ConfigDir\build-config.ps1 -ConfigDir $ConfigDir"
    return
  }
  $buildScript = Join-Path $ConfigDir "build-config.ps1"
  if (-not (Test-Path $buildScript)) {
    Write-Warn "no build-config.ps1 in $ConfigDir - leaving config.toml as committed"
    return
  }
  # re-run in a fresh host so the execution policy cannot block the script
  $hostExe = (Get-Process -Id $PID).Path
  & $hostExe -NoProfile -ExecutionPolicy Bypass -File $buildScript -ConfigDir $ConfigDir
  if ($LASTEXITCODE -ne 0) { Write-Warn "build-config.ps1 failed - config.toml may be stale" }
}

# --- prerequisites ---------------------------------------------------------
Write-Step "checking prerequisites (git, helix)"

Ensure-Tool -Command "git" -DisplayName "Git" -WingetId "Git.Git" -Hint "install Git for Windows and re-run." -Portable {
  Install-Portable -Name "MinGit" -Exe "git.exe" -Repository "git-for-windows/git" `
    -AssetPattern '^MinGit-\d[\d.]*-64-bit\.zip$' -KeepRoot
} | Out-Null

if ($NoEditor) {
  Write-Note "skipping Helix (-NoEditor)"
}
else {
  Ensure-Tool -Command "hx" -DisplayName "Helix" -WingetId "Helix.Helix" -Hint "install Helix and re-run." -Portable {
    Install-Portable -Name "helix" -Exe "hx.exe" -Repository "helix-editor/helix" `
      -AssetPattern '^helix-[\d.]+-x86_64-windows\.zip$' -KeepRoot
  } | Out-Null
}

if ($NoFont) {
  Write-Note "skipping Nerd Font ($FontFamily)"
}
else {
  Install-NerdFont $FontFamily
}

# --- configuration ---------------------------------------------------------
Write-Step "installing configuration into $Destination"

if (-not (Test-Tool "git") -and -not $script:DryRunMode) {
  throw "git is required to clone the configuration; install it and re-run."
}

if (-not $Branch) {
  Write-Step "detecting the default branch of $Repo"
  $ref = $null
  try { $ref = (& git ls-remote --symref $Repo HEAD 2>$null | Select-Object -First 1) } catch { }
  if ($ref -match '^ref: refs/heads/(\S+)') { $Branch = $Matches[1] } else { $Branch = "master" }
}
Write-Step "branch: $Branch"

$isRepo = Test-Path (Join-Path $Destination ".git")
if ($isRepo) {
  Write-Step "updating existing clone"
  if ($script:DryRunMode) {
    Write-Note "[dry-run] git pull --ff-only origin $Branch"
  }
  else {
    & git -C $Destination pull --ff-only --quiet origin $Branch
    if ($LASTEXITCODE -ne 0) { Write-Warn "could not fast-forward $Destination - leaving it untouched" }
  }
}
else {
  if (Test-Path $Destination) {
    $full = (Resolve-Path $Destination).Path
    if ($full -eq $PWD.Path) { throw "refusing to move $Destination while it is the current directory; run the installer from elsewhere." }
    $backup = "$Destination.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Write-Step "backing up existing config -> $backup"
    if (-not $script:DryRunMode) { Move-Item -Path $Destination -Destination $backup }
  }

  Write-Step "cloning $Repo ($Branch)"
  if ($script:DryRunMode) {
    Write-Note "[dry-run] git clone --depth 1 --branch $Branch $Repo $Destination"
  }
  else {
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    & git clone --quiet --depth 1 --branch $Branch $Repo $Destination
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
  }
}

Invoke-BuildConfig $Destination

Write-Step "done"
Write-Note "config: $Destination"
Write-Note "start:  hx"
if (-not $NoFont) { Write-Note "set '$FontFamily Nerd Font' as the font in Windows Terminal (Settings > Profiles > Defaults > Appearance)" }
Write-Note "edit keys\*.toml, then <space>B inside Helix to rebuild and reload"
