# AIMS — Postman Guide

Two collections, split along the same line as the codebase.

```
postman/
├── AIMS-Platform.postman_collection.json   Tenant management   8 folders · 32 requests · 94 assertions
├── AIMS-ERP.postman_collection.json        Academic domain     5 folders · 23 requests · 50 assertions
├── AIMS-Local.postman_environment.json     Shared: base_url + token
├── build_collections.py                    Generator — edit this, not the JSON
└── README.md                               this file
```

| | **AIMS Platform** | **AIMS ERP** |
| --- | --- | --- |
| Owns | Onboarding a college, its lifecycle, its schema and migrations, how a request resolves to it | Everything *inside* a college's own schema |
| Schema | `public` | `tenant_<slug>` |
| Endpoints | `/health`, `/academic-term-patterns`, `/tenants*`, `/tenant` | `/departments*` |
| Grows with | Identity, roles, audit (Milestone 2) | Programmes, courses, curricula, NAAC data (Milestone 3+) |

They were one collection until the folder list stopped being scannable. The
split follows the architecture: the platform layer knows about tenants and
nothing else; the AIMS domain knows about academics and never about tenancy.

**Both are independently runnable.** The ERP collection provisions its own two
colleges in folder `0 · Setup`, so it works on a fresh database without the
Platform collection ever having run.

---

## 1. Before you run anything

Both collections talk to a live server against a live database.

```bash
# from the repository root
mix deps.get
mix ecto.create          # creates aims_dev
mix ecto.migrate         # public schema: tenants, term patterns, versions
mix phx.server           # http://localhost:4000
```

Confirm it is up — this is also the Platform collection's first request:

```bash
curl http://localhost:4000/api/v1/health
```

```json
{"data":{
  "status":"ok",
  "latest_tenant_migration":20250101000001,
  "lagging_tenants":[],
  "server_time_utc":"2026-08-31T06:12:11.310000Z",
  "server_time_local":"2026-08-31T11:42:11.310000+05:30",
  "default_time_zone":"Asia/Kolkata"
}}
```

**You do not need to run the seeds.** Each collection provisions its own
colleges. `mix run priv/repo/seeds.exs` is for browsing by hand.

---

## 2. Running — Postman app

1. **Import** → drag all three `.json` files in.
2. Environment selector (top right) → choose **AIMS Local**.
3. Click a collection in the sidebar → **Run**.

| Collection | Expect |
| --- | --- |
| AIMS Platform · Tenant Management | 32 requests, **94 assertions**, 0 failures |
| AIMS ERP · Academic Domain | 23 requests, **50 assertions**, 0 failures |

Run them in either order, as many times as you like.

---

## 3. Running — command line

```bash
npx newman run postman/AIMS-Platform.postman_collection.json \
                -e postman/AIMS-Local.postman_environment.json

npx newman run postman/AIMS-ERP.postman_collection.json \
                -e postman/AIMS-Local.postman_environment.json
```

Useful variants:

```bash
# point at another environment
npx newman run ... --env-var base_url=https://staging.example.com

# CI: non-zero exit on any failed assertion, plus a JUnit report
npx newman run ... --reporters cli,junit --reporter-junit-export newman.xml
```

---

## 4. ⚠️ Run a whole collection, not single requests

Within a collection, requests share state. `Onboard College A` stores the new id
into `{{tenant_a_id}}`, and a dozen later requests read it.

Fire `Get College` on its own against a fresh database and you hit
`/api/v1/tenants/` with an empty id — a confusing 404 that is the collection's
fault, not the API's.

The same applies to `--folder`. Only the first folder of each collection is
self-contained; everything after depends on the colleges it creates. Pass
several `--folder` flags in order:

```bash
npx newman run postman/AIMS-ERP.postman_collection.json \
                -e postman/AIMS-Local.postman_environment.json \
                --folder "0 · Setup" \
                --folder "1 · Departments" \
                --folder "2 · Tenant Data Isolation"
```

To poke at one endpoint by hand, run the onboarding folder first so the
variables are populated, then experiment.

---

## 5. AIMS Platform — what each folder proves

| Folder | Reqs | Establishes |
| --- | --- | --- |
| **1 · Health & Reference** | 2 | Service is alive; term patterns are platform-wide, not copied per college |
| **2 · Onboarding** | 5 | A college can be provisioned end to end — registry row, schema, migrations, ACTIVE |
| **3 · Configuration & Profile** | 4 | The two flags resolve to the right capability profile; immutable fields cannot be reassigned |
| **4 · Schema & Migrations** | 3 | Schema state is reportable; migrations roll out and are safe to repeat |
| **5 · Lifecycle** | 5 | PROVISIONING → ACTIVE ⇄ SUSPENDED → ARCHIVED, and what is refused |
| **6 · Tenant Resolution** | 4 | How a request finds its college, and how it fails when it cannot |
| **7 · Validation Failures** | 7 | Every documented 4xx shape for onboarding |
| **8 · Cleanup** | 2 | Archives the colleges this run created |

### The folder that carries the most weight

**3 · Configuration & Profile** is the point of the whole platform layer. The
same endpoint returns a different profile per college:

| | College A · Engineering + Autonomous | College B · Arts & Science + Affiliated |
| --- | --- | --- |
| `criteria_scale` | 150 | 100 |
| `obe_mapping` | `true` | `false` |
| `bos_curriculum_revision` | `true` | `false` |
| `faculty_bos_participation` | `false` | `true` |
| `experiential_variant` | `industry` | `field` |

That is the four-way institution matrix resolved **once**, at the edge of the
request, so nothing downstream branches on institution type.

### Isolation, at the resolution layer

`Resolve College B` asserts it resolves to a *different schema* than College A.
That proves the request routing switches correctly.

Proving the **data** is isolated needs tenant-scoped tables, so it lives in the
ERP collection — see §6. It is also covered exhaustively in ExUnit
(`test/aims/tenancy/isolation_test.exs`).

---

## 6. AIMS ERP — what each folder proves

| Folder | Reqs | Establishes |
| --- | --- | --- |
| **0 · Setup** | 2 | Provisions two colleges, so the collection stands alone |
| **1 · Departments** | 9 | Tenant-scoped CRUD inside a college's own schema |
| **2 · Tenant Data Isolation** | 7 | **The security proof.** Every cross-college attempt is refused |
| **3 · Validation Failures** | 3 | Domain validation shapes |
| **4 · Cleanup** | 2 | Archives the colleges this run created |

### Why folder 2 is written the way it is

Both colleges' first department is `id = 1`, because each schema has its own
sequence. A test that only asserted "found / not found" would therefore pass
even under a leak. The folder avoids that trap three ways:

1. **An id that exists only in College B** — College A fetching it must 404. A
   leak surfaces here as a successful fetch.
2. **A colliding id** — College B fetching College A's id gets `200`, and the
   assertion checks the *contents* are College B's row, not College A's.
3. **A follow-up read** — after every cross-tenant attempt, College B's list is
   re-read to confirm nothing was hijacked and nothing was deactivated.

---

## 7. Variables

The environment file holds only two, on purpose:

| Variable | Value | Notes |
| --- | --- | --- |
| `base_url` | `http://localhost:4000` | Change for staging/prod |
| `token` | *(empty)* | Bearer auth is wired up but unused — Milestone 1 has no authentication |

Everything else is a **collection** variable managed by scripts. The two
collections use different names on purpose, so running both never crosses wires:

| Platform | ERP | Set by |
| --- | --- | --- |
| `run_stamp` | `run_stamp` | Collection pre-request, once per run |
| `tenant_a_code` / `tenant_b_code` | `erp_a_code` / `erp_b_code` | Derived from `run_stamp` |
| `tenant_a_id` / `tenant_b_id` | `erp_a_id` / `erp_b_id` | The onboarding requests |
| — | `dept_a_id` / `dept_b_id` / `dept_b_only_id` | The Departments requests |

> **Do not add these ids to the environment file.** Environment scope
> *overrides* collection scope in Postman, so empty environment values silently
> shadow the captured ids and every dependent request breaks. That was a real
> bug in an earlier version of this collection.

---

## 8. Both are re-runnable

A collection-level pre-request script mints fresh college codes at the start of
every run:

```js
const stamp = String(Date.now()).slice(-7);
set('tenant_a_code', 'C-A' + stamp);
set('tenant_b_code', 'C-B' + stamp);
```

So repeated runs never collide on the unique `institution_code`. The Cleanup
folder then archives them, keeping `GET /tenants?status=ACTIVE` meaningful.

What it does **not** do is delete them — an archived college keeps its schema,
because a college that has served requests holds accreditation records. Schemas
therefore accumulate. Check what has piled up:

```bash
mix aims.tenants.status
```

To reclaim them, **stop the server first**:

```bash
# Ctrl-C twice in the mix phx.server terminal, then
mix ecto.drop && mix ecto.create && mix ecto.migrate
```

`mix ecto.drop` refuses while anything holds a connection, and because the
commands are chained with `&&` the whole reset then silently does nothing:

```
** (Mix) The database for Aims.Repo couldn't be dropped:
   ERROR 55006 (object_in_use) database "aims_dev" is being accessed by other users
   There are 10 other sessions using the database.
```

A detached `mix phx.server`, an open `iex -S mix`, or a stray `psql` will each
do it. Confirm nothing is connected:

```bash
psql -h localhost -U postgres -tAc \
  "select count(*) from pg_stat_activity where datname='aims_dev';"
```

---

## 9. Reading the responses

### Success

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

Timestamps are stored UTC and returned in the college's own zone, as ISO 8601
**with the offset attached**. The `+05:30` is the point — a client that assumes
UTC cannot be silently wrong by five and a half hours.

### Errors — two shapes, unambiguous to tell apart

A reasoned failure carries `code` and `detail`:

```json
{"errors":{"code":"tenant_not_found","detail":"No college is registered with the code \"C-XYZ\"."}}
```

A validation failure is keyed by field and carries no `detail`:

```json
{"errors":{"institution_code":["has already been taken"]}}
```

| Status | Means |
| --- | --- |
| `400` | No tenant specified |
| `403` | College is suspended/archived, or client-supplied tenants are disabled |
| `404` | Resource or college not found |
| `409` | Lifecycle conflict — not discardable |
| `422` | Validation failure |
| `500` | Provisioning failed |

---

## 10. Tenant-scoped requests need a header

Anything under `/api/v1/departments` or `/api/v1/tenant` must say which college
it is for:

```
x-tenant: C-41207
```

A subdomain works too (`abc.aims.example.com`) and takes priority. Tenant
*management* endpoints (`/api/v1/tenants`) deliberately do **not** take the
header — provisioning a college cannot require that college to already be
resolvable.

> ⚠️ In Milestone 1 the header is **unauthenticated**: any caller can name any
> college. That is fine for provisioning and isolation testing, and not fine in
> production. The authenticated strategy is already first in the resolver's
> priority order and takes over when auth lands.

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ECONNREFUSED` | Server not running | `mix phx.server` |
| `404` on `/api/v1/tenants/` with empty id | Ran a single request instead of the collection | Run the whole collection, or the onboarding folder first |
| `422 has already been taken` on onboarding | Stale `run_stamp` | Start the run from the collection's first request, which mints fresh codes |
| `400 tenant_not_specified` | Missing `x-tenant` on a tenant-scoped request | Add the header |
| `tenant_not_found` where you expected `not_found` | Ran a dependent folder alone, so the college code is empty | Include the Setup / Onboarding folder |
| `403 tenant_inactive` | The college is SUSPENDED or ARCHIVED | `POST /api/v1/tenants/:id/activate` |
| Assertions fail after an interrupted run | A college left SUSPENDED by the 403 test | Reactivate it, or reset the database |
| `ERROR 55006 object_in_use` on `mix ecto.drop` | Server, IEx or psql still connected | Stop them all. The `&&` chain means the reset then does nothing — check for `0` in `pg_stat_activity` before retrying |
| Dozens of leftover `tenant_*` schemas | Normal — archived colleges keep their data | Stop the server, then drop/create/migrate |

---

## 12. Editing the collections

**Edit `build_collections.py`, then regenerate.** Both JSON files are generated:

```bash
python postman/build_collections.py
```

Hand-editing two large JSON files drifts them apart within a week; the generator
keeps shared pieces — the re-run stamping script, the archive request, the
validation-failure helper — defined once.

When you add an endpoint:

1. Put it in the collection that owns it. Tenant metadata → Platform. Anything
   inside a tenant schema → ERP.
2. Add a **happy path** and at least one **failure case**.
3. If it is tenant-scoped, add a **cross-college refusal** to *Tenant Data
   Isolation*.
4. Capture any new id with both `pm.collectionVariables.set` **and**
   `pm.environment.set` — the scoping reason in §7.
5. Regenerate, then run both collections twice to confirm they are still
   re-runnable.

Keep assertions specific. `pm.response.to.have.status(201)` alone says almost
nothing; assert what proves the behaviour — that the college came back `ACTIVE`
rather than merely registered, that the timestamp carries `+05:30`, that
College A's list does not contain College B's department.

> **Watch out for `data`.** Postman predefines it as a sandbox global for
> data-file variables, so `const data = pm.response.json().data;` throws
> `Identifier 'data' has already been declared`. Name the variable after the
> thing it holds.
