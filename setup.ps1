#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a fresh Windows install: apps, WSL2, and NixOS from github:sknutsen/nixconf#wsl.

.PARAMETER Resume
  Continues after the WSL feature reboot. Set automatically via RunOnce.

.PARAMETER SkipWsl
  Skip WSL / NixOS entirely.

.PARAMETER SkipNixFlake
  Install the NixOS-WSL distro but do not apply the nixconf flake.
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$SkipWsl,
    [switch]$SkipNixFlake
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Match nixosConfigurations.wsl in https://github.com/sknutsen/nixconf
$WslDistroName = 'NixOS'
$NixFlake      = 'github:sknutsen/nixconf#wsl'
$NixconfClone  = 'https://github.com/sknutsen/nixconf.git'

$WingetAlreadyInstalled = @(-1978335189, -1978335135)

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Admin {
    if (Test-IsAdmin) { return }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Resume) { $args += '-Resume' }
    if ($SkipWsl) { $args += '-SkipWsl' }
    if ($SkipNixFlake) { $args += '-SkipNixFlake' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args
    exit
}

function Register-ResumeAfterReboot {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'WinSetupResume' -Value $cmd
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Override,
        [string]$Locale
    )

    Write-Host ">>> $Id"
    $wingetArgs = @(
        'install', '--id', $Id, '-e',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Locale) { $wingetArgs += @('--locale', $Locale) }
    if ($Override) { $wingetArgs += @('--override', $Override) }

    & winget @wingetArgs
    if ($LASTEXITCODE -and ($WingetAlreadyInstalled -notcontains $LASTEXITCODE)) {
        Write-Warning "winget install $Id exited with code $LASTEXITCODE"
    }
}

function Test-WslUsable {
    & wsl.exe --status 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-WslDistro {
    param([string]$Name)
    $listing = & wsl.exe -l -q --utf8 2>$null
    if (-not $listing) { $listing = & wsl.exe -l -q 2>$null }
    if (-not $listing) { return $false }
    $names = @(
        $listing |
            ForEach-Object { ($_ -replace "`0", '').Trim() } |
            Where-Object { $_ }
    )
    return $names -contains $Name
}

function Enable-NotepadPlusPlusDarkMode {
    $configDir = Join-Path $env:APPDATA 'Notepad++'
    $configPath = Join-Path $configDir 'config.xml'
    $npp = Join-Path $env:ProgramFiles 'Notepad++\notepad++.exe'
    if (-not (Test-Path $npp)) {
        Write-Warning 'Notepad++ not found; skipping dark mode.'
        return
    }

    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $srcTheme = Join-Path $env:ProgramFiles 'Notepad++\themes\DarkModeDefault.xml'
    $dstThemeDir = Join-Path $configDir 'themes'
    $dstTheme = Join-Path $dstThemeDir 'DarkModeDefault.xml'
    if ((Test-Path $srcTheme) -and -not (Test-Path $dstTheme)) {
        New-Item -ItemType Directory -Force -Path $dstThemeDir | Out-Null
        Copy-Item -Path $srcTheme -Destination $dstTheme -Force
    }

    if (-not (Test-Path $configPath)) {
        Write-Host 'Generating Notepad++ config.xml (first launch)...'
        $proc = Start-Process -FilePath $npp -ArgumentList @('-nosession', '-multiInst') -WindowStyle Minimized -PassThru
        $until = (Get-Date).AddSeconds(20)
        while (-not (Test-Path $configPath) -and ((Get-Date) -lt $until)) {
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Seconds 1
        Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $configPath)) {
        Write-Warning 'Could not create Notepad++ config.xml. Enable Dark Mode in Settings > Preferences.'
        return
    }

    $text = [IO.File]::ReadAllText($configPath)
    $text = [regex]::Replace($text, '(<GUIConfig name="DarkMode"[^>]*\benable=")no(")', '${1}yes${2}')
    if ($text -match 'GUIConfig name="stylerTheme"') {
        $text = [regex]::Replace(
            $text,
            '(<GUIConfig name="stylerTheme" path=")[^"]*(")',
            ('${1}' + $dstTheme + '${2}')
        )
    }
    [IO.File]::WriteAllText($configPath, $text)
    Write-Host 'Notepad++ dark mode enabled (DarkModeDefault).'
}

function Install-NixOSWsl {
    param([switch]$ApplyFlake)

    Write-Host 'Updating WSL...'
    & wsl.exe --update --web-download
    & wsl.exe --set-default-version 2

    if (-not (Test-WslDistro $WslDistroName)) {
        $tmp = Join-Path $PSScriptRoot 'tmp'
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $wslFile = Join-Path $tmp 'nixos.wsl'
        if (-not (Test-Path $wslFile)) {
            Write-Host 'Downloading latest NixOS-WSL image...'
            & curl.exe -L --fail -o $wslFile 'https://github.com/nix-community/NixOS-WSL/releases/latest/download/nixos.wsl'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to download nixos.wsl' }
        }

        Write-Host "Installing NixOS-WSL as distro '$WslDistroName'..."
        & wsl.exe --install --name $WslDistroName --from-file $wslFile --no-launch
        if ($LASTEXITCODE -ne 0) {
            $importDir = Join-Path $env:LOCALAPPDATA "wsl\$WslDistroName"
            New-Item -ItemType Directory -Force -Path $importDir | Out-Null
            & wsl.exe --import $WslDistroName $importDir $wslFile --version 2
            if ($LASTEXITCODE -ne 0) { throw 'Failed to import NixOS-WSL' }
        }
    }
    else {
        Write-Host "WSL distro '$WslDistroName' already installed."
    }

    & wsl.exe -s $WslDistroName

    if (-not $ApplyFlake) {
        Write-Host "NixOS-WSL is installed. Apply the flake later with:"
        Write-Host "  wsl -d $WslDistroName -u root -- bash -lc `"nixos-rebuild boot --flake $NixFlake`""
        return
    }

    Write-Host "Applying $NixFlake (first rebuild can take a long time)..."
    $inner = 'set -euo pipefail; mkdir -p /etc/nix; grep -q experimental-features /etc/nix/nix.conf 2>/dev/null || echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf; nixos-rebuild boot --flake ' + $NixFlake
    & wsl.exe -d $WslDistroName -u root -- bash -lc $inner
    if ($LASTEXITCODE -ne 0) { throw 'nixos-rebuild boot failed' }

    # Changing wsl.defaultUser (nixos -> zdk) requires boot + two restarts, not switch.
    & wsl.exe --terminate $WslDistroName
    & wsl.exe -d $WslDistroName -u root -- true
    & wsl.exe --terminate $WslDistroName
    & wsl.exe -s $WslDistroName

    Write-Host 'Cloning nixconf into ~/.nixconf for local rebuilds...'
    $clone = 'test -d "$HOME/.nixconf/.git" || git clone ' + $NixconfClone + ' "$HOME/.nixconf"'
    & wsl.exe -d $WslDistroName -u zdk -- bash -lc $clone
    Write-Host "NixOS WSL is ready. Open with: wsl -d $WslDistroName"
}

Request-Admin

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store and re-run.'
}

Write-Host 'Accepting winget source agreements...'
& winget source update --disable-interactivity | Out-Null

# --- Mandatory ---
Install-WingetPackage -Id 'Git.Git'
Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.Enterprise' -Override '--passive --wait --includeRecommended --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NetWeb --add Microsoft.VisualStudio.Workload.Azure --add Microsoft.VisualStudio.Workload.Data'
Install-WingetPackage -Id 'Anthropic.ClaudeCode'
Install-WingetPackage -Id 'Axosoft.GitKraken'
# Developer edition: full engine, free for non-production. Swap to Microsoft.SQLServer.2022.Express if you prefer Express.
Install-WingetPackage -Id 'Microsoft.SQLServer.2022.Developer' -Locale 'en-US'
Install-WingetPackage -Id 'Microsoft.SQLServerManagementStudio.21'
Install-WingetPackage -Id 'Figma.Figma'
Install-WingetPackage -Id 'Microsoft.Teams'
Install-WingetPackage -Id '7zip.7zip'
Install-WingetPackage -Id 'Microsoft.DotNet.Framework.DeveloperPack_4'
Install-WingetPackage -Id 'Microsoft.DotNet.SDK.9'
Install-WingetPackage -Id 'Microsoft.Azure.FunctionsCoreTools'
Install-WingetPackage -Id 'Microsoft.AzureCLI'
Install-WingetPackage -Id 'Microsoft.AzureVPNClient'
Install-WingetPackage -Id 'GitHub.cli'
Install-WingetPackage -Id 'SlackTechnologies.Slack'
Install-WingetPackage -Id 'AgileBits.1Password'
Install-WingetPackage -Id 'Postman.Postman'

# --- Preference ---
Install-WingetPackage -Id 'Spotify.Spotify'
Install-WingetPackage -Id 'Zen-Team.Zen-Browser'
Install-WingetPackage -Id 'Notepad++.Notepad++'
Install-WingetPackage -Id 'mRemoteNG.mRemoteNG'
Install-WingetPackage -Id 'Discord.Discord'
Install-WingetPackage -Id 'WireGuard.WireGuard'
Install-WingetPackage -Id 'KeePassXCTeam.KeePassXC'
Install-WingetPackage -Id 'AgileBits.1Password.CLI'
Install-WingetPackage -Id 'mpv.net'
Install-WingetPackage -Id 'Microsoft.PowerToys'

Enable-NotepadPlusPlusDarkMode

# --- WSL2 + NixOS ---
if (-not $SkipWsl) {
    if (-not (Test-WslUsable)) {
        Write-Host 'Enabling WSL2 (no default distro; NixOS is installed next)...'
        & wsl.exe --install --no-distribution --web-download --no-launch
        Register-ResumeAfterReboot
        Write-Host 'A reboot is required to finish WSL2 setup. Rebooting in 15 seconds.'
        Write-Host 'The script will resume after you log in (UAC prompt).'
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit
    }

    Install-NixOSWsl -ApplyFlake:(-not $SkipNixFlake)
}

Write-Host 'Setup finished.'
