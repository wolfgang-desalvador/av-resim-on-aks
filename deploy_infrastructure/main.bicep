@description('Random string to be appended to storage accounts.')
param random string

@description('Azure Container Registry Name')
param acrName string

@description('Azure Kuberentes Services Cluster Name')
param aksClusterName string

@description('Azure Kuberentes Services Cluster Admin Username')
param adminUsername string

@description('Azure Container Registry Name')
param location string = resourceGroup().location

@description('Virtual Network Name')
param virtualNetworkName string 

@description('Subnet name for AKS Cluster')
param subnetName string 


@description('Servie CIDR for AKS Cluster')
param serviceCIDR string 

@description('DNS Service IP for AKS Cluster')
param dnsServiceIP string 


@secure()
@description('SSH Admin RSA Key')
param sshRSAPublicKey string 


module aks 'aks/aks.bicep' = {
  name: 'aks-cluster'
  params: {
    aksName: aksClusterName
    virtualNetworkName: virtualNetworkName
    subnetName: subnetName
    sshRSAPublicKey: sshRSAPublicKey
    location: location
    adminUsername: adminUsername
    serviceCIDR: serviceCIDR
    dnsServiceIP: dnsServiceIP
  }
}

module storageDnsZone 'privateDNSZone/privateDNSZone.bicep' = {
  name: 'storage-private-dns-zone'
  params: {
    privateDNSZoneName: 'privatelink.dfs.${environment().suffixes.storage}'
    virtualNetworkName: virtualNetworkName
  }
}

module inputStorage 'storage/storage.bicep' = {
  name: 'input-storage'
  dependsOn: [storageDnsZone]
  params: {
    location: location
    virtualNetworkName: virtualNetworkName
    privateDNSZoneName: storageDnsZone.outputs.privateDNSZoneName
    subnetName: subnetName
    storageName: 'avaksinput${random}'
    containerName: 'input'
  }
}

module outputStorage 'storage/storage.bicep' = {
  name: 'output-storage'
  dependsOn: [storageDnsZone]
  params: {
    location: location
    virtualNetworkName: virtualNetworkName
    privateDNSZoneName: storageDnsZone.outputs.privateDNSZoneName
    subnetName: subnetName
    storageName: 'avaksoutput${random}'
    containerName: 'output'
  }
}

module acrDnsZone 'privateDNSZone/privateDNSZone.bicep' = {
  name: 'acr-private-dns-zone'
  params: {
    privateDNSZoneName: 'privatelink${environment().suffixes.acrLoginServer}'
    virtualNetworkName: virtualNetworkName
  }
}

module acr 'acr/acr.bicep' = {
  name: 'acr'
  params: {
    virtualNetworkName: virtualNetworkName
    subnetName: subnetName
    acrName: acrName
    location: location
    acrPrivateDNSZoneName: acrDnsZone.outputs.privateDNSZoneName
  }
}
