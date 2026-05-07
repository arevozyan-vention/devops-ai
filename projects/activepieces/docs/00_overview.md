# activepieces

**Cloud:** azure     **Skeleton:** container-apps-postgres

## Stack
- TypeScript 5.5 on Node 24 (bun used at build time)
- Fastify 5 (`packages/server/api`), React 18 + Vite 6 SPA (`packages/web`)
- TypeORM 0.3 (Postgres / PGLite)
- BullMQ 5 over ioredis, redlock 5, socket.io 4 with `@socket.io/redis-adapter`
- Multi-package monorepo via Turborepo (`turbo.json`, workspaces in `package.json:388`)

## Runtime
- Single OCI image (`Dockerfile`); PM2 launches `activepieces-app` (API + bundled SPA) and `activepieces-worker` based on `AP_CONTAINER_TYPE` (`docker-entrypoint.sh:29-57`). Default `WORKER_AND_APP` runs both in one container — viable for dev.
- Ports: 80 (HTTP, SPA + REST + WebSocket on same listener)
- Health check: `/api/v1/health` (`packages/server/api/src/app/health/health.module.ts:8`)
- Migrations: auto-run on boot (`postgres-connection.ts:759`, `migrationsRun: true`)

## Persistence
- Postgres 14 (`pgvector/pgvector:0.8.0-pg14` in `docker-compose.yml:33`); skeleton's Flexible Server 16 default works — no pgvector usage in core platform
- Redis 7 — required (BullMQ queues, redlock, socket.io adapter)
- Optional S3-compatible bucket for file storage (`AP_FILE_STORAGE_LOCATION=S3`); default is DB

## Required env vars
| Name | Secret? | Notes |
|---|---|---|
| `AP_POSTGRES_URL` | yes | or split host/port/user/pass/db vars |
| `AP_REDIS_URL` | yes | overrides discrete `AP_REDIS_*` vars |
| `AP_ENCRYPTION_KEY` | yes | 32-char hex (`openssl rand -hex 16`) |
| `AP_JWT_SECRET` | yes | 32-char hex (`openssl rand -hex 32`) |
| `AP_FRONTEND_URL` | no | public HTTPS URL of the Container App; webhooks break without it |
| `AP_CONTAINER_TYPE` | no | leave `WORKER_AND_APP` for single-container dev |
| `AP_POSTGRES_USE_SSL` | no | set `true` for Azure Postgres |

## External integrations
- SMTP — optional, for transactional email (`AP_SMTP_*`)
- Stripe, SendGrid, Segment, Intercom, Sentry — referenced by EE/Cloud editions only; not needed for self-hosted CE
- AI provider SDKs (OpenAI, Anthropic, Bedrock, Google, Replicate) — only invoked from user flows / AI pieces, no platform-level credentials required
- AWS S3 SDK — only if `AP_FILE_STORAGE_LOCATION=S3`

## Deployment fit (azure / container-apps-postgres)
- **`--include` extensions to enable**: `redis`
  - `redis`: BullMQ + redlock + socket.io-redis-adapter all require a real Redis (Azure Cache for Redis Basic C0 fits dev).
  - `queue`: skip — the app is hard-wired to BullMQ-on-Redis, will not use Azure Storage Queue.
  - `frontend`: skip — the SPA is built into `dist/packages/web` inside the same image and served by Fastify on port 80 (`Dockerfile:127`).
  - `keycloak` / `custom-domain-https`: skip for dev.
- **Estimated dev cost**: ~$62–77/month (skeleton baseline ~$45–60 + redis ~$17, per skeleton README)
- **Fit concerns**:
  1. socket.io WebSocket fan-out may bump Container Apps' per-revision concurrent-connection limits at scale; OK for dev/small workspaces.
  2. `isolated-vm` sandbox + iptables-based `AP_NETWORK_MODE=STRICT` need extra Linux capabilities the Consumption profile does not grant; keep `AP_EXECUTION_MODE=UNSANDBOXED` (the project default) and `AP_NETWORK_MODE=UNRESTRICTED`.
  3. Cold start on Consumption (~30–90 s, README) loses webhook deliveries; pin `min_replicas=1`.

## Selection command
`./devops-ai.sh select activepieces --cloud azure --region eastus --env dev --include redis`
