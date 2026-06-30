// IronXpress — STATEFUL data stack (Postgres only). Deployed ONCE per environment
// and rarely changed. The server carries a CanNotDelete lock so neither an app
// release nor a stray Complete-mode deployment can destroy it.
//
//   az deployment group create -g rg-ironx-dev -f data.bicep -p data.dev.bicepparam \
//     -p postgresPassword='<STRONG_PASSWORD>'
//
// SAFETY: always deploy incremental (the default). NEVER use --mode Complete.
targetScope = 'resourceGroup'

@description('Short environment name, e.g. dev or prod.')
param env string

@description('Azure region.')
param location string = resourceGroup().location

@description('Postgres administrator login + password.')
param postgresAdmin string = 'ironxadmin'
@secure()
param postgresPassword string

@description('Database name for this environment.')
param postgresDbName string = 'ironx_${env}'

@description('Apply a CanNotDelete lock on the Postgres server. Keep true.')
param lockDatabase bool = true

@description('Geo-redundant backups (recommended for prod).')
param geoRedundantBackup bool = false

var prefix = 'ironx-${env}'
var unique = substring(uniqueString(resourceGroup().id), 0, 6)
var tags = { app: 'ironxpress', env: env, tier: 'data' }

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: '${prefix}-pg-${unique}'
  location: location
  tags: tags
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '15'
    administratorLogin: postgresAdmin
    administratorLoginPassword: postgresPassword
    storage: { storageSizeGB: 32 }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: geoRedundantBackup ? 'Enabled' : 'Disabled'
    }
    highAvailability: { mode: 'Disabled' }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: postgres
  name: postgresDbName
}

resource pgAllowAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: postgres
  name: 'AllowAllAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// The guardrail: blocks DELETE on the server (and anything that would require
// replacing it). Remove deliberately before an intentional teardown.
resource pgLock 'Microsoft.Authorization/locks@2020-05-01' = if (lockDatabase) {
  name: '${prefix}-pg-cannotdelete'
  scope: postgres
  properties: {
    level: 'CanNotDelete'
    notes: 'Protects the IronXpress database from accidental deletion. Remove intentionally before destroying.'
  }
}

output postgresServerName string = postgres.name
output postgresHost string = postgres.properties.fullyQualifiedDomainName
output postgresDbName string = postgresDbName
