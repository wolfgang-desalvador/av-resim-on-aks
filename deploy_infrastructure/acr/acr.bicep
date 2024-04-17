// Creates an Azure Container Registry, private endpoints and DNS zones
@description('Azure region of the deployment')
param location string

@description('Subnet Name for the storage account')
param acrName string

@description('Subnet Name for the storage account')
param subnetName string

@description('Virtual Network Name for the storage account')
param virtualNetworkName string


@description('Private DNS Zone Name for the account')
param acrPrivateDNSZoneName string

var acrPleBlobName = '${acrName}-pe'


resource virtualNetwork 'Microsoft.Network/virtualNetworks@2020-08-01' existing = {
  name: virtualNetworkName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2020-08-01' existing = {
  parent: virtualNetwork
  name: subnetName
}

resource acrPrivateDNSZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: acrPrivateDNSZoneName
}


resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: false
    networkRuleSet: {
      defaultAction: 'Deny'
    }
    publicNetworkAccess: 'Disabled'
  }
}

resource acrPrivateEndpointBlob 'Microsoft.Network/privateEndpoints@2022-01-01' = {
  name: acrPleBlobName
  location: location
  properties: {
    privateLinkServiceConnections: [
      { 
        name: acrPleBlobName
        properties: {
          groupIds: [
            'registry'
          ]
          privateLinkServiceId: acr.id
        }
      }
    ]
    subnet: {
      id: subnet.id
    }
  }
}

resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-01-01' = {
  name: '${acrPrivateEndpointBlob.name}/registry-PrivateDnsZoneGroup'
  properties:{
    privateDnsZoneConfigs: [
      {
        name: acrPrivateDNSZoneName
        properties:{
          privateDnsZoneId: acrPrivateDNSZone.id
        }
      }
    ]
  }
}
