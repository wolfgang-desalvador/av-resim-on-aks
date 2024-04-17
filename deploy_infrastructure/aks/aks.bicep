@description('Azure Kuberentes Services Cluster Name')
param aksName string

@description('Location of the cluster')
param location string

@description('SSH RSA Key')
param sshRSAPublicKey string

@description('Service CIDR')
param serviceCIDR string

@description('DNS Service IP')
param dnsServiceIP string


@description('Cluster SSH Admin username')
param adminUsername string

@description('Subnet name for the cluster')
param subnetName string 

@description('Virtual Network name for the cluster')
param virtualNetworkName string 

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2020-08-01' existing = {
  name: virtualNetworkName
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-08-01' existing = {
  parent: virtualNetwork
  name: subnetName
}



resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: aksName
  location: location
  sku: {
    name: 'Base'
tier: 'Free'
}
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: '${virtualNetworkName}-${aksName}'
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
    }
    autoUpgradeProfile: {
      upgradeChannel: 'none'
    }
    kubernetesVersion: '1.28.5'
    networkProfile: {
      dnsServiceIP: dnsServiceIP
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      serviceCidr: serviceCIDR
    }
    agentPoolProfiles: [
      {
        name: 'agentpool'
        vmSize: 'Standard_d2as_v5'
        vnetSubnetID: aksSubnet.id
        count: 2
        osType: 'Linux'
        mode: 'System'
      }
    ]
    linuxProfile: {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshRSAPublicKey
          }
        ]
      }
    }
  }
}

output controlPlaneFQDN string = aks.properties.fqdn
