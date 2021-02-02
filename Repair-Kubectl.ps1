[CmdletBinding()]
param([switch]$Force)

if (!(Get-Command az)) {
    throw "You need the Azure commandline tool 'az' in your path. https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
}
if ($Force -or -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    # The Azure CLI tools have installed kubectl in a bewildering array of different places over the years
    # Now they're adding kubelogin, and they're spraying that around too.
    # I'm going to pick ONE PLACE to put them, but search the latest default install locations too

    $ToolsPath = "~\.tools\", "~\.azure-kubectl\", "~\.azure-kubelogin\",
                (Join-Path (Split-Path $Profile.CurrentUserAllHosts) "Tools")

    if ($kubectl = Get-ChildItem $ToolsPath -Filter kubectl.exe -ErrorAction SilentlyContinue) {
        ## Alias it, because it's always in a stupid path location
        Set-Alias kubectl $kubectl[0] -Scope global
        Write-Warning "kubectl found in '$($kubectl[0].Definition)' -- adding it to your path for this session."
        $Env:Path += ';' + (Split-Path $kubectl[0].Definition)
    }
    if ($kubelogin = Get-ChildItem $ToolsPath -Filter kubelogin.exe -ErrorAction SilentlyContinue) {
        ## Alias it, because it's always in a stupid path location
        Set-Alias kubelogin $kubelogin[0] -Scope global
        Write-Warning "kubelogin found in '$($kubelogin[0].Definition)' -- adding it to your path for this session."
        $Env:Path += ';' + (Split-Path $kubelogin[0].Definition)
    }

    if (-not $kubectl -or -not $kubelogin) {
        Write-Warning "You need the kubernetes control and login tools in your path"

        $ToolsPath = New-Item -Path "~\.tools\" -ItemType Directory -Force | Convert-Path
        if ($PSCmdlet.ShouldContinue("Install kubectl to $ToolsPath", "Install kubectl?")) {
            az aks install-cli --install-location $ToolsPath\kubectl.exe --kubelogin-install-location $ToolsPath\kubelogin.exe
            if (!($Env:Path -split [IO.Path]::PathSeparator -contains $ToolsPath)) {
                Write-Warning "Adding '$ToolsPath' to your path for this session. You should add it permanently"
                $Env:Path += ';' + $ToolsPath
            }
        } else {
            return
        }
    }
}