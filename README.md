# AIMS ERP — Backend

Multi-tenant Academic Information Management System for Indian colleges, built
to produce **NAAC Criteria 1 (Curricular Aspects)** reporting from real academic
master data.

Elixir · Phoenix · PostgreSQL · Ecto · Triplex · ExUnit · Postman.

> **Status: Milestone 1 — Tenant Infrastructure.**
> The platform layer is complete: a college can be provisioned as a tenant with
> its own isolated PostgreSQL schema, resolved from a request, and operated on
> without any chance of cross-tenant leakage. The AIMS academic domain
> (programmes, courses, curricula, NAAC data) is **not** implemented yet — see
> [Roadmap](#roadmap). One tenant table, `departments`, exists as the first
> slice of Academic Structure and as the isolation proof.

---

## Contents

- [Quick start](#quick-start)
- [Architecture](#architecture)
- [How tenant schemas work](#how-tenant-schemas-work)
- [Creating a tenant](#creating-a-tenant)
- [Tenant resolution](#tenant-resolution)
- [Dates and times](#dates-and-times)
- [Writing tenant-scoped code](#writing-tenant-scoped-code)
- [How tenant migrations work](#how-tenant-migrations-work)
- [Adding a new tenant-domain migration](#adding-a-new-tenant-domain-migration)
- [API reference](#api-reference)
- [Running the tests](#running-the-tests)
- [Using the Postman collection](#using-the-postman-collection)
- [Security notes](#security-notes)
- [Roadmap](#roadmap)

---

## Quick start

**Prerequisites:** Elixir 1.18+, Erlang/OTP 25+, PostgreSQL 14+ running locally.

```bash
mix deps.get                      # fetch dependencies
mix ecto.create                   # create the aims_dev database
mix ecto.migrate                  # public schema: tenants, patterns, versions
mix run priv/repo/seeds.exs       # provision two demo colleges (optional)
mix phx.server                    # http://localhost:4000
```

Database credentials live in `config/dev.exs` and default to
`postgres` / `postgres` on `localhost`. Change them there if yours differ.

Confirm it is alive:

```bash
curl http://localhost:4000/api/v1/health
# {"data":{
#   "status":"ok",
#   "latest_tenant_migration":20250101000001,
#   "lagging_tenants":[],
#   "server_time_utc":"2026-08-31T05:44:56.329000Z",
#   "server_time_local":"2026-08-31T11:14:56.329000+05:30",
#   "default_time_zone":"Asia/Kolkata"
# }}
```

---

## Architecture

Two layers, deliberately separated.

```
                         AIMS Platform
                               │
            ┌──────────────────┴──────────────────┐
            │                                     │
   Tenant / Platform layer            Tenant Application (AIMS ERP)
   Aims.Platform                      Aims.Academics, and the AIMS
   Aims.Tenancy                       domain contexts to come
            │                                     │
   ┌────────▼─────────┐              ┌────────────▼────────────┐
   │  public schema   │              │  tenant_<code> schema   │
   │                  │              │                         │
   │  tenants         │  1 : 1       │  departments            │
   │  academic_       │─────────────▶│  (programs, courses,    │
   │    patterns      │              │   curriculums, NAAC     │
   │  tenant_schema_  │              │   data — Milestone 2+)  │
   │    versions      │              │  schema_migrations      │
   └──────────────────┘              └─────────────────────────┘
```

### Module map

| Module | Responsibility |
| --- | --- |
| `Aims.Platform` | The platform context. Tenant registry, lifecycle, reference data. |
| `Aims.Platform.Tenant` | Tenant schema and changesets. Derives `tenant_slug`; locks immutable fields. |
| `Aims.Platform.TenantSlug` | **Security boundary.** Derives and validates the identifier that reaches DDL. |
| `Aims.Time` | UTC in, tenant-local ISO 8601 out. The single time-rendering rule. |
| `Aims.Platform.TenantProfile` | Resolves the two config flags into an immutable capability profile. |
| `Aims.Platform.Provisioner` | The provisioning saga, with explicit failure and recovery states. |
| `Aims.Platform.TenantMigrator` | Schema creation, tenant migrations, multi-tenant rollout. |
| `Aims.Tenancy.Context` | The current tenant, scoped to the executing process. |
| `Aims.Tenancy.Repo` | Repo operations bound to the current tenant's schema. |
| `Aims.Academics` | Academic Structure context. First slice: departments. |
| `AimsWeb.Plugs.ResolveTenant` | Resolves and validates the tenant for a request. |

### Column naming

One rule, applied consistently:

> Prefix a column with the entity name **only when the table name does not
> already convey it.**

A row in `tenants` *is* an institution, but the table is named for the platform
concept — so those columns are `institution_code`, `institution_name`,
`institution_type`, `autonomy_status`. In `departments` the table name already
says what `code` and `name` describe, so they stay bare.

`lifecycle_status` is spelled out rather than left as `status`, because the same
row also carries `autonomy_status` and a bare `status` beside it reads
ambiguously.

### Why the two flags matter

A tenant carries exactly two pieces of configuration, and between them they
drive the whole application:

| Flag | Values | Decides |
| --- | --- | --- |
| `institution_type` | `ENGINEERING`, `ARTS_SCIENCE` | Which **fields** apply — OBE / CO-PO matrix, experiential learning variant |
| `autonomy_status` | `AFFILIATED`, `AUTONOMOUS` | Which **marks** apply — Criteria 1 out of 100 or 150 — and whether the college designs its own syllabus |

`Aims.Platform.TenantProfile` resolves these **once**, at the edge of a request,
into a struct with a `features` map. The rule the codebase follows:

> Nothing below the resolver branches on `institution_type` or
> `autonomy_status`. Callers read a named feature flag.

```elixir
# Do this
if TenantProfile.feature?(profile, :obe_mapping), do: ...

# Never this
if tenant.institution_type == "ENGINEERING", do: ...
```

That discipline is what makes "an Arts & Science college that voluntarily
adopted OBE" a data change instead of a code change, and it keeps the four-way
matrix from leaking into a hundred call sites.

---

## How tenant schemas work

Every college gets its own PostgreSQL schema. Tenant tables carry **no
`tenant_id` column** — isolation is the schema boundary itself.

```
aims_dev
├── public
│   ├── tenants                     institution_code, tenant_slug,
│   │                               institution_type, autonomy_status,
│   │                               lifecycle_status, time_zone
│   ├── academic_term_patterns      SEMESTER / TRIMESTER / ANNUAL
│   ├── tenant_migration_versions   which college has which migration
│   └── schema_migrations           public migration state
│
├── tenant_c_41207                  ABC Institute of Technology
│   ├── departments
│   └── schema_migrations           this college's migration state
│
└── tenant_c_55891                  St Xavier College of Arts and Science
    ├── departments
    └── schema_migrations
```

### Multi-tenancy is Triplex

[Triplex](https://hex.pm/packages/triplex) drives the schema plumbing:
`CREATE SCHEMA`, `DROP SCHEMA`, running the tenant migration line against a
prefix, and the prefix itself. Configured in `config/config.exs`:

```elixir
config :triplex, repo: Aims.Repo, tenant_prefix: "tenant_"
```

**Triplex owns** schema lifecycle, the migration runner and `to_prefix/1`.
**This codebase keeps** the *grammar* for tenant identifiers, the rollout across
colleges with per-tenant failure isolation, and the
`tenant_migration_versions` projection. Triplex has no notion of any of those.

### Schema naming

`tenant_slug` is **derived server-side** from the institution code, never
accepted from a client. Triplex then supplies the prefix:

```
"C-41207"  ->  slug "c_41207"  ->  schema "tenant_c_41207"
```

The grammar is deliberately narrow — `[a-z0-9_]{1,55}` — and enforced in three
places: `Aims.Platform.TenantSlug`, a changeset validation, and a PostgreSQL
`CHECK` constraint on the column. The slug is interpolated into DDL where no
parameter binding is possible, so the only defence is that an unsafe value is
impossible to construct. Triplex's own reserved-tenant list is consulted too.

### Foreign keys never cross a schema boundary

Tenant tables reference platform reference data by **stable string code**, not
by foreign key. For example a programme will hold `pattern_code = "SEMESTER"`
rather than a FK into `public.academic_term_patterns`.

This keeps each tenant schema independently dumpable and restorable, which is
the main reason to choose schema-per-tenant for accreditation data:

```bash
pg_dump -n tenant_c_41207 aims_dev > abc_institute.sql
```

---

## Creating a tenant

### Over the API

```bash
curl -X POST http://localhost:4000/api/v1/tenants \
  -H 'Content-Type: application/json' \
  -d '{
        "institution_code": "C-41207",
        "institution_name": "ABC Institute of Technology",
        "institution_type": "ENGINEERING",
        "autonomy_status": "AUTONOMOUS",
        "time_zone": "Asia/Kolkata"
      }'
```

An **affiliated** college must also supply `affiliating_university` — it is
required to report BoS and syllabus compliance against its parent university:

```bash
curl -X POST http://localhost:4000/api/v1/tenants \
  -H 'Content-Type: application/json' \
  -d '{
        "institution_code": "C-55891",
        "institution_name": "St Xavier College of Arts and Science",
        "institution_type": "ARTS_SCIENCE",
        "autonomy_status": "AFFILIATED",
        "affiliating_university": "University of Madras"
      }'
```

### In IEx

```elixir
iex -S mix

{:ok, tenant} = Aims.Platform.create_tenant(%{
  "institution_code" => "C-41207",
  "institution_name" => "ABC Institute of Technology",
  "institution_type" => "ENGINEERING",
  "autonomy_status" => "AUTONOMOUS"
})
```

### What provisioning actually does

```
insert registry row (PROVISIONING)   ← committed first, so an orphan schema is impossible
        ↓
check for a schema-name collision
        ↓
Triplex.create -> CREATE SCHEMA tenant_c_41207
                  + run every tenant migration, in one transaction
        ↓
seed initial records                 ← extension point; nothing to seed today
        ↓
mark ACTIVE                          ← the only status the application will serve
```

This is a **saga with an explicit terminal state**, not one transaction. It
cannot be one transaction: `Ecto.Migrator` manages its own transactions and its
own advisory lock, and wrapping it would deadlock or defeat the lock.

**If any step fails**, the schema is dropped and the tenant moves to
`PROVISION_FAILED`. That status is visible, queryable and retryable — and it is
never `ACTIVE`, so a half-provisioned college can never serve a request:

```bash
curl 'http://localhost:4000/api/v1/tenants?status=PROVISION_FAILED'
curl -X POST http://localhost:4000/api/v1/tenants/1/retry     # repair it
curl -X DELETE http://localhost:4000/api/v1/tenants/1         # discard it entirely
```

`DELETE` works **only** on `PROVISION_FAILED`. A college that has ever been
active holds accreditation records; its terminal state is `ARCHIVED`, never
deletion.

### Tenant lifecycle

```
PROVISIONING ──✓──▶ ACTIVE ⇄ SUSPENDED
      │                │
      ✗                └────▶ ARCHIVED   (terminal, data retained)
      │
      ▼
PROVISION_FAILED ──retry──▶ ACTIVE
      │
      └──discard──▶ gone (schema dropped, row deleted)
```

Only `ACTIVE` tenants can serve requests.

---

## Tenant resolution

```
HTTP request
     ↓
ResolveTenant plug
     ↓  strategies, in priority order
     │  1. authenticated session   (seam — inert until auth lands)
     │  2. subdomain               abc.aims.example.com  → code "abc"
     │  3. x-tenant header         the college's AISHE / NAAC code
     ↓
tenant must exist and be ACTIVE
     ↓
TenantProfile resolved and installed into the process context
     ↓
controller → context → Aims.Tenancy.Repo → tenant schema
```

```bash
curl -H 'x-tenant: C-41207' http://localhost:4000/api/v1/tenant
curl -H 'x-tenant: C-41207' http://localhost:4000/api/v1/departments
```

Failures are distinct and deliberate:

| Situation | Status | `errors.code` |
| --- | --- | --- |
| No tenant given | `400` | `tenant_not_specified` |
| Unknown college | `404` | `tenant_not_found` |
| Suspended / archived / half-provisioned | `403` | `tenant_inactive` |
| Client-supplied tenant disallowed | `403` | `tenant_resolution_forbidden` |

"Unknown" and "inactive" are kept apart on purpose — collapsing them would make
a typo indistinguishable from a suspension.

### ⚠️ Milestone 1 security posture

Authentication does not exist yet, so strategies 2 and 3 are **unauthenticated**:
any caller can name any tenant. This is acceptable for a milestone whose
acceptance criteria are provisioning and isolation, and **unacceptable in
production**.

The seam is already in place. When auth lands, strategy 1 starts matching first
and you set:

```elixir
config :aims, allow_client_supplied_tenant: false
```

after which a client-named tenant is refused outright. Nothing downstream
changes, because everything downstream already reads the resolved profile.

---

## Dates and times

One rule, applied everywhere:

```
PostgreSQL stores UTC        every timestamp column is timestamptz
Elixir holds UTC             every DateTime in the domain is UTC
The API returns local time   ISO 8601 with an explicit offset
```

A response looks like this:

```json
{ "inserted_at": "2026-08-31T11:13:36.573000+05:30", "time_zone": "Asia/Kolkata" }
```

### Why the offset matters more than the zone

Returning `"2026-08-31T11:13:36"` and telling clients "it's IST" is exactly the
confusion this design prevents — a client that assumes UTC is wrong by five and
a half hours and nothing in the payload says so.

`+05:30` in the string cannot be misread. Every ISO 8601 parser in every
language handles it, and `Date.parse()` in JavaScript yields the correct instant
without the client knowing anything about India.

### Which zone is used

| Response | Zone |
| --- | --- |
| Tenant-scoped (`/departments`, `/tenant`) | That college's `time_zone` |
| Platform-level (`/tenants`, `/health`) | `config :aims, :default_time_zone` |

`tenants.time_zone` defaults to `Asia/Kolkata` and is validated on write against
the IANA database, so an unusable zone is rejected at the API rather than
silently degrading every later response. It affects **presentation only** —
stored values never move.

```bash
# Confirm at a glance that storage is UTC and presentation is IST
curl http://localhost:4000/api/v1/health
```

The time zone database is [`tz`](https://hex.pm/packages/tz), chosen over
`tzdata` because tzdata pulls in `hackney` for auto-updates and hackney
currently carries four open CVEs including one rated HIGH.

### In code

```elixir
Aims.Time.utc_now()                              # the only way to read the clock
Aims.Time.render(dt, "Asia/Kolkata")             # "...+05:30"
Aims.Time.render(dt)                             # platform default zone
```

Never convert by hand. `DateTime.add(dt, 19_800)` looks tempting because IST has
no daylight saving, but it produces a `DateTime` whose `time_zone` says
`Etc/UTC` while its fields say otherwise, and it stops being correct the moment
a non-IST college exists.

---

## Writing tenant-scoped code

Tenant-domain functions take **no tenant argument**. There is no `tenant_id`
column to filter on; the schema comes from the process context.

```elixir
alias Aims.Tenancy.Context

Context.put(profile)
Aims.Academics.list_departments()      # queries tenant_c_41207.departments

Context.with_tenant(other_profile, fn ->
  Aims.Academics.list_departments()    # queries the other tenant
end)                                   # previous context restored, even on raise
```

Inside a context module, use `Aims.Tenancy.Repo` instead of `Aims.Repo`:

```elixir
defmodule Aims.Academics do
  alias Aims.Tenancy.Repo, as: TenantRepo

  def list_departments do
    Department |> order_by([d], asc: d.code) |> TenantRepo.all()
  end
end
```

### Two rules

1. **Never use `Aims.Repo` directly for a tenant table.** It has no prefix and
   would look in `public`.
2. **The context does not cross process boundaries.** `Task.async`, GenServers
   and background jobs start with an empty context. Capture the profile in the
   parent and re-establish it with `with_tenant/2`.

`Aims.Tenancy.Repo` raises `Aims.Tenancy.MissingTenantError` when no tenant is
set, so a missed hand-off fails loudly rather than reading the wrong schema.

### Why `prefix:` and not `SET LOCAL search_path`

Ecto's query prefix compiles to `SELECT ... FROM "tenant_c_41207"."departments"`.
The prefix travels with the query, so unlike `search_path` there is no window in
which a pooled connection is mis-set — and no reliance on every tenant query
running inside a transaction. `search_path` is never set anywhere in this
application; mixing the two would reintroduce exactly the ambient state this
avoids.

---

## How tenant migrations work

Two independent version lines, because they change for different reasons:

| Directory | Applies to | Command |
| --- | --- | --- |
| `priv/repo/migrations` | `public` schema | `mix ecto.migrate` |
| `priv/repo/tenant_migrations` | every tenant schema | `mix aims.tenants.migrate` |

### The three scenarios that must all work

```
New tenant             Provisioning runs the full tenant migration set
                       into the fresh schema.

App version changes    mix aims.tenants.migrate walks every tenant and
                       applies whatever each one is missing.

Interrupted rollout    Re-run it. A tenant already at the current version
                       is a no-op, so the run is resumable.
```

### Commands

```bash
mix aims.tenants.status                  # every tenant, its schema, pending count
mix aims.tenants.migrate                 # roll out to all serving tenants
mix aims.tenants.migrate --tenant C-41207   # just one
mix aims.tenants.migrate --all-statuses  # include ARCHIVED / PROVISION_FAILED
```

Example:

```
$ mix aims.tenants.status
Tenant migration line: 20250101000001
Tenants: 2

CODE          SCHEMA                  STATUS            TYPE          AUTONOMY    MIGRATIONS
C-41207       tenant_c_41207          ACTIVE            ENGINEERING   AUTONOMOUS  up to date
C-55891       tenant_c_55891          ACTIVE            ARTS_SCIENCE  AFFILIATED  up to date
```

### Failure handling

Tenants are migrated **one at a time and independently**. A failure is logged,
recorded, and the run continues — one broken schema cannot strand the rest. The
task exits non-zero and names every tenant that failed:

```
  ok      C-41207
  FAILED  C-55891: ERROR 42P01 relation "x" does not exist

1 migrated, 1 failed
```

### Version tracking

Ecto maintains a `schema_migrations` table **inside each tenant schema**. That
is the authority — it is what the migrator reads to decide what is pending.

`public.tenant_migration_versions` is a projection of those tables, refreshed after
every run, so the orchestrator can find lagging tenants with one query instead
of opening every schema. It never decides whether a migration runs.

```bash
curl http://localhost:4000/api/v1/health          # names any lagging tenants
curl http://localhost:4000/api/v1/tenants/1/schema  # one tenant's exact state
```

---

## Adding a new tenant-domain migration

1. **Create the file** in `priv/repo/tenant_migrations/`, named
   `<utc_timestamp>_<description>.exs`. There is no generator for tenant
   migrations — `mix ecto.gen.migration` targets `public`.

   ```bash
   # timestamp helper
   date -u +%Y%m%d%H%M%S
   ```

2. **Write it with no tenancy of its own.** No `tenant_id` column, no
   `prefix:` — the migrator supplies the prefix.

   ```elixir
   defmodule Aims.Repo.TenantMigrations.CreatePrograms do
     use Ecto.Migration

     def up do
       create table(:programs) do
         add :owning_department_id, references(:departments, on_delete: :restrict), null: false
         add :code, :string, size: 50, null: false
         add :name, :string, size: 255, null: false
         add :pattern_code, :string, size: 20, null: false   # public.academic_term_patterns.code
         timestamps(type: :utc_datetime_usec)
       end

       create unique_index(:programs, [:code])
     end

     def down, do: drop table(:programs)
   end
   ```

   **Use `on_delete: :restrict`, not `:delete_all`**, for anything that will
   carry accreditation evidence. This is a record store; a cascading delete of a
   programme would destroy BoS approval documents a submitted report cites.

   **Reference platform data by code, not by FK** — foreign keys must not cross
   a schema boundary.

3. **Roll it out.**

   ```bash
   mix aims.tenants.migrate
   mix aims.tenants.status     # confirm every tenant is up to date
   ```

4. **Add the Ecto schema and context**, using `Aims.Tenancy.Repo`.

5. **Add tests**, including a cross-tenant isolation case for the new table.

---

## API reference

Base path `/api/v1`. All responses are JSON.

### Platform — no tenant resolved

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Liveness, tenant migration line, lagging colleges, server clock in UTC **and** local |
| `GET` | `/academic-term-patterns` | Term patterns reference data (SEMESTER / TRIMESTER / ANNUAL) |

### Tenant management — no tenant resolved

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/tenants` | List tenants; `?status=ACTIVE` filters |
| `POST` | `/tenants` | Register **and provision** a college |
| `GET` | `/tenants/:id` | Show one tenant |
| `PATCH` `PUT` | `/tenants/:id` | Update `institution_name`, `affiliating_university`, `time_zone` |
| `DELETE` | `/tenants/:id` | Discard a `PROVISION_FAILED` tenant |
| `GET` | `/tenants/:id/schema` | Schema existence and migration state |
| `POST` | `/tenants/:id/migrations` | Migrate one tenant |
| `POST` | `/tenants/migrations` | Roll out to every tenant |
| `POST` | `/tenants/:id/retry` | Retry a failed provision |
| `POST` | `/tenants/:id/suspend` | Stop serving; retain data |
| `POST` | `/tenants/:id/activate` | Resume serving |
| `POST` | `/tenants/:id/archive` | Terminal state; retain data |

### Tenant-scoped — require `x-tenant` or a subdomain

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/tenant` | The resolved tenant and its capability profile |
| `GET` | `/departments` | List; `?active=true` filters |
| `POST` | `/departments` | Create |
| `GET` | `/departments/:id` | Show |
| `PATCH` `PUT` | `/departments/:id` | Update |
| `POST` | `/departments/:id/deactivate` | Soft-deactivate |

### Response shapes

Success wraps a `data` key:

```json
{
  "data": {
    "id": 1,
    "institution_code": "C-41207",
    "institution_name": "ABC Institute of Technology",
    "tenant_slug": "c_41207",
    "schema_name": "tenant_c_41207",
    "lifecycle_status": "ACTIVE",
    "time_zone": "Asia/Kolkata",
    "inserted_at": "2026-08-31T11:13:36.573000+05:30"
  }
}
```

Two error shapes, both under `errors`, unambiguous to tell apart — a reasoned
failure carries `code` and `detail`, a validation failure carries field keys and
no `detail`:

```json
{ "errors": { "code": "tenant_not_found", "detail": "No college is registered with the code \"C-XYZ\"." } }
```

```json
{
  "errors": {
    "institution_code": ["has already been taken"],
    "affiliating_university": ["is required for an affiliated college"],
    "time_zone": ["is not a recognised IANA time zone, for example Asia/Kolkata"]
  }
}
```

| Status | When |
| --- | --- |
| `200` / `201` | Success |
| `204` | Deleted |
| `400` | No tenant specified |
| `403` | Tenant inactive, or client-supplied tenant disallowed |
| `404` | Resource or tenant not found |
| `409` | Lifecycle conflict — schema collision, not discardable, not retryable |
| `422` | Validation failure |
| `500` | Provisioning failed |

---

## Running the tests

```bash
mix test                                   # everything
mix test test/aims/tenancy/isolation_test.exs   # the isolation proof
mix test --cover
mix compile --warnings-as-errors           # must be clean
```

The failure-path tests deliberately provoke migration errors, so **`[error]` log
lines during a green run are expected** — they are the abort path being
exercised.

### Layout

| Path | Covers |
| --- | --- |
| `test/aims/platform/tenant_slug_test.exs` | Identifier grammar, adversarially |
| `test/aims/time_test.exs` | UTC storage, IST rendering, offset correctness |
| `test/aims/platform/tenant_test.exs` | Changesets, immutable fields, mass assignment |
| `test/aims/platform/tenant_profile_test.exs` | All four institution configurations |
| `test/aims/platform/provisioner_test.exs` | Provisioning, failure, retry, discard |
| `test/aims/platform/tenant_migrator_test.exs` | Schema lifecycle, versions, rollout |
| `test/aims/tenancy/isolation_test.exs` | **The mandatory isolation proof** |
| `test/aims_web/plugs/resolve_tenant_test.exs` | Resolution and its failure modes |
| `test/aims_web/controllers/*_test.exs` | API contract, cross-tenant attempts |

### A note on the isolation tests

Both tenants' first department is `id = 1`, because each schema has its own
sequence. A test that only asserts "found / not found" would therefore pass even
under a leak. The suite avoids that trap by asserting on **contents** for
colliding ids, and by giving tenant B an extra row so it holds an id that does
not exist in tenant A at all.

---

## Using the Postman collection

```
postman/
├── AIMS-ERP.postman_collection.json
├── AIMS-Local.postman_environment.json
└── README.md    ← full guide: setup, folder walkthrough, troubleshooting
```

**[→ postman/README.md](postman/README.md)** covers this in depth. The short
version: import both files, select the **AIMS Local** environment, and run the
collection top to bottom. Or from the command line:

```bash
npx newman run postman/AIMS-ERP.postman_collection.json \
                -e postman/AIMS-Local.postman_environment.json
```

```
Folders
├── Platform            health, reference data
├── Tenant Management   provision, list, update, lifecycle, migrations
├── Tenant Context      resolution + the profile each configuration produces
├── Academic Structure  departments in each tenant
├── Tenant Isolation    cross-tenant attempts — all must be refused
├── Failure Cases       422 / 404 / 409 / 403 with exact error shapes
└── Cleanup             archives the colleges this run created
```

The collection is **re-runnable**: a collection-level pre-request script mints a
fresh pair of college codes at the start of each run, so repeated runs do not
collide on the unique tenant code. Ids are captured into variables as it goes,
so later folders depend on earlier ones — run the whole collection, not
individual requests, on a fresh database.

To reclaim the schemas that accumulate across runs:

```bash
mix ecto.drop && mix ecto.create && mix ecto.migrate
```

### Environment variables

| Variable | Purpose |
| --- | --- |
| `base_url` | `http://localhost:4000` |
| `token` | Bearer token. Empty in Milestone 1; wired up for the auth milestone. |

`tenant_a_code`, `tenant_b_code`, and the various ids are managed by the
collection itself.

---

## Security notes

Tenant isolation is treated as a **security boundary**: a failure is not a
leaked row, it is one college reading another college's accreditation data.

| Risk | Mitigation |
| --- | --- |
| Schema-name injection | `Aims.Platform.TenantSlug.safe!/1` guards every interpolation into DDL, including everything handed to Triplex. Grammar is `[a-z0-9_]{1,55}`, enforced again by a database `CHECK`. |
| SQL injection | All values are bound parameters. The only interpolated identifiers are schema names, which pass the guard above. |
| Cross-tenant reads | Every tenant query carries an explicit prefix. No prefix means an error, never a fallback to another schema. |
| Unauthorised tenant switching | ⚠️ **Open in Milestone 1** — see [Tenant resolution](#tenant-resolution). |
| Vulnerable dependencies | `mix deps.get` reports advisories. `tzdata` was rejected for this reason; `tz` is used instead. Re-check on every dependency bump. |
| Mass assignment | Changesets cast an explicit field list. `institution_code`, `tenant_slug`, `institution_type`, `autonomy_status` and `lifecycle_status` cannot be set or changed by a client. |
| Error leakage | Errors carry a stable machine-readable code and a human message. Stack traces and raw driver errors are not returned. |
| Accidental data loss | `PROVISION_FAILED` is the only deletable state. Everything else archives. |

### Verifying isolation yourself

```bash
mix test test/aims/tenancy/isolation_test.exs
```

Or by hand, against a seeded database:

```bash
curl -H 'x-tenant: C-41207' localhost:4000/api/v1/departments   # CSE, MAT
curl -H 'x-tenant: C-55891' localhost:4000/api/v1/departments   # ENG, COM
```

Or in the database directly:

```sql
SELECT 'A' AS tenant, code FROM tenant_c_41207.departments
UNION ALL
SELECT 'B', code FROM tenant_c_55891.departments;
```

---

## Roadmap

Milestone 1 is complete. The order below follows the dependency graph of the
approved architecture, not feature appeal.

| Milestone | Contents |
| --- | --- |
| **1 — Tenant infrastructure** ✅ | Registry, provisioning, schema isolation, tenant migrations, resolution, tenant API |
| **2 — Identity & authorisation** | Users, tenant membership, roles, authenticated tenant resolution, audit log. Closes the open security item above, and gives `departments.hod_user_id` something real to point at. |
| **3 — Academic Structure** | Programmes and the course catalogue. A course carries **no** `is_elective` or `semester` — role is contextual to a curriculum. |
| **4 — Academic Execution** | Academic years, batches, operational term schedules with real dates per cohort |
| **5 — Curriculum** | Versioned curricula by admission batch, curriculum terms, core bindings, publish lifecycle |
| **6 — Electives & streams** | Elective groups with min/max selection, specialisation streams spanning terms |
| **7 — Evidence** | Documents as immutable, checksummed, re-usable artefacts. Built **before** the collection screens that need it. |
| **8 — NAAC Criteria 1 data** | QlM narratives, cross-cutting mappings, add-on offerings, experiential learning, feedback, OBE |
| **9 — Rules & validation** | Versioned metric definitions, profile-driven rule engine, readiness dashboard |
| **10 — Reporting** | Metric calculation, frozen report runs, DVV evidence bundle export |

### Known open items

- **Authentication and authorisation are not implemented.** Tenant resolution is
  currently unauthenticated. This is the single most important item in
  Milestone 2.
- **NAAC metric definitions are unverified.** The mark weightages and metric
  numbering in the source architecture come from a design conversation, not the
  official NAAC manual. Every formula must be checked against the current SSR
  manual before it is coded — this is tracked as risk `R-01` in the architecture
  document.
- **No `students` table.** Deliberate. Criteria 1 needs aggregate counts, not a
  student master; the full student model arrives only when a later criterion
  requires it.
