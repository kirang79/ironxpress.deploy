using './data.bicep'

param env = 'dev'
// The CI principal has Contributor, which cannot write Authorization locks.
// Apply the CanNotDelete lock once, manually, as a subscription Owner (see README)
// — a lock the pipeline can't remove is a stronger guardrail anyway.
param lockDatabase = false
// Secret at deploy time: -p postgresPassword='<STRONG_PASSWORD>'
