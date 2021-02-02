<#
.Notes
    Based on https://docs.microsoft.com/en-us/azure/aks/ingress-static-ip

    To cleanly uninstall all of this, you need to run it through in reverse order:

        kubectl delete -f cluster-issuer.yaml
        helm uninstall cert-manager --namespace cert-manager
        helm uninstall nginx-ingress --namespace ingress
#>
[CmdletBinding(DefaultParameterSetName = "DynamicIP")]
param(
    # The name of the resource group that contains the AKS cluster
    [Parameter(Mandatory)]
    $ResourceGroup,

    # The name of the Kubernetes cluster
    [Parameter(Mandatory)]
    $ClusterName,

    # A DNS name for the ingress
    $DnsName = $($ClusterName.ToLower() + "-ingress"),

    # If set, use a dynamic public IP Address instead of a static one
    [switch]$DynamicIP,

    # If set, redeploy the helm charts even if we find the services already. Don't do this.
    [switch]$Force
)
if (!($Region = (az group show --resource-group $ResourceGroup | ConvertFrom-Json).location)) {
    throw "Couldn't get location from ResourceGroup $Resourcegroup"
}

# we need to create the IP address in the AKS resource group
$ResourceGroup = "MC_${ResourceGroup}_${ClusterName}_${Region}"
if (!(az group show --resource-group $ResourceGroup | ConvertFrom-Json)) {
    throw "Couldn't find the calculated ResourceGroup $Resourcegroup"
}

if (Resolve-DnsName "$DnsName.$Region.cloudapp.azure.com" -ErrorAction SilentlyContinue) {
    if(!$PSCmdlet.ShouldContinue("Are you re-applying this ingress?", "DNSName taken: $DnsName")) {
        throw "Can't use '$DnsName.$Region.cloudapp.azure.com' because it's already taken."
    }
}

Push-Location $PSScriptRoot
.\Repair-KubeCtl.ps1

# register the nginx repo in helm:
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
# update our local cache
helm repo update


$Namespace = "ingress"
## https://docs.microsoft.com/en-us/azure/aks/ingress-tls
# Create a namespace for your ingress resources
if (!(kubectl get namespaces -o "jsonpath={.items[?(@.metadata.name=='$Namespace')]}")) {
    kubectl create namespace $Namespace
}

if ($Force -or -not ($nginx = kubectl get service --namespace $Namespace nginx-ingress-ingress-nginx-controller -o json | ConvertFrom-Json)) {
    if ($DynamicIP) {
        # Use Helm to deploy an NGINX ingress controller WITHOUT the static IP
        helm install nginx-ingress ingress-nginx/ingress-nginx `
            --namespace $Namespace `
            --set controller.replicaCount=2 `
            --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"=$dnsname
    } else {
        ## First, make a static IP address
        if (!($AksIPAddress = az network public-ip list --resource-group $ResourceGroup --query "[?name=='${ClusterName}_IP']" | ConvertFrom-Json)) {
            $AksIPAddress = az network public-ip create --name "$($ClusterName)_IP" --sku Standard --resource-group $ResourceGroup --allocation-method static | ConvertFrom-Json
        }
        $ipAddress = $AksIPAddress.ipAddress
        if (!$ipAddress) {
            Write-Error "Could not get IPAddress!"
            return
        } else {
            Write-Warning "Using IPAddress '$ipAddress'"
        }
        # Use Helm to deploy an NGINX ingress controller
        helm install nginx-ingress ingress-nginx/ingress-nginx `
            --namespace $Namespace `
            --set controller.replicaCount=2 `
            --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux `
            --set controller.service.loadBalancerIP="$ipAddress" `
            --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-dns-label-name"="$dnsname"
    }
}

$Namespace = 'cert-manager'
if (!(kubectl get namespaces -o "jsonpath={.items[?(@.metadata.name=='$Namespace')]}")) {
    kubectl create namespace $Namespace
    # Label the cert-manager namespace to disable resource validation
    kubectl label namespace $Namespace cert-manager.io/disable-validation=true
}


if ($Force -or -not (kubectl get service --namespace $Namespace cert-manager -o json | ConvertFrom-Json)) {
    # Install the cert-manager Helm chart
    helm install cert-manager `
        --namespace $Namespace `
        --version v1.1.0 `
        --set installCRDs=true `
        --set nodeSelector."beta\.kubernetes\.io/os"=linux `
        jetstack/cert-manager

    Write-Progress "Waiting for cert-manager deployment"
    Start-Sleep 5
    $Start = Get-Date
    while (!((kubectl get service --namespace $Namespace cert-manager -o json | ConvertFrom-Json))) {
        Write-Progress "Waiting for cert-manager deployment"
        Start-Sleep -milli 500
        if (((Get-Date) - $Start) -gt [TimeSpan]::FromMinutes(2)) {
            Write-Warning "cert-manager failed to finish after 2 minutes. `nYou'll need to run the command by hand:`n$([char]27)[39m`nkubectl apply --namespace $Namespace -f cluster-issuer.yaml"
            return
        }
    }
    Write-Progress "Waiting for cert-manager deployment" -Completed

    kubectl apply --namespace $Namespace -f cluster-issuer.yaml
}