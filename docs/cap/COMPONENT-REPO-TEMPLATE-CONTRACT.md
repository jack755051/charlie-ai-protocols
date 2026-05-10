# Component Repo Template Contract

> Status: active template contract for Component Repo dogfood.
> Scope: Full-stack Component Repo shape for the primary stack
> (Next.js + C#/.NET + PostgreSQL + Docker Compose).
> Purpose: define what CAP should ask frontend, backend, UI, QA, and DevOps
> agents to produce before Product Repo expansion.

## Decision

A Component Repo can run independently, but it is not a full product. It is an
independently buildable, testable, runnable, and smoke-verifiable feature slice
that can later be consumed by a Product Repo.

The default Full-stack Component Repo shape is:

```text
component-core
component-frontend
  - frontend-core
  - frontend-ui
component-backend
component-demo
integration-runtime
async-runtime optional
```

Do not use `component-ui` as a top-level layer. UI belongs under
`component-frontend` as `frontend-ui`; this avoids confusing "UI" with the
whole frontend surface.

## Layer Contract

### component-core

Cross-layer contract that is independent of React, shadcn, .NET, PostgreSQL,
Redis, Docker, and provider SDKs.

Must contain or reference:

- domain language and bounded feature vocabulary
- DTO schema and response envelope contract
- status enum and error-code taxonomy
- API contract reference
- integration assumptions shared by frontend and backend

### component-frontend

Reusable frontend surface. It has two internal layers:

```text
frontend-core
frontend-ui
```

`frontend-core` contains hooks, API client, DTO mapper, ViewModel mapping,
state machine, error mapping, and facade logic. It must not depend on shadcn,
Tailwind class constants, route entries, fixed backend URLs, or demo pages.

`frontend-ui` contains the default visual adapter:

```text
shadcn-ui + Tailwind CSS + Lucide
```

It may import `frontend-core`, but `frontend-core` must not import
`frontend-ui`.

Expected STT example outputs:

```text
frontend/lib/stt/useSttRecorder.ts
frontend/lib/stt/transcriptApiClient.ts
frontend/lib/stt/transcriptMapper.ts
frontend/lib/stt/transcriptTypes.ts
frontend/components/stt/SttRecorder.tsx
frontend/components/stt/TranscriptResult.tsx
frontend/components/stt/SttStatusBadge.tsx
frontend/components/stt/SttUploadFallback.tsx
```

### component-backend

Reusable backend module, not a whole product backend. Its core is domain,
application, provider, store, DTO, endpoint, and test contracts.

Expected STT example outputs:

```text
backend/SpeechTranscription/Domain/
backend/SpeechTranscription/Application/
backend/SpeechTranscription/Infrastructure/
backend/SpeechTranscription/WebApi/
```

Required backend contracts:

```csharp
public interface ISttProvider
{
    Task<TranscriptResult> TranscribeAsync(Stream audio, CancellationToken ct);
}

public interface ITranscriptStore
{
    Task SaveAsync(Transcript transcript, CancellationToken ct);
    Task<Transcript?> GetAsync(Guid id, CancellationToken ct);
}
```

Default adapters:

- `MockSttProvider` for dev/test/smoke.
- `InMemoryTranscriptStore` for component-core and component-demo.
- `PostgresTranscriptStore` only in integration-runtime when persistence is
  part of the validated profile.
- Redis / queue adapters only in async-runtime when the task requires
  background jobs, retry, queueing, rate limiting, or long-running
  transcription.

### component-demo

Demo host for humans and smoke scripts. It may include:

- Next.js demo route
- backend demo host
- mock STT provider
- in-memory store

Demo code may depend on runtime wiring, but demo code must not leak back into
`component-frontend/frontend-core` or `component-backend` core contracts.

### integration-runtime

Docker Compose / env / smoke harness profile that validates the component can
run as a three-tier local stack.

This is where PostgreSQL is enabled for the primary Component Runtime Profile.
It must not imply PostgreSQL is mandatory for component-core.

Required runtime files:

```text
.env.example
docker-compose.yml
scripts/runtime-smoke.sh
docs/runtime-profile.md
```

Minimum externalized settings:

```env
FRONTEND_PORT=3000
BACKEND_PORT=8080
BACKEND_URL=http://backend:8080
NEXT_PUBLIC_API_BASE_URL=/api
POSTGRES_PORT=5432
STT_STORE=inmemory
STT_PROVIDER=mock
```

Compose and smoke scripts must read env/config instead of hardcoding host
ports or endpoints.

### async-runtime optional

Optional runtime profile. Enable only when the component needs background job
processing, queueing, retry, rate limiting, cache-aside, or long-running
provider calls.

This is where Redis / queue infrastructure belongs. STT v0.1 happy path does
not require async-runtime.

## Seven Implementation Priorities

1. **Logic extraction first.** Frontend recording state, upload flow, API
   client, DTO mapper, ViewModel, and error mapping are reusable core logic.
2. **Default frontend UI adapter.** Use `shadcn-ui + Tailwind CSS + Lucide`
   for the default visual implementation, but keep it out of frontend-core.
3. **Design contract is independent.** Keep tokens, theme, screens, component
   states, and copy in files such as `design/tokens.json`,
   `design/theme.css`, `design/screens.json`, and `design/components.md`.
4. **Backend contract first.** API endpoints, DTOs, response envelopes,
   domain service interfaces, provider ports, and store ports come before
   infrastructure choices.
5. **Infrastructure is adapterized.** SQL DB, Redis, provider SDKs, queues,
   and object storage are infrastructure adapters, not component-core
   dependencies.
6. **Runtime profiles are layered.** component-core uses no DB/Redis;
   component-demo uses mock/in-memory; integration-runtime may add
   PostgreSQL; async-runtime may add Redis.
7. **Ports and endpoints are externalized.** Do not hardcode `3000`, `8080`,
   `localhost`, `http://backend:8080`, or compose service names inside core
   logic.

## STT Fixture Adjustment Order

Use this order when converting
`~/projects/cap-test/component-next-dotnet-stt` from a Phase F skeleton into a
template-quality Component Repo fixture:

1. Add `.env.example`; update `docker-compose.yml` and
   `scripts/runtime-smoke.sh` to read ports/endpoints from env.
2. Extract frontend-core under `frontend/lib/stt/*`.
3. Add frontend-ui components under `frontend/components/stt/*` using the
   default shadcn/Tailwind/Lucide adapter.
4. Add design contract files under `design/`.
5. Add backend ports (`ISttProvider`, `ITranscriptStore`) and dev/test
   adapters (`MockSttProvider`, `InMemoryTranscriptStore`).
6. Add PostgreSQL adapter only for integration-runtime.
7. Keep Redis / queue out until async-runtime has a real dogfood requirement.

## Agent Skill Binding

Component Repo implementation steps must mount:

- `agent-skills/04-frontend-agent.md` §3.6.1 for frontend work.
- `agent-skills/05-backend-agent.md` §3.5.1 for backend work.

Product Repo sections in those agent skills are intentionally placeholders
until Product Repo dogfood produces evidence.
