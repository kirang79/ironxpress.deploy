# IronXpress — Azure infrastructure (Bicep, Container Apps)

Two stacks per environment, deliberately separated so frequent deploys can never
touch your data:

| Stack | File | Holds | Cadence | Protection |
|---|---|---|---|---|
| **Data** | `data.bicep` | Postgres Flexible Server + DB | deploy **once**, rarely changed | **CanNotDelete lock** + 7-day backups |
| **Apps** | `apps.bicep` | Container Apps (API + 2 workers), Service Bus, Managed Identity, App Insights, Log Analytics | redeploy any time | stateless — no data to lose |

App **releases** (per merge) don't run Bicep at all — they only swap the container
image (`az containerapp update`). So the only thing that ever touches the database
is the rarely-run, locked data stack.

> **Telemetry:** Application Insights + Log Analytics are in the apps stack; every
> app gets `ApplicationInsights__ConnectionString`. Fully emitting traces needs the
> Azure Monitor OpenTelemetry exporter wired in app code (follow-up).

## ⚠️ Data-safety rules (non-negotiable)
- **Always incremental.** `az deployment group create` defaults to incremental
  (creates/updates, never deletes absent resources). **NEVER pass `--mode Complete`** —
  that deletes anything not in the template.
- **Preview first.** Run `az deployment group what-if` before any apply; prod is
  gated behind a manual approval.
- **Keep the lock.** The Postgres `CanNotDelete` lock blocks deletion (and any
  change that would replace the server). Remove it only for an intentional teardown.
- Infra runs on a **dedicated subscription**, isolated from everything else.

## 1. Commission an environment (one-time, idempotent)

```bash
ENV=dev
RG=rg-ironx-$ENV
LOCATION=centralindia
PG_PW='<STRONG_PASSWORD>'

# Confirm you're on the RIGHT subscription first:
az account show --query '{name:name, id:id}'

az group create -n $RG -l $LOCATION

# 1) Data stack (Postgres, locked). Idempotent — safe to re-run.
az deployment group create -g $RG -f data.bicep -p data.$ENV.bicepparam \
  -p postgresPassword="$PG_PW"

PG_HOST=$(az deployment group show -g $RG -n data --query properties.outputs.postgresHost.value -o tsv)

# 2) Apps stack (Container Apps, Service Bus, App Insights).
az deployment group create -g $RG -f apps.bicep -p apps.$ENV.bicepparam \
  -p postgresHost="$PG_HOST" postgresPassword="$PG_PW" \
     ghcrUsername='<github-username>' ghcrToken='<ghcr-PAT-read:packages>'

az deployment group show -g $RG -n apps --query properties.outputs
```

Re-running either deployment only reconciles drift — it never deletes the DB.

## 2. GitHub OIDC for CD (no stored Azure passwords)

```bash
APP_ID=$(az ad app create --display-name "ironx-deploy-$ENV" --query appId -o tsv)
az ad sp create --id $APP_ID
SUB=$(az account show --query id -o tsv)
az role assignment create --assignee $APP_ID --role Contributor \
  --scope /subscriptions/$SUB/resourceGroups/$RG

# One federated credential per repo + branch (publish-dev / publish-prod):
az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "ironx-'$ENV'",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<OWNER>/<REPO>:ref:refs/heads/publish-'$ENV'",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

GitHub repo secrets (each service repo): `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`.

## 3. Deploy cadence

- **App release** (merge to `publish-dev`/`publish-prod`): build image → push GHCR →
  `az containerapp update --image …`. No Bicep, no data risk.
- **Apps-infra change** (scaling, env vars, new app): re-run `apps.bicep` (incremental).
- **Data change** (rare): re-run `data.bicep`; the lock must be lifted only for an
  intentional destructive change.

## Cost levers
- Dev API scales to zero (`apiMinReplicas=0`); prod keeps one warm replica.
- Stop dev Postgres when idle: `az postgres flexible-server stop -g $RG -n <server>`.
- To share one Postgres across dev+prod early on: deploy `data.bicep` once, create a
  second database, and point the dev apps stack at it via `postgresHost`/`postgresDbName`.
