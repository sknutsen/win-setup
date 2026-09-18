# Windows workstation setup

PowerShell bootstrap for a fresh Windows install. It installs the usual Windows apps with winget, enables **WSL2**, imports **NixOS-WSL**, and applies [sknutsen/nixconf](https://github.com/sknutsen/nixconf) as `nixosConfigurations.wsl`.

## Prerequisites

- Windows 10 (recent) or Windows 11
- An administrator account (UAC is fine; the script self-elevates)
- Internet
- **Virtualization enabled in firmware** (Intel VT-x / AMD-V). WSL2 will fail if this is off
- [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) so `winget` exists (included on current Windows 11)

BIOS/UEFI virtualization cannot be turned on by the script.

## Install

In PowerShell, from this repo:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\setup.ps1
```

On a machine that has never had WSL, Windows will reboot after enabling the WSL features. Log in again, accept UAC, and the script continues via RunOnce (it re-runs winget; already-installed packages are skipped).

The first NixOS rebuild from GitHub can take a long time.

### Options

| Flag | Effect |
| --- | --- |
| `-SkipWsl` | Windows apps only; no WSL / NixOS |
| `-SkipNixFlake` | Install the stock NixOS-WSL distro, but do not apply `nixconf` |
| `-Resume` | Used after the WSL reboot; you do not need to pass this yourself |

## What gets installed

### Windows (winget)

- Git, GitKraken, GitHub CLI
- Visual Studio 2026 Enterprise (Managed Desktop, ASP.NET, Azure, Data workloads + recommended components + WCF tooling)
- Claude Code
- SQL Server 2025 **Developer** (full engine, not for production) and SSMS 22
- Azure CLI, Azure VPN Client, Azure Functions Core Tools
- .NET SDK 10 and .NET Framework 4 developer pack
- Zen Browser, Spotify, Notepad++ (dark mode / DarkModeDefault)
- Teams, Figma, Discord, Bruno
- 7zip, WireGuard, KeePassXC, PowerToys, mRemoteNG, mpv.net, Docker Desktop

SQL Server Express instead of Developer: in `setup.ps1`, change `Microsoft.SQLServer.2025.Developer` to `Microsoft.SQLServer.2025.Express`.

### WSL2 + NixOS

1. `wsl --install --no-distribution` (no Ubuntu)
2. Latest [NixOS-WSL](https://github.com/nix-community/NixOS-WSL) `.wsl` image
3. Distro registered as **`NixOS`**
4. `nixos-rebuild boot --flake github:sknutsen/nixconf#wsl`
5. Distro restarted so `wsl.defaultUser` becomes `zdk` (must use `boot`, not `switch`)
6. Flake cloned to `~/.nixconf` for local edits

Open it with:

```powershell
wsl -d NixOS
```

Later rebuilds, from inside NixOS:

```bash
sudo nixos-rebuild switch --flake ~/.nixconf#wsl
```

Windows-native apps (VS, SSMS, Azure VPN, Spotify, Zen, Notepad++) stay on Windows. The NixOS side is the Linux CLI/dev environment from nixconf.

## After install

- Sign in to Claude Code (`claude`), GitHub CLI (`gh auth login`), Azure CLI (`az login`)
- Import an Azure VPN profile in Azure VPN Client if you use point-to-site
- First SSMS connection: `localhost` with Windows Authentication
- If Notepad++ is still light, enable **Settings → Preferences → Dark Mode** (the script patches `config.xml` only when Notepad++ is not running)

## Nix flake (nixconf)

`setup.ps1` expects `nixosConfigurations.wsl` on [github:sknutsen/nixconf](https://github.com/sknutsen/nixconf). That host already exists as a stub; it needs a proper WSL configuration (no Hyprland, no hardware-configuration, `wsl.defaultUser = "zdk"`).

Copy [`nixconf-wsl-prompt.md`](./nixconf-wsl-prompt.md) into a chat in the **nixconf** repo and have an agent apply those changes **before** relying on the automatic flake apply. You can still install Windows apps first with `.\setup.ps1 -SkipNixFlake` and apply the flake yourself after nixconf is updated.
