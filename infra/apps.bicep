// IronXpress — STATELESS apps stack: Container Apps (API + 2 workers), Service Bus,
// Managed Identity, App Insights. Safe to redeploy on every infra change; it holds
// NO database, so it can never delete your data. Postgres connection details come
// in as parameters from the data stack outputs.
//
//   az deployment group create -g rg-ironx-dev -f apps.bicep -p apps.dev.bicepparam \
//     -p postgresHost=<from data stack> postgresPassword='<pw>' \
//        ghcrUsername=<user> ghcrToken=<pat>
//
// SAFETY: always incremental (default). NEVER --mode Complete.
targetScope = 'resourceGroup'

@description('Short environment name, e.g. dev or prod.')
param env string

@description('Azure region.')
param location string = resourceGroup().location

@description('Container images (GHCR). CD overrides these via `az containerapp update`.')
param apiImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param outboxWorkerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'
param notificationImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('GHCR pull credentials for private images. Blank = public image.')
param ghcrUsername string = ''
@secure()
param ghcrToken string = ''

@description('API ingress replicas. dev can be 0 (scale to zero).')
param apiMinReplicas int = 0
param apiMaxReplicas int = 2

// ---- Postgres connection (from the data stack; this stack never creates it) ----
@description('Postgres FQDN, e.g. ironx-dev-pg-xxxx.postgres.database.azure.com')
param postgresHost string
param postgresDbName string = 'ironx_${env}'
param postgresAdmin string = 'ironxadmin'
@secure()
param postgresPassword string

var prefix = 'ironx-${env}'
var unique = substring(uniqueString(resourceGroup().id), 0, 6)
var tags = { app: 'ironxpress', env: env, tier: 'apps' }

// ---------------------------------------------------------------- observability
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appi'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ------------------------------------------------------------------- identity
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id'
  location: location
  tags: tags
}

// ----------------------------------------------------------------- service bus
resource sb 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${prefix}-sb-${unique}'
  location: location
  tags: tags
  sku: { name: 'Basic', tier: 'Basic' }
}

resource emailQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sb
  name: 'email-jobs'
  properties: {
    maxDeliveryCount: 5
    lockDuration: 'PT1M'
    deadLetteringOnMessageExpiration: true
  }
}

resource mobileQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sb
  name: 'mobile-jobs'
  properties: {
    maxDeliveryCount: 5
    lockDuration: 'PT1M'
    deadLetteringOnMessageExpiration: true
  }
}

var sbDataOwnerRoleId = '090c5cfd-751d-490a-894a-3ce6f1109419' // Azure Service Bus Data Owner
resource sbRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sb.id, uami.id, sbDataOwnerRoleId)
  scope: sb
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sbDataOwnerRoleId)
  }
}

// -------------------------------------------------------- container apps env
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-aca'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

var sbNamespaceHost = '${sb.name}.servicebus.windows.net'
var pgConnString = 'Host=${postgresHost};Database=${postgresDbName};Username=${postgresAdmin};Password=${postgresPassword};Ssl Mode=Require'
var registries = empty(ghcrUsername) ? [] : [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-token'
  }
]
var registrySecrets = empty(ghcrUsername) ? [] : [
  { name: 'ghcr-token', value: ghcrToken }
]

// ----------------------------------------------------------------- API app
resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-api'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8081
        transport: 'auto'
      }
      registries: registries
      secrets: concat(registrySecrets, [
        { name: 'pg-conn', value: pgConnString }
      ])
    }
    template: {
      containers: [
        {
          name: 'api'
          image: apiImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'ASPNETCORE_URLS', value: 'http://0.0.0.0:8081' }
            { name: 'ASPNETCORE_ENVIRONMENT', value: env == 'prod' ? 'Production' : 'Development' }
            { name: 'ConnectionStrings__DefaultConnection', secretRef: 'pg-conn' }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
          ]
        }
      ]
      scale: {
        minReplicas: apiMinReplicas
        maxReplicas: apiMaxReplicas
        rules: [
          { name: 'http', http: { metadata: { concurrentRequests: '50' } } }
        ]
      }
    }
  }
}

// ------------------------------------------------------ outbox worker app
resource outboxApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-outbox'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, [
        { name: 'pg-conn', value: pgConnString }
        { name: 'pg-pass', value: postgresPassword }
      ])
    }
    template: {
      containers: [
        {
          name: 'outbox'
          image: outboxWorkerImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'ConnectionStrings__DefaultConnection', secretRef: 'pg-conn' }
            { name: 'Messaging__Provider', value: 'ServiceBus' }
            { name: 'Messaging__ServiceBus__FullyQualifiedNamespace', value: sbNamespaceHost }
            { name: 'Messaging__ServiceBus__Queue', value: 'email-jobs' }
            { name: 'Messaging__ServiceBus__MobileQueue', value: 'mobile-jobs' }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 2
        rules: [
          {
            name: 'pending-outbox'
            custom: {
              type: 'postgresql'
              metadata: {
                query: 'SELECT count(*) FROM outboxes WHERE status = \'pending\''
                targetQueryValue: '1'
                host: postgresHost
                userName: postgresAdmin
                dbName: postgresDbName
                port: '5432'
                sslmode: 'require'
              }
              auth: [ { secretRef: 'pg-pass', triggerParameter: 'password' } ]
            }
          }
        ]
      }
    }
  }
}

// ------------------------------------------------ notification service app
resource notificationApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-notify'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: acaEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, [
        { name: 'pg-conn', value: pgConnString }
      ])
    }
    template: {
      containers: [
        {
          name: 'notify'
          image: notificationImage
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'DOTNET_ENVIRONMENT', value: env == 'prod' ? 'Production' : 'Development' }
            { name: 'ConnectionStrings__DefaultConnection', secretRef: 'pg-conn' }
            { name: 'Messaging__Provider', value: 'ServiceBus' }
            { name: 'ServiceBus__FullyQualifiedNamespace', value: sbNamespaceHost }
            { name: 'ServiceBus__Queues__EmailQueue', value: 'email-jobs' }
            { name: 'ServiceBus__Queues__MobileQueue', value: 'mobile-jobs' }
            { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
            { name: 'ApplicationInsights__ConnectionString', value: appInsights.properties.ConnectionString }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
        rules: [
          {
            name: 'sb-email'
            custom: {
              type: 'azure-servicebus'
              // KEDA authenticates to Service Bus with the user-assigned identity.
              // `identity` is valid on the 2024-03-01 API; the bicep type lags, so
              // the BCP037 warning is suppressed (the value reaches the ARM output).
              #disable-next-line BCP037
              identity: uami.id
              metadata: {
                namespace: sb.name
                queueName: 'email-jobs'
                messageCount: '5'
              }
            }
          }
          {
            name: 'sb-mobile'
            custom: {
              type: 'azure-servicebus'
              #disable-next-line BCP037
              identity: uami.id
              metadata: {
                namespace: sb.name
                queueName: 'mobile-jobs'
                messageCount: '5'
              }
            }
          }
        ]
      }
    }
  }
}

output apiFqdn string = apiApp.properties.configuration.ingress.fqdn
output serviceBusNamespace string = sbNamespaceHost
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
