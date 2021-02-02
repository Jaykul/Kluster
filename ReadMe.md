# My latest experiment with Azure Kubernetes Service (AKS)

So far, in order to create Azure Kubernetes Services, you *must* start with the Azure CLI. The Az.Aks PowerShell module is so far behind that it's not even able to specify all the parameters we need for creating the cluster, nevermind managing it. Since that's the case, I'll use the `az` command-lines for everything, instead of requiring any Azure modules.

Start by [installing the **latest** Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) and [Helm](https://github.com/helm/helm), probably from chocolatey.

Before we get to the scripts, a couple of points:

## We _can_ use Windows Server containers on Azure Kubernetes Service now

The important thing you have to know is that if you want to be able to have Windows containers, you have to create a [multiple node pool](https://docs.microsoft.com/en-us/azure/aks/use-multiple-node-pools) cluster. In this configuration, the _first node pool_ must be Linux (so we can run the kubernetes services on it), and _you can't delete the first node pool_.

I'm going to provision it with a single (tiny) system pool which I can use for learning and practicing, and then I'll add and remove additional pools when I need them to actually host something.  There's an added cost for this, because it has to use a "standard" load balancer sku, but I think it will be worth it -- and I'll make up for it somewhat by using a smaller system nodepool when I'm not actually hosting anything but matterbridge in here.

In the `New-Kubernetes` script I create a small nodepool with just 2 burstable servers for the first nodepool.

## Use Role-Based Access Control (RBAC) from the beginning

The easiest way to do that is to use the new [_Managed Azure AD_ integrattion](https://docs.microsoft.com/en-us/azure/aks/managed-aad), but if you do, you'll be locked in. As an alternative, you can [set up RBAC manually](https://docs.microsoft.com/en-us/azure/aks/azure-ad-integration-cli).

# Installation

The short version is: _read through_, and then run [`.\New-Kubernetes.ps1`](./New-Kubernetes.ps1)

## For hosting HTTPS services, we need an ingress controller

This is based on Microsoft's recommendation for [configuring an HTTPS ingress controller](https://docs.microsoft.com/en-us/azure/aks/ingress-tls), but see also the [cert-manager installation docs](https://cert-manager.io/docs/installation/) and their tutorial on [securing nginx Ingress](https://cert-manager.io/docs/tutorials/acme/ingress/#step-5-deploy-cert-manager).

We have to deploy nginx and cert-manager using Helm, and configure cert-manager to use LetsEncrypt to issue certificates for anything that needs them. _Read through_, and then run [`.\New-Ingress.ps1`](./New-Ingress.ps1)
