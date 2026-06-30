using './data.bicep'

param env = 'prod'
param geoRedundantBackup = true
// Secret at deploy time: -p postgresPassword='<STRONG_PASSWORD>'
