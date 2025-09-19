# Mandatory
winget install --id=Git.Git -e
winget install --id=Microsoft.VisualStudio.2022.Enterprise -e
winget install --id=Axosoft.GitKraken -e
winget install --id=Microsoft.SQLServer.2022.Express  -e
winget install --id=Microsoft.SQLServerManagementStudio  -e
winget install --id=Figma.Figma  -e
winget install --id=Microsoft.Teams -e
winget install --id=7zip.7zip  -e
winget install --id=Microsoft.DotNet.Framework.DeveloperPack_4  -e
winget install --id=Microsoft.DotNet.SDK.9
winget install --id=Microsoft.Azure.FunctionsCoreTools
winget install --id=SlackTechnologies.Slack  -e
winget install --id=AgileBits.1Password  -e
winget install --id=Postman.Postman  -e

# Preference
winget install --id=Spotify.Spotify -e
winget install --id=Zen-Team.Zen-Browser -e
# winget install --id=Mozilla.Firefox.MSIX  -e
# winget install --id=Google.Chrome  -e
winget install --id=mRemoteNG.mRemoteNG -e
# winget install --id=Notepad++.Notepad++  -e
# winget install --id=Microsoft.VisualStudioCode  -e
winget install --id=Discord.Discord -e
winget install --id=WireGuard.WireGuard  -e
# winget install --id=Netbird.Netbird  -e
# winget install --id=Tailscale.Tailscale  -e
winget install --id=KeePassXCTeam.KeePassXC  -e
winget install --id=AgileBits.1Password.CLI  -e
winget install --id=mpv.net  -e
winget install --id=Microsoft.PowerToys  -e
# winget install --id=Microsoft.PowerBI  -e

#WSL
$Distro = ""
if ($Distro -eq "nix") {
    curl.exe -L -o .\tmp\nixos.wsl https://github.com/nix-community/NixOS-WSL/releases/download/2505.7.0/nixos.wsl

    wsl --install --name wsl --from-file .\tmp\nixos.wsl

    wsl -s wsl
}
elseif ($Distro -eq "ubuntu") {
    winget install --id=Canonical.Ubuntu  -e ;
}
elseif ($Distro -eq "debian") {
    winget install --id=Debian.Debian  -e ;
}