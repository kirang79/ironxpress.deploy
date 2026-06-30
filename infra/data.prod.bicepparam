using './data.bicep'

param env = 'prod'
param geoRedundantBackup = true
// Lock applied manually by an Owner (CI principal has Contributor, which can't
// write locks). See README. A lock the pipeline can't remove is stronger.
param lockDatabase = false
// Secret at deploy time: -p postgresPassword='<STRONG_PASSWORD>'
