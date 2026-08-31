# AIMS ERP — Postman Guide

Everything needed to exercise the Milestone 1 API by hand or in CI.

```
postman/
├── AIMS-ERP.postman_collection.json    43 requests, 112 assertions
├── AIMS-Local.postman_environment.json base_url + token
└── README.md                           this file
```

---

## 1. Before you run anything

The collection talks to a live server against a live database. Three things
must be true first.

```bash
# from the repository root
mix deps.get
mix ecto.create          # creates aims_dev
mix ecto.migrate         # public schema: tenants, term patterns, versions
mix phx.server           # http://localhost:4000
```

Confirm it is up — this is also the collection's first request:

```bash
curl http://localhost:4000/api/v1/health
```

```json
{"data":{
  "status":"ok",
  "latest_tenant_migration":20250101000001,
  "lagging_tenants":[],
  "server_time_utc":"2026-08-31T05:44:56.329000Z",
  "server_time_local":"2026-08-31T11:14:56.329000+05:30",
  "default_time_zone":"Asia/Kolkata"
}}
```

**You do not need to run the seeds.** The collection provisions its own two
colleges. `mix run priv/repo/seeds.exs` is for browsing by hand, not for this.

---

## 2. Running it — Postman app

1. **Import** → drag both `.json` files in.
2. Top-right environment selector → choose **AIMS Local**.
3. Left sidebar → click the **AIMS ERP** collection → **Run**.
4. Leave the defaults on and hit **Run AIMS ERP**.

Expect **45 requests, 112 assertions, 0 failures**.

> Newman reports 45 where the collection lists 43. The two extra are
> `pm.sendRequest` calls inside *Suspended tenant cannot serve requests*, which
> suspends a college before the check and reactivates it afterwards so the
> collection stays re-runnable.

---

## 3. Running it — command line

```bash
npx newman run postman/AIMS-ERP.postman_collection.json \
                -e postman/AIMS-Local.postman_environment.json
```

Useful variants:

```bash
# a subset — but include the folders it depends on (see below)
npx newman run ... --folder "Platform" \
                   --folder "Tenant Management" \
                   --folder "Academic Structure" \
                   --folder "Tenant Isolation"

# point at another environment
npx newman run ... --env-var base_url=https://staging.example.com

# CI: non-zero exit on any failed assertion, plus a JUnit report
npx newman run ... --reporters cli,junit --reporter-junit-export newman.xml
```

---

## 4. ⚠️ Run the whole collection, not single requests

Requests share state. `Create Tenant A` stores the new id into
`{{tenant_a_id}}`, and roughly a dozen later requests read it.

Fire `Get Tenant` on its own against a fresh database and you will hit
`/api/v1/tenants/` with an empty id — a confusing 404 that is the collection's
fault, not the API's.

The same applies to folders. Only **Platform** and **Tenant Management** are
self-contained; everything after them depends on the colleges those create. Pass
several `--folder` flags in order, or just run the lot — it takes five seconds.

If you want to poke at one endpoint by hand, run the **Tenant Management** folder
first so the variables are populated, then experiment.

---

## 5. What each folder proves

| Folder | Requests | What it establishes |
| --- | --- | --- |
| **Platform** | 2 | Service is alive; term patterns are platform-wide reference data, not copied per college |
| **Tenant Management** | 12 | A college can be provisioned end to end, updated, migrated, suspended and reactivated |
| **Tenant Context** | 2 | Tenant resolution works, and the two config flags resolve to the right capability profile |
| **Academic Structure** | 9 | Tenant-scoped CRUD inside a college's own schema |
| **Tenant Isolation** | 5 | **The security boundary.** Every cross-college attempt is refused |
| **Failure Cases** | 11 | Validation, lifecycle and resolution failures return the documented shapes |
| **Cleanup** | 2 | Archives the two colleges this run created |

### The two that matter most

**Tenant Context** shows the whole point of the platform layer. The same
endpoint returns a different profile per college:

| | Tenant A · Engineering + Autonomous | Tenant B · Arts & Science + Affiliated |
| --- | --- | --- |
| `criteria_scale` | 150 | 100 |
| `obe_mapping` | `true` | `false` |
| `bos_curriculum_revision` | `true` | `false` |
| `faculty_bos_participation` | `false` | `true` |
| `experiential_variant` | `industry` | `field` |

**Tenant Isolation** is the security proof. It creates a department in each
college and then shows A cannot read, update or deactivate B's — including the
case where both colleges' first department is `id = 1`, since each schema has
its own sequence.

It cannot run on its own, though: it needs the colleges and departments the
earlier folders create. On its own you get

```
expected 'tenant_not_found' to deeply equal 'not_found'
```

which is the collection resolving an empty `{{tenant_a_code}}`, not an API
fault. Run it with its prerequisites:

```bash
npx newman run ... --folder "Platform" \
                   --folder "Tenant Management" \
                   --folder "Academic Structure" \
                   --folder "Tenant Isolation"
# 70 assertions, 0 failures
```

---

## 6. Variables

The environment file holds only two, on purpose:

| Variable | Value | Notes |
| --- | --- | --- |
| `base_url` | `http://localhost:4000` | Change for staging/prod |
| `token` | *(empty)* | Bearer auth is wired up but unused — Milestone 1 has no authentication |

Everything else is a **collection** variable managed by the scripts:

| Variable | Set by |
| --- | --- |
| `run_stamp` | Collection pre-request, once per run |
| `tenant_a_code` / `tenant_b_code` | Derived from `run_stamp` |
| `tenant_a_id` / `tenant_b_id` | `Create Tenant A` / `B` |
| `dept_a_id` / `dept_b_id` / `dept_b_only_id` | The Academic Structure requests |

> **Do not add these ids back into the environment file.** Environment scope
> *overrides* collection scope in Postman, so empty environment values silently
> shadow the captured ids and every dependent request breaks. That was a real
> bug in the first version of this collection.

---

## 7. It is re-runnable

A collection-level pre-request script mints a fresh pair of college codes at the
start of every run:

```js
const stamp = String(Date.now()).slice(-7);
set('tenant_a_code', 'C-A' + stamp);
set('tenant_b_code', 'C-B' + stamp);
```

So repeated runs never collide on the unique `institution_code`. The **Cleanup**
folder then archives them, keeping `GET /tenants?status=ACTIVE` meaningful.

What it does **not** do is delete them — an archived college keeps its schema,
because a college that has served requests holds accreditation records. Schemas
therefore accumulate across runs.

Check what has piled up:

```bash
mix aims.tenants.status
```

To reclaim them, **stop the server first**:

```bash
# Ctrl-C twice in the mix phx.server terminal, then
mix ecto.drop && mix ecto.create && mix ecto.migrate
```

`mix ecto.drop` refuses while anything holds a connection, and because the
commands are chained with `&&` the whole reset silently does nothing:

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

## 8. Reading the responses

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
| `409` | Lifecycle conflict — not discardable, schema collision |
| `422` | Validation failure |
| `500` | Provisioning failed |

---

## 9. Tenant-scoped requests need a header

Anything under `/api/v1/departments` or `/api/v1/tenant` must say which college
it is for:

```
x-tenant: C-41207
```

A subdomain works too (`abc.aims.example.com`), and takes priority. Tenant
*management* endpoints (`/api/v1/tenants`) deliberately do **not** take the
header — provisioning a college cannot require that college to already be
resolvable.

> ⚠️ In Milestone 1 the header is **unauthenticated**: any caller can name any
> college. That is fine for provisioning and isolation testing, and not fine in
> production. The authenticated strategy is already first in the resolver's
> priority order and takes over when auth lands.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `ECONNREFUSED` | Server not running | `mix phx.server` |
| `404` on `/api/v1/tenants/` with empty id | Ran a single request instead of the collection | Run the whole collection, or the Tenant Management folder first |
| `422 has already been taken` on Create Tenant | Ran with a stale `run_stamp` | Start the run from **Health**, which mints fresh codes |
| `400 tenant_not_specified` | Missing `x-tenant` on a tenant-scoped request | Add the header |
| `expected 'tenant_not_found' to deeply equal 'not_found'` | Ran a dependent folder alone, so `{{tenant_a_code}}` is empty | Include Platform + Tenant Management + Academic Structure |
| `403 tenant_inactive` | The college is SUSPENDED or ARCHIVED | `POST /api/v1/tenants/:id/activate` |
| Assertions fail after an interrupted run | A college left SUSPENDED by the 403 test | Reactivate it, or reset the database |
| Dozens of leftover `tenant_*` schemas | Normal — archived colleges keep their data | Stop the server, then `mix ecto.drop && mix ecto.create && mix ecto.migrate` |
| `ERROR 55006 object_in_use` on `mix ecto.drop` | Server, IEx or psql still connected | Stop them all. The `&&` chain means the reset then does nothing at all — check for `0` in `pg_stat_activity` before retrying |

---

## 11. When you add an endpoint

Every implemented API needs a corresponding request. The convention here:

1. Put it in the folder matching its bounded context.
2. Add a **happy path** and at least one **failure case**.
3. If it is tenant-scoped, add a **cross-tenant refusal** to *Tenant Isolation*.
4. Capture any new id into a collection variable with `pm.collectionVariables.set`
   **and** `pm.environment.set` — both, for the scoping reason in §6.
5. Re-run the whole collection twice, to confirm it is still re-runnable.

Keep assertions specific. `pm.response.to.have.status(201)` alone says almost
nothing; assert the fields that prove the behaviour — that the college came back
`ACTIVE` rather than merely registered, that the timestamp carries `+05:30`,
that tenant A's list does not contain tenant B's department.
