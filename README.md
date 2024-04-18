# AV Resimulation on Azure playground

## Introduction
This repository contains a blueprint for an AV resimulation architecture on AKS. Please refer to the [AVOps Design Guide](https://learn.microsoft.com/en-us/azure/architecture/solution-ideas/articles/avops-architecture#valops)


## Pre-requisites

* An Azure Subscription
* A dedicated Azure Resource Group
* An Azure Virtual Network with at least /15 CIDR address space
* Quota for a GPU accelerated SKU on Azure
* A client with Azure CLI installed. 
* A Docker installation for image build process

## Define variables

These variables needs to be defined with your specific values. These will be used then in all the deployment phases:

```bash
export RESOURCE_GROUP_NAME=
export AKS_CLUSTER_NAME=
export LOCATION=
export VIRTUAL_NETWORK_NAME=
export ADMIN_USERNAME=
export SSH_RSA_PUB_KEY=
export ACR_NAME=
export RAND=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13 | awk '{print tolower($0)}')

```

## Login in Azure CLI

Here we will assume that we are using an Azure VM with a System Assigned Identity enabled and being Owner on the Resource Group. The same login process can be done also on a Windows machine, without `--identity` flag.

```bash
az login --identity
```

## Deploy the infrastructure

As a first step let's deploy the blueprint infrastructure that will be composed by:
* An Azure Kuberentes Cluster in Private Networking mode
* An Azure Container Registry with a Private Endpoint
* One input storage account and one output storage account that will be used for data read/write


```bash
envsubst < deploy_infrastructure/parameters.bicepparam.example >  deploy_infrastructure/parameters.bicepparam
az deployment group create -g $RESOURCE_GROUP_NAME --template-file deploy_infrastructure/main.bicep --parameters deploy_infrastructure/parameters.bicepparam
```

## Attach Azure Container registry to the Azure Kubernetes Cluster

As a second step, let's attach the AKS cluster to the Azure Container Registry, to allow transparent image pull from the container.

```bash
az aks update --name $AKS_CLUSTER_NAME --resource-group  $RESOURCE_GROUP_NAME --attach-acr $ACR_NAME
```

## Assign the dedicated permissions to the Service Principal (case of using an Azure VM as client)

This step is really meant for the case of an Azure VM being used as a client with a Service Principal. This is required since we are using Azure RBAC authorization mode on the AKS cluster. Even if we are Owner of the Resource Group, this Role Assigment is still required to interact with the cluster.

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

k9s is a valid open source TUI to interact with the AKS cluster. It is not mandatory, since all operations can also be done using `kubectl`. 

```bash
wget "https://github.com/derailed/k9s/releases/download/v0.31.9/k9s_linux_amd64.deb"
dpkg -i k9s_linux_amd64.deb
```

## Install kubectl and enable authentication

After the AKS cluster creation and role assignment, let's configure `kubectl` to have access to the cluster.

```bash
az aks install-cli
az aks get-credentials --resource-group $RESOURCE_GROUP_NAME --name $AKS_CLUSTER_NAME
```

Modify `$HOME/.kubectl/config` updating the login mode to make `kubelogin` use the same login environment as the Azure CLI:

```yaml
...
- --login
- azurecli # Modify the login mode to azurecli
command: kubelogin
...
```

## Create a GPU Node Pool without NVIDIA Driver installation enabled

Let's create a node pool with `Standard_NC4as_T4_v3` expliciting asking AKS not to manage the GPU driver installation (since it will be managed by NVIDIA Network operator) using `SkipGPUDriverInstall=True`

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

## Install Helm

Install Helm for the next installation steps. This assumes `kubectl` properly installed.

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 \
    && chmod 700 get_helm.sh \
    && ./get_helm.sh
```

## Install Node Feature Discovery

In this configuration, we installe Node Feature Discovery externally from the NVIDIA GPU Operator. This to allow a better control of node labelling using specific Azure Device IDs. This is not critical for GPU Operator, but it will become in case in the cluster NVIDIA Network Operator will be used for correct recognition of InfiniBand cards.

```bash
helm install --wait --create-namespace \
    -n gpu-operator node-feature-discovery node-feature-discovery \
    --create-namespace    --repo https://kubernetes-sigs.github.io/node-feature-discovery/charts   \
     --set-json master.config.extraLabelNs='["nvidia.com"]'  \
    --set-json worker.tolerations='[{ "effect": "NoSchedule", "key": "sku", "operator": "Equal", "value": "gpu"},{"effect": "NoSchedule", "key": "kubernetes.azure.com/scalesetpriority", "value":"spot", "operator": "Equal"},{"effect": "NoSchedule", "key": "mig", "value":"notReady", "operator": "Equal"}]'

```

## Install the NVIDIA Specific discovery rule

Let's apply the discovery rule that will label the node for GPU Operator target nodes.

```bash
kubectl apply -n gpu-operator -f node_feature_discovery/nfd-gpu-rule.yaml
```

## Install NVIDIA GPU Operator

Let's install the NVIDIA GPU Operator with the following options:
* Specify tolerations for the operator PODs, including Spot instances toleration, as well as specific flags for MIG management.
* Disable Node Feature Discover installation since already deployed externally

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia    && helm repo update

helm install --wait --generate-name -n gpu-operator nvidia/gpu-operator --set-json daemonsets.tolerations='[{ "effect": "NoSchedule", "key": "sku", "operator": "Equal", "value": "gpu"},{"effect": "NoSchedule", "key": "kubernetes.azure.com/scalesetpriority", "value":"spot", "operator": "Equal"},{"effect": "NoSchedule", "key": "mig", "value":"notReady", "operator": "Equal"}]' --set nfd.enabled=false
```

## Apply time slicing (optional)

In case we want to be able to oversubscribe the GPU with multiple PODs scheduled on the same node and using the same GPU, we can enable time slicing using the below commands. It is important to understand that time slicing works on the basis of node labels that needs to be applied to the cluster and matched in the configmap.

```bash
az aks nodepool update --cluster-name $AKS_CLUSTER_NAME --resource-group $RESOURCE_GROUP_NAME --nodepool-name nc4ast4 --labels "nvidia.com/device-plugin.config=tesla-t4-ts2"

kubectl apply -f time_slicing/time-slicing-example.yaml -n gpu-operator

kubectl patch clusterpolicy/cluster-policy \
    -n gpu-operator --type merge \
    -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config"}}}}'
```

## Run a batch of sample GPU accelerated jobs to track functionlity

In this first test, we will just run a batch job that will impose a test load on the GPU.

```bash
export NUMBER_OF_JOBS=10
envsubst < sample_jobs/gpu_test/template_job.yaml | kubectl apply -f -
```

## Deploy the Azure Blob Storage CSI Driver

In order to enable the I/O part of the architecture, we will install the Azure Blob Storage CSI Driver:

```bash
helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts
helm install blob-csi-driver blob-csi-driver/blob-csi-driver --set node.enableBlobfuseProxy=true --namespace kube-system --set node.blobfuseProxy.blobfuse2Version="2.2.1" --version v1.24.1 --wait
```

## Create PV and PVC on AKS

As a second step, we will create PersistentVolumes and PersitentVolumeClaims for the two blob storage accounts, including the required secrets:

```bash
export INPUT_STORAGE_ACCOUNT="avaksinput${RAND}"
export OUTPUT_STORAGE_ACCOUNT="avaksoutput${RAND}"
envsubst < aks_volumes/volumes.yaml | kubectl apply -f -

export end=`date -u -d "2 days" '+%Y-%m-%dT%H:%MZ'`
export INPUT_SAS=$(az storage container generate-sas --account-name $INPUT_STORAGE_ACCOUNT --name input --permissions acemdlrw --auth-mode login --as-user --expiry $end)
export OUTPUT_SAS=$(az storage container generate-sas --account-name $OUTPUT_STORAGE_ACCOUNT --name output --permissions acemdlrw --auth-mode login --as-user --expiry $end)

kubectl create secret generic azure-sas-token-input --from-literal azurestorageaccountname=$INPUT_STORAGE_ACCOUNT --from-literal azurestorageaccountsastoken=$INPUT_SAS  --type=Opaque
kubectl create secret generic azure-sas-token-output --from-literal azurestorageaccountname=$OUTPUT_STORAGE_ACCOUNT --from-literal azurestorageaccountsastoken=$OUTPUT_SAS  --type=Opaque
```

## Build the Docker image for the job with GPU load and I/O

Let's then build the Docker image for the mixed GPU and I/O case:

```bash
cd sample_jobs/gpu_io_test
docker build . -t $ACR_NAME.azurecr.io/test-io
az acr login --name $ACR_NAME
docker push $ACR_NAME.azurecr.io/test-io
```

## Submit 20 jobs with I/O and GPU load

Let's submit 20 parallel jobs simulating an embarassingly parallel workload of a re-simulation scenario:

```bash
python3 submit.py --acrName $ACR_NAME --njobs 20
```

## Build Metaseq image

To build Metaseq image, follow to recipe described in [AI on AKS](https://github.com/edwardsp/ai-on-aks#metaseq)

It is assumed that image is pushed in the container as `$ACR_NAME.azurecr.io/metaseq`

## Create an A100 GPU Node Pool to test Metaseq

Let's create a node pool with `Standard_NCA100ads_A100_v4` expliciting asking AKS not to manage the GPU driver installation (since it will be managed by NVIDIA Network operator) using `SkipGPUDriverInstall=True`

```bash
 az aks nodepool add \
    --resource-group $RESOURCE_GROUP_NAME \
    --cluster-name $AKS_CLUSTER_NAME \
    --name nc48a100 \
    --node-taints sku=gpu:NoSchedule \
    --node-vm-size Standard_NCA100ads_A100_v4 \
    --enable-cluster-autoscaler \
    --min-count 1 --max-count 5 --node-count 1 --tags SkipGPUDriverInstall=True --priority Spot
```

## Submit 1 jobs with I/O and Metaseq running on 2 GPUs

Let's submit 20 parallel jobs simulating an embarassingly parallel workload of a re-simulation scenario:

```bash
python3 submit.py --acrName $ACR_NAME --njobs 1 --jobTemplate "template_job_metaseq.yaml"
```