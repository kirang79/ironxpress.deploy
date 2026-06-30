using './apps.bicep'

param env = 'dev'
param apiMinReplicas = 0
param apiMaxReplicas = 2
// Passed at deploy time (from the data-stack outputs + secrets):
//   -p postgresHost=<host> postgresPassword='<pw>' ghcrUsername=<u> ghcrToken=<pat>
