#Requires -Version 5.1
<#
.SYNOPSIS
  Bootstrap a fresh Windows 11+ install: apps, personalization, WSL2, and NixOS from github:sknutsen/nixconf#wsl.

.PARAMETER Resume
  Continues after the WSL feature reboot. Set automatically via RunOnce.

.PARAMETER SkipWsl
  Skip WSL / NixOS entirely.

.PARAMETER SkipNixFlake
  Install the NixOS-WSL distro but do not apply the nixconf flake.

.PARAMETER SkipPersonalization
  Skip theme / taskbar registry tweaks.
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$SkipWsl,
    [switch]$SkipNixFlake,
    [switch]$SkipPersonalization
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Match nixosConfigurations.wsl in https://github.com/sknutsen/nixconf
$WslDistroName = 'NixOS'
$NixFlake      = 'github:sknutsen/nixconf#wsl'
$NixconfClone  = 'https://github.com/sknutsen/nixconf.git'

# Windows 11 personalization (HKCU). Edit these to taste.
$Personalization = @{
    DarkTheme            = $true
    TaskbarAlignLeft     = $true
    SearchMode           = 0       # 0 = hidden, 1 = icon, 2 = search box
    HideTaskView         = $true
    HideWidgets          = $true
    HideChat             = $true   # Taskbar Chat / Copilot button
    NeverCombineTaskbar  = $true   # Show labels; never group app windows
    SmallTaskbarButtons  = $true
    # Multi-monitor: 1 = main taskbar + where window is open (0 = all, 2 = where open only)
    MMTaskbarAppsMode    = 1
    AccentBlue           = $true   # Windows blue (#0078D4)
    NoTransparency       = $true
    NightLightAlways     = $true   # Schedule 00:00-23:59 + force on
    StartHideRecentApps  = $true
    StartHideFrequent    = $true
    StartHideRecommendedFiles = $true
    StartHideRecommendations  = $true
    StartShowSettingsAndExplorer = $true  # Folders next to power button
}

$WingetAlreadyInstalled = @(-1978335189, -1978335135)

function Assert-Windows11 {
    $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem).BuildNumber
    if ($build -lt 22000) {
        throw "Windows 11 or later required (build >= 22000). This OS reports build $build."
    }
}

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
    if ($SkipPersonalization) { $args += '-SkipPersonalization' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args
    exit
}

function Register-ResumeAfterReboot {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"
    if ($SkipWsl) { $cmd += ' -SkipWsl' }
    if ($SkipNixFlake) { $cmd += ' -SkipNixFlake' }
    if ($SkipPersonalization) { $cmd += ' -SkipPersonalization' }
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'WinSetupResume' -Value $cmd
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegistryBinary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][byte[]]$Value
    )
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType Binary -Force | Out-Null
}

function Enable-NightLightAlwaysOn {
    # CloudStore binary format: all-day schedule + force active. Best-effort on fresh installs.
    $settingsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings\windows.data.bluelightreduction.settings'
    $statePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate'

    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $settings = [System.Collections.Generic.List[byte]]::new()
    $settings.AddRange([byte[]](0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06))
    $settings.Add([byte](($epoch -band 0x7F) -bor 0x80))
    $settings.Add([byte]((($epoch -shr 7) -band 0x7F) -bor 0x80))
    $settings.Add([byte]((($epoch -shr 14) -band 0x7F) -bor 0x80))
    $settings.Add([byte]((($epoch -shr 21) -band 0x7F) -bor 0x80))
    $settings.Add([byte]($epoch -shr 28))
    # Schedule active + explicit hours 00:00-23:59, ~4000K
    $kelvin = 4000
    $tempLo = [byte]((($kelvin -band 0x3F) * 2) + 0x80)
    $tempHi = [byte]($kelvin -shr 6)
    $settings.AddRange([byte[]](
        0x2A, 0x2B, 0x0E, 0x1F, 0x43, 0x42, 0x01, 0x00,
        0x02, 0x01, 0xC2, 0x0A, 0x00,
        0xCA, 0x14, 0x0E, 0x00, 0x2E, 0x00, 0x00,
        0xCA, 0x1E, 0x0E, 0x17, 0x2E, 0x3B, 0x00,
        0xCF, 0x28, $tempLo, $tempHi,
        0xCA, 0x32, 0x00, 0xCA, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00
    ))
    Set-RegistryBinary -Path $settingsPath -Name 'Data' -Value $settings.ToArray()

    $state = [System.Collections.Generic.List[byte]]::new()
    $state.AddRange([byte[]](0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06))
    $state.Add([byte](($epoch -band 0x7F) -bor 0x80))
    $state.Add([byte]((($epoch -shr 7) -band 0x7F) -bor 0x80))
    $state.Add([byte]((($epoch -shr 14) -band 0x7F) -bor 0x80))
    $state.Add([byte]((($epoch -shr 21) -band 0x7F) -bor 0x80))
    $state.Add([byte]($epoch -shr 28))
    # Active (10 00) + manually transitioned
    $state.AddRange([byte[]](
        0x2A, 0x2B, 0x0E, 0x15, 0x43, 0x42, 0x01, 0x00,
        0x10, 0x00, 0xD0, 0x0A, 0x02,
        0xC6, 0x14, 0xA9, 0xA5, 0x92, 0xA4, 0xF6, 0xE1, 0x80, 0xED, 0x01,
        0x00, 0x00, 0x00, 0x00
    ))
    Set-RegistryBinary -Path $statePath -Name 'Data' -Value $state.ToArray()
}

function Set-WindowsPersonalization {
    param([hashtable]$Prefs)

    Write-Host 'Applying Windows 11 personalization...'

    $theme = if ($Prefs.DarkTheme) { 0 } else { 1 }
    $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-RegistryDword -Path $personalize -Name 'AppsUseLightTheme' -Value $theme
    Set-RegistryDword -Path $personalize -Name 'SystemUsesLightTheme' -Value $theme
    if ($Prefs.NoTransparency) {
        Set-RegistryDword -Path $personalize -Name 'EnableTransparency' -Value 0
    }

    if ($Prefs.AccentBlue) {
        # Windows blue #0078D4 stored as ABGR DWORD + AccentPalette (RGBA slots)
        $accentPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
        $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
        Set-RegistryDword -Path 'HKCU:\Control Panel\Desktop' -Name 'AutoColorization' -Value 0
        Set-RegistryDword -Path $personalize -Name 'ColorPrevalence' -Value 1
        Set-RegistryDword -Path $dwm -Name 'ColorPrevalence' -Value 1
        Set-RegistryDword -Path $dwm -Name 'AccentColor' -Value 0xFFD47800
        Set-RegistryDword -Path $dwm -Name 'ColorizationColor' -Value 0xC40078D4
        Set-RegistryDword -Path $dwm -Name 'ColorizationAfterglow' -Value 0xC40078D4
        Set-RegistryDword -Path $accentPath -Name 'AccentColorMenu' -Value 0xFFD47800
        Set-RegistryDword -Path $accentPath -Name 'StartColorMenu' -Value 0xFFBA5F00
        Set-RegistryBinary -Path $accentPath -Name 'AccentPalette' -Value ([byte[]](
            0x99, 0xEB, 0xFF, 0x00,
            0x61, 0xCC, 0xFF, 0x00,
            0x00, 0x93, 0xFC, 0x00,
            0x00, 0x78, 0xD4, 0x00,
            0x00, 0x5F, 0xBA, 0x00,
            0x00, 0x3F, 0x95, 0x00,
            0x00, 0x1A, 0x6A, 0x00,
            0x88, 0x17, 0x98, 0x00
        ))
    }

    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegistryDword -Path $advanced -Name 'TaskbarAl' -Value $(if ($Prefs.TaskbarAlignLeft) { 0 } else { 1 })
    Set-RegistryDword -Path $advanced -Name 'ShowTaskViewButton' -Value $(if ($Prefs.HideTaskView) { 0 } else { 1 })
    Set-RegistryDword -Path $advanced -Name 'TaskbarDa' -Value $(if ($Prefs.HideWidgets) { 0 } else { 1 })
    Set-RegistryDword -Path $advanced -Name 'TaskbarMn' -Value $(if ($Prefs.HideChat) { 0 } else { 1 })
    if ($Prefs.NeverCombineTaskbar) {
        Set-RegistryDword -Path $advanced -Name 'TaskbarGlomLevel' -Value 2
        Set-RegistryDword -Path $advanced -Name 'MMTaskbarGlomLevel' -Value 2
    }
    if ($Prefs.SmallTaskbarButtons) {
        Set-RegistryDword -Path $advanced -Name 'TaskbarSi' -Value 0
    }
    if ($null -ne $Prefs.MMTaskbarAppsMode) {
        Set-RegistryDword -Path $advanced -Name 'MMTaskbarEnabled' -Value 1
        Set-RegistryDword -Path $advanced -Name 'MMTaskbarMode' -Value ([int]$Prefs.MMTaskbarAppsMode)
    }

    $searchMode = [int]$Prefs.SearchMode
    if ($searchMode -lt 0 -or $searchMode -gt 2) { $searchMode = 0 }
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value $searchMode

    $start = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'
    if ($Prefs.StartHideRecentApps) {
        Set-RegistryDword -Path $start -Name 'ShowRecentList' -Value 0
    }
    if ($Prefs.StartHideFrequent) {
        Set-RegistryDword -Path $start -Name 'ShowFrequentList' -Value 0
    }
    if ($Prefs.StartHideRecommendedFiles) {
        Set-RegistryDword -Path $advanced -Name 'Start_TrackDocs' -Value 0
    }
    if ($Prefs.StartHideRecommendations) {
        Set-RegistryDword -Path $advanced -Name 'Start_IrisRecommendations' -Value 0
    }
    if ($Prefs.StartShowSettingsAndExplorer) {
        # Explorer {148A24BC-...} then Settings {52730886-...}
        Set-RegistryBinary -Path $start -Name 'VisiblePlaces' -Value ([byte[]](
            0xBC, 0x24, 0x8A, 0x14, 0x0C, 0xD6, 0x89, 0x42, 0xA0, 0x80, 0x6E, 0xD9, 0xBB, 0xA2, 0x48, 0x82,
            0x86, 0x08, 0x73, 0x52, 0xAA, 0x51, 0x43, 0x42, 0x9F, 0x7B, 0x27, 0x76, 0x58, 0x46, 0x59, 0xD4
        ))
        Set-RegistryDword -Path $start -Name 'PlacesInitializedVersion' -Value 2
    }

    if ($Prefs.NightLightAlways) {
        try {
            Enable-NightLightAlwaysOn
        }
        catch {
            Write-Warning "Night Light could not be enabled automatically (open Settings > System > Display once, then re-run). $_"
        }
    }

    # Restart Explorer so taskbar/theme chrome pick up HKCU changes.
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
    }
    catch {
        Write-Warning "Could not restart Explorer; sign out or reboot for personalization to fully apply. $_"
    }

    Write-Host 'Personalization applied.'
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
Assert-Windows11

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget not found. Install "App Installer" from the Microsoft Store and re-run.'
}

Write-Host 'Accepting winget source agreements...'
& winget source update --disable-interactivity | Out-Null

# --- Mandatory ---
Install-WingetPackage -Id 'Git.Git'
Install-WingetPackage -Id 'Microsoft.VisualStudio.Enterprise' -Override '--passive --wait --includeRecommended --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.NetWeb --add Microsoft.VisualStudio.Workload.Azure --add Microsoft.VisualStudio.Workload.Data --add Microsoft.VisualStudio.Component.Wcf.Tooling'
Install-WingetPackage -Id 'Anthropic.ClaudeCode'
Install-WingetPackage -Id 'Axosoft.GitKraken'
# Developer edition: full engine, free for non-production. Swap to Microsoft.SQLServer.2025.Express if you prefer Express.
Install-WingetPackage -Id 'Microsoft.SQLServer.2025.Developer' -Locale 'en-US'
Install-WingetPackage -Id 'Microsoft.SQLServerManagementStudio.22'
Install-WingetPackage -Id 'Microsoft.PowerBI'
Install-WingetPackage -Id 'Figma.Figma'
Install-WingetPackage -Id 'Microsoft.Teams'
Install-WingetPackage -Id '7zip.7zip'
Install-WingetPackage -Id 'Microsoft.DotNet.Framework.DeveloperPack_4'
Install-WingetPackage -Id 'Microsoft.DotNet.SDK.10'
Install-WingetPackage -Id 'Microsoft.Azure.FunctionsCoreTools'
Install-WingetPackage -Id 'Microsoft.AzureCLI'
Install-WingetPackage -Id 'Microsoft.AzureVPNClient'
Install-WingetPackage -Id 'GitHub.cli'
Install-WingetPackage -Id 'Bruno.Bruno'

# --- Preference ---
Install-WingetPackage -Id 'Spotify.Spotify'
Install-WingetPackage -Id 'Zen-Team.Zen-Browser'
Install-WingetPackage -Id 'ImputNet.Helium'
Install-WingetPackage -Id 'Notepad++.Notepad++'
Install-WingetPackage -Id 'mRemoteNG.mRemoteNG'
Install-WingetPackage -Id 'TeamViewer.TeamViewer'
Install-WingetPackage -Id 'WireGuard.WireGuard'
Install-WingetPackage -Id 'Tailscale.Tailscale'
Install-WingetPackage -Id 'KeePassXCTeam.KeePassXC'
Install-WingetPackage -Id 'mpv.net'
Install-WingetPackage -Id 'Microsoft.PowerToys'
Install-WingetPackage -Id 'BillStewart.SyncthingWindowsSetup'
Install-WingetPackage -Id 'Docker.DockerDesktop'

Enable-NotepadPlusPlusDarkMode

if (-not $SkipPersonalization) {
    Set-WindowsPersonalization -Prefs $Personalization
}

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
