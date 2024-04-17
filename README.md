# AV Resimulation on Azure playground

## Introduction
This repository contains a blueprint for an AV resimulation architecture on AKS. Please refer to the [AVOps Design Guide](https://learn.microsoft.com/en-us/azure/architecture/solution-ideas/articles/avops-architecture#valops)


## Pre-requisites

* An Azure Subscription
* A dedicated Azure Resource Group
* An Azure Virtual Network with at least /15 CIDR address space
* Quota for a GPU accelerated SKU on Azure
* A client with Azure CLI installed. 

## Define variables

These variables needs to be defined with your specific values. These will be used then in all the deployment phases:

```bash
export RESOURCE_GROUP_NAME=
export AKS_CLUSTER_NAME=
export LOCATION=
export VIRTUAL_NETWORK_NAME=
export VIRTUAL_NETWORK_ID=
export SUBNET_NAME=
export SUBNET_ID="$VIRTUAL_NETWORK_ID/subnets/$SUBNET_NAME"
export ACR_NAME=
```

## Login in Azure CLI

Here we will assume that we are using an Azure VM with a System Assigned Identity enabled and being Owner on the Resource Group.

```bash
az login --identity
```

## Create Azure Kuberentes Cluster

As a first step let's create an AKS cluster in private networking mode, on-boarding the existing Virtual Network. We are going also to use Azure RBAC with AAD integration for access/authorization management.

```bash
az aks create --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_NAME --node-count 2 --generate-ssh-keys --enable-private-cluster --vnet-subnet-id $SUBNET_ID --enable-aad --enable-azure-rbac --tier free --kubernetes-version 1.28.5 --auto-upgrade-channel none --network-plugin azure --network-policy calico
```

## Create Azure Container Registry

```bash
az acr create --resource-group $RESOURCE_GROUP_NAME --name $ACR_NAME --sku Premium --allow-trusted-services false --default-action deny --public-network-enabled false

az network private-dns zone create --resource-group $RESOURCE_GROUP_NAME --name "privatelink.azurecr.io"

az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP_NAME \
  --zone-name "privatelink.azurecr.io" \
  --name MyDNSLink \
  --virtual-network $VIRTUAL_NETWORK_NAME \
  --registration-enabled false
  
REGISTRY_ID=$(az acr show --name $ACR_NAME \
  --query 'id' --output tsv)

az network private-endpoint create \
    --name acr-pe \
    --resource-group $RESOURCE_GROUP_NAME \
    --vnet-name $VIRTUAL_NETWORK_NAME \
    --subnet $SUBNET_NAME \
    --private-connection-resource-id $REGISTRY_ID \
    --group-ids registry \
    --connection-name myConnection
```

## Attach Azure Container registry to the Azure Kubernetes Cluster

```bash
az aks update --name $AKS_CLUSTER_NAME --resource-group  $RESOURCE_GROUP_NAME --attach-acr $ACR_NAME
```

## Assign the dedicated permissions to the Service Principal (case of using an Azure VM as client)

```bash
AKS_ID=$(az aks show -g $RESOURCE_GROUP_NAME -n $AKS_CLUSTER_NAME --query id -o tsv)
VM_NAME=$(curl --connect-timeout 10 -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2018-04-02" | jq '.compute.name' | sed 's/"//g')
VM_RESOURCE_GROUP=$(curl --connect-timeout 10 -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2018-04-02" | jq '.compute.resourceGroupName' | sed 's/"//g')
SERVICE_PRINCIPAL_VM=$(az vm show -g $VM_RESOURCE_GROUP -n $VM_NAME | jq .identity.principalId | sed 's/"//g')

az role assignment create --role "Azure Kubernetes Service RBAC Cluster Admin" --assignee $SERVICE_PRINCIPAL_VM --scope $AKS_ID

az logout
az login --identity
```

## Install K9S (optional)

```bash
wget "https://github.com/derailed/k9s/releases/download/v0.31.9/k9s_linux_amd64.deb"
dpkg -i k9s_linux_amd64.deb
```

## Install kubectl and enable authentication

```bash
az aks install-cli
az aks get-credentials --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_NAME
```

Modify `$HOME/.kubectl/config` updating the login mode:

```yaml
...
- --login
- azurecli # Modify the login mode to azurecli
command: kubelogin
...
```

## Create a GPU Node Pool without NVIDIA Driver installation enabled

```bash
 az aks nodepool add \
    --resource-group $RESOURCE_GROUP_NAME \
    --cluster-name $AKS_CLUSTER_NAME \
    --name nc4ast4 \
    --node-taints sku=gpu:NoSchedule \
    --node-vm-size Standard_NC4as_T4_v3 \
    --enable-cluster-autoscaler \
    --min-count 1 --max-count 5 --node-count 1 --tags SkipGPUDriverInstall=True --priority Spot
```

## Install HELM

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 \
    && chmod 700 get_helm.sh \
    && ./get_helm.sh
```

## Install Node Feature Discovery


```bash
helm install --wait --create-namespace \
    -n gpu-operator node-feature-discovery node-feature-discovery \
    --create-namespace    --repo https://kubernetes-sigs.github.io/node-feature-discovery/charts   \
     --set-json master.config.extraLabelNs='["nvidia.com"]'  \
    --set-json worker.tolerations='[{ "effect": "NoSchedule", "key": "sku", "operator": "Equal", "value": "gpu"},{"effect": "NoSchedule", "key": "kubernetes.azure.com/scalesetpriority", "value":"spot", "operator": "Equal"},{"effect": "NoSchedule", "key": "mig", "value":"notReady", "operator": "Equal"}]'

```

## Install the NVIDIA Specific discovery rule

```bash
kubectl apply -n gpu-operator -f node_feature_discovery/nfd-gpu-rule.yaml
```

## Install NVIDIA GPU Operator

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia    && helm repo update

helm install --wait --generate-name -n gpu-operator nvidia/gpu-operator --set-json daemonsets.tolerations='[{ "effect": "NoSchedule", "key": "sku", "operator": "Equal", "value": "gpu"},{"effect": "NoSchedule", "key": "kubernetes.azure.com/scalesetpriority", "value":"spot", "operator": "Equal"},{"effect": "NoSchedule", "key": "mig", "value":"notReady", "operator": "Equal"}]' --set nfd.enabled=false
```

## Apply time slicing (optional)

```bash
az aks nodepool update --cluster-name $AKS_CLUSTER_NAME --resource-group $RESOURCE_GROUP_NAME --nodepool-name nc4ast4 --labels "nvidia.com/device-plugin.config=tesla-t4-ts2"

kubectl apply -f time_slicing/time-slicing-example.yaml -n gpu-operator

kubectl patch clusterpolicy/cluster-policy \
    -n gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config"}}}}'
```

## Run a batch of sample GPU accelerated jobs to track functionlity

```bash
export NUMBER_OF_JOBS=10
envsubst < sample_jobs/gpu_test/template_job.yaml | kubectl apply -f -
```

