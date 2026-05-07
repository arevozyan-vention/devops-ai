# Deploy Attempts — activepieces (Azure / dev / westus3)

## Counter
- env: 3/3 (AP_PORT, AP_REDIS_TYPE, AP_EXECUTION_MODE pre-fixed)
- secret: 2/3 (ap-postgres-password attempt 1, ap-encryption-key + ap-jwt-secret attempt 3)
- sslmode: 0/3
- port: 0/3
- probe: 1/3 (probe path pre-fixed: /health → /api/v1/health)
- grace: 0/3
- scale: 0/3
- image-tag: 0/3
- identity: 0/3
- dns: 0/3
- migration: 1/3 (vector extension allow-list attempt 2)
- revision: 0/3
- logs: 0/3
- acr-auth: 0/3
- ingress: 0/3
- size: 0/3
- **Total attempts**: 3/8 — SUCCESS at attempt 3

## Pre-fix log

| ts | category | command | result |
|----|----------|---------|--------|
| 2026-05-07T15:38Z | env | `az containerapp update --set-env-vars AP_PORT=8080 AP_REDIS_TYPE=MEMORY AP_EXECUTION_MODE=UNSANDBOXED` | applied — Activepieces requires AP_PORT to match targetPort 8080 (default is 80); REDIS_TYPE=MEMORY since include_redis=false; EXECUTION_MODE=UNSANDBOXED for managed env |
| 2026-05-07T15:39Z | probe | edited Container App YAML: probe httpGet.path `/health` → `/api/v1/health` (3 probes), `az containerapp update --yaml` | applied — health endpoint registered under `/api` prefix |

## Self-heal log

## Attempt 1 — 2026-05-07T16:00Z
**Category:** secret  (counter: 1/3)
**Symptom:** First revision activation failed. Postgres FATAL: `password authentication failed for user "pgadmin"`
**Diagnose output:**
- `az containerapp logs show ... --revision activepieces-dev--0000003` → repeating `DatabaseError: password authentication failed for user "pgadmin"` from `pg-protocol/parser`, code 28P01.
- `az keyvault secret show --vault-name activepieces-dev-kv --name ap-postgres-password` → value `PLACEHOLDER-CHANGE-ME`.
**Classification:** Whitelist row 4 — DB password slot not populated; derive from `outputs.json::admin_password` and store in KV.
**Fix applied:**
- `az keyvault secret set --vault-name activepieces-dev-kv --name ap-postgres-password --file <pgpass>` (real password from outputs.json).
- `az containerapp update -n activepieces-dev -g activepieces-dev-rg --image activepiecesdevacr.azurecr.io/activepieces:e909bef6e3ac19955a8d81732e7e2155930b5bf8 --revision-suffix r2` to roll a fresh revision that resolves the new KV secret.
**Result:** still failing (different error) → see attempt 2.

## Attempt 2 — 2026-05-07T16:08Z
**Category:** migration  (counter: 1/3)
**Symptom:** Activation failed in Migration `AddPgVectorExtension1773627989514`: `extension "vector" is not allow-listed for "azure_pg_admin" users in Azure Database for PostgreSQL` (code 0A000).
**Diagnose output:**
- TypeORM tries `CREATE EXTENSION IF NOT EXISTS "vector"`; Azure PG denies.
- `az postgres flexible-server parameter show ... --name azure.extensions` → value empty; allowed list contains `vector`.
**Classification:** Whitelist row 14 — migrations require an allow-listed extension; enable it on the Postgres server (analogous to running an init/setup step migrations need).
**Fix applied:**
- `az postgres flexible-server parameter set --resource-group activepieces-dev-rg --server-name activepieces-dev-pg --name azure.extensions --value VECTOR`
- `az containerapp revision restart -n activepieces-dev -g activepieces-dev-rg --revision activepieces-dev--r2`
**Result:** migration ran successfully; new error surfaced → see attempt 3.

## Attempt 3 — 2026-05-07T16:18Z
**Category:** secret  (counter: 2/3)
**Symptom:** App boot failed: `AP_ENCRYPTION_KEY is missing or invalid. It must be a 32-character hexadecimal string`. Worker started fine; app side rejected at `validateEnvPropsOnStartup`.
**Diagnose output:**
- Logs from replica `activepieces-dev--r2-67b89cfd44-4w88x` show migrations succeed and worker starts, then app process exits with the encryption-key validation error.
- `az keyvault secret show ... --name ap-encryption-key` → `PLACEHOLDER-CHANGE-ME`; `--name ap-jwt-secret` → `PLACEHOLDER-CHANGE-ME`.
**Classification:** Whitelist row 3 — empty Key Vault secret blocks startup.
**Fix applied:**
- `ENC_KEY=$(openssl rand -hex 16)` (32 hex chars); `JWT=$(openssl rand -hex 32)`.
- `az keyvault secret set --vault-name activepieces-dev-kv --name ap-encryption-key --value $ENC_KEY`.
- `az keyvault secret set --vault-name activepieces-dev-kv --name ap-jwt-secret --value $JWT`.
- `az containerapp update -n activepieces-dev -g activepieces-dev-rg --image activepiecesdevacr.azurecr.io/activepieces:<sha> --revision-suffix r3` to roll a fresh revision.
**Result:** healthy after ~60s. Revision activepieces-dev--r3 reached `Running/Healthy/100`. `curl https://<fqdn>/api/v1/health` → 200 `{"status":"Healthy"}`.
