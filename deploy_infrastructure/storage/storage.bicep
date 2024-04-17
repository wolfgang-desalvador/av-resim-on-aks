// Creates a storage account, private endpoints and DNS zones
@description('Azure region of the deployment')
param location string

@description('Name of the storage account')
param storageName string

@description('Subnet Name for the storage account')
param subnetName string

@description('Virtual Network Name for the storage account')
param virtualNetworkName string

@description('Name of the container to be created')
param containerName string

@description('Private DNS Zone Name')
param privateDNSZoneName string


@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
@description('Storage SKU')
param storageSkuName string = 'Standard_ZRS'

var storageNameCleaned = replace(storageName, '-', '')

var blobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

var storagePleBlobName = '${storageNameCleaned}-pe'


resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDNSZoneName
}


resource virtualNetwork 'Microsoft.Network/virtualNetworks@2020-08-01' existing = {
  name: virtualNetworkName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2020-08-01' existing = {
  parent: virtualNetwork
  name: subnetName
}


resource storage 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: storageNameCleaned
  location: location
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
        queue: {
          enabled: true
          keyType: 'Account'
        }
        table: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    isHnsEnabled: true
    isNfsV3Enabled: false
    largeFileSharesState: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    supportsHttpsTrafficOnly: true
  }
}

resource storagePrivateEndpointBlob 'Microsoft.Network/privateEndpoints@2022-01-01' = {
  name: storagePleBlobName
  location: location
  properties: {
    privateLinkServiceConnections: [
      { 
        name: storagePleBlobName
        properties: {
          groupIds: [
            'blob'
          ]
          privateLinkServiceId: storage.id
        }
      }
    ]
    subnet: {
      id: subnet.id
    }
  }
}


resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-01-01' = {
  name: '${storagePrivateEndpointBlob.name}/blob-PrivateDnsZoneGroup'
  properties:{
    privateDnsZoneConfigs: [
      {
        name: blobPrivateDnsZoneName
        properties:{
          privateDnsZoneId: blobPrivateDnsZone.id
        }
      }
    ]
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' existing = {
  name: storageNameCleaned
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-06-01' existing = {
  name: '${storageAccount.name}/default'
}

// Create containers if specified
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-06-01' = {
  parent: blobService
  dependsOn: [storage]
  name: containerName
  properties: {
    publicAccess: 'None'
    metadata: {}
  }
}

output containerName string = containerName
output blob string = '${storageNameCleaned}.blob.${environment().suffixes.storage}'
