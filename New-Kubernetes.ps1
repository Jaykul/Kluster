<#
    .SYNOPSIS
        Creates a new kubernetes cluster with RBAC and multi-nodepool capability
#>
[CmdletBinding()]
param(
    # The location (where to create your resource group)
    [Parameter(Mandatory)]
    $Location,

    # The name of the resource group that contains the AKS cluster
    [Parameter(Mandatory)]
    $ResourceGroup,

    # The name of the Kubernetes cluster
    [Parameter(Mandatory)]
    $ClusterName,

    # The version of kubernetes to use.
    #
    # Azure's default is always set to the n-1 minor version and latest patch.
    # For example, if AKS supports 1.11.x, 1.10.a + 1.10.b, 1.9.c + 1.9d, 1.8.e + 1.8f
    # The default version for new clusters is 1.10.b rather than 1.11.x
    #
    # Listing versions still isn't possible in the PowerShell module, Run something like:
    # az aks get-versions --location eastus --output table
    $KubernetesVersion = "1.19.6",

    # The VM size to use for system nodes
    # Our default is Standard_B2s which is the smallest that will work (2cpu, 4GB)
    # (normally the default is DS_V2)
    $SystemNodeVMSize = "standard_b2s",

    # The number of VMs to start with (you can --Scale-Up later)
    $SystemNodeCount = 2,

    # The VM size to use for an additional node pool
    # My default is standard_d2s_v4 (4cpu, 16Gb)
    $AdditionalNodeVMSize = "standard_d2s_v4",

    # The number of nodes to put in the user node pool
    # The default is 0, so no additional pool is created!
    $AdditionalNodeCount = 0,

    # The name of a node pool must start with a lowercase letter and can only contain alphanumeric characters.
    # For windows node pools the length must be between 1 and 6 characters, so I'm always enforcing that
    # (for Linux node pools the length could be between 1 and 12 characters)
    # The default is based on the user node VM size and may not always work
    [ValidateScript({
        if ($_ -cmatch "^[a-z][a-zA-Z0-9]{1,6}$") {
            $true
        } else {
            throw "Node pool names must start with a lowercase letter and can only contain alphanumeric characters"
        }
    })]
    $AdditionalNodePoolName = $($AdditionalNodeVMSize -replace "standard" -replace "[_\d]"),

    # The OS for the additional node pool (defaults to Linux)
    [ValidateSet("Linux", "Windows")]
    $AdditionalNodeOS = "Linux",

    # The name of an administrators group (you MUST pre-create this in AzureAD)
    $KubernetesAdminGroup = "AksAdmins"

    # $ADTenantId = "b3714c3f-ecbc-453f-8ae4-ddeeb141a966",

    # $ServerAppSecret  = "QXi/eauuNdSZGq1Eg1LIQFyC0pKjVtrsVr+GumXXJaY="
)

if(!(Get-Command az)) {
    throw "You need the Azure commandline tool 'az' in your path. https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
}

Push-Location $PSScriptRoot
.\Repair-KubeCtl.ps1

# Don't do this if it was already done
if ("false" -eq (az group exists --name $ResourceGroup)) {
    # Create the resource group
    az group create --name $ResourceGroup --location $Location
}

# Don't do this if it was already done
if (!(az acr list --resource-group $ResourceGroup --query "[?displayName=='${ResourceGroup}HelmAcr']")) {
    # Create a container registry so we can use Helm
    az acr create --resource-group $ResourceGroup --name ${ResourceGroup}HelmAcr --sku Basic
}

if (!($me = az ad signed-in-user show | ConvertFrom-Json) -or -not $me.objectId) {
    Write-Error "Without self identity, we can't set up RBAC properly"
    return
}

# Don't do this if it was already done
if (!($adminGroup = az ad group list --query "[?displayName=='$KubernetesAdminGroup']" | ConvertFrom-Json)) {
    # Create an administrators group in Azure AD (if you haven't got AzureAD configured already)
    az ad group create --display-name $KubernetesAdminGroup --mail-nickname $KubernetesAdminGroup --description "Kubernetes Admins"

    if (!($adminGroup = az ad group list --query "[?displayName=='$KubernetesAdminGroup']" | ConvertFrom-Json)) {
        Write-Error "Error creating admin group '$KubernetesAdminGroup'"
        return
    }

    az ad group member add --group $KubernetesAdminGroup --member-id $me.objectId
}

# THE OLD WAY REQUIRES SETTING UP AN APPLICATION
# # Since I created the AKSServer application, I can just re-use it....
# if (!($AKSServer = az ad app list --display-name AKSServer | ConvertFrom-Json)) {
#     # The script in here doesn't actually work yet
#     & $PSScriptRoot\Initialize-AzureAD.ps1 -ServerAppSecret $ServerAppSecret
#     $AKSServer = az ad app list --display-name AKSServer | ConvertFrom-Json
# }
# $AKSClient = az ad app list --display-name AKSClient | ConvertFrom-Json

# Don't do this if we already have a Kubernetes cluster
if (!(az aks get-upgrades --resource-group $ResourceGroup --name $ClusterName | ConvertFrom-Json)) {
    Write-Warning "Creating AKS cluster with $SystemNodeCount $SystemNodeVMSize VMs in the system node pool"

    # Create the AKS (Azure Kubernetes Service)
    # BE SURE TO SPECIFY: 1. The version (because the default is ancient) 2. The vm-size (because the default is DS_V2)
    az aks create `
        --resource-group $ResourceGroup `
        --name $ClusterName `
        --enable-aad `
        --aad-admin-group-object-ids $adminGroup.objectId `
        --generate-ssh-keys `
        --vm-set-type VirtualMachineScaleSets `
        --kubernetes-version $KubernetesVersion `
        --node-count $SystemNodeCount `
        --node-vm-size $SystemNodeVMSize `
        --enable-addons monitoring `
        --load-balancer-sku standard
        # --aad-server-app-id $AKSServer.AppId `
        # --aad-server-app-secret $ServerAppSecret `
        # --aad-client-app-id $AKSClient.AppId `
        # --aad-tenant-id $ADTenantId `

    ## Then, fetch the normal user credentials for kubectl
    az aks get-credentials --resource-group $ResourceGroup --name $ClusterName
    # Create a cluster role binding so we can access the dashboard
    kubectl create clusterrolebinding kubernetes-dashboard -n kube-system --clusterrole=cluster-admin --serviceaccount=kube-system:kubernetes-dashboard
}


if ($AdditionalNodeCount -gt 0) {
    Write-Warning "Creating additional node pool $AdditionalNodePoolName with $AdditionalNodeCount $AdditionalNodeVmSize VMs in it"

    az aks nodepool add `
        --resource-group $ResourceGroup `
        --cluster-name $ClusterName `
        --name $AdditionalNodePoolName `
        --node-count $AdditionalNodeCount `
        --node-vm-size $AdditionalNodeVMSize `
        --os-type $AdditionalNodeOS `
        --kubernetes-version $KubernetesVersion
}

Pop-Location