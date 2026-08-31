"""Generates the two Postman collections from one definition.

Kept in the repo under postman/ so the collections stay reproducible: editing
JSON by hand across two files drifts, editing this does not.
"""
import json, io, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)))


def url(path, query=None):
    raw = "{{base_url}}" + path
    u = {"raw": raw + ("?" + "&".join(f"{k}={v}" for k, v in query) if query else ""),
         "host": ["{{base_url}}"],
         "path": [p for p in path.strip("/").split("/")]}
    if query:
        u["query"] = [{"key": k, "value": v} for k, v in query]
    return u


def req(name, method, path, body=None, tenant=None, query=None, desc=None,
        tests=None, prerequest=None):
    headers = [{"key": "Accept", "value": "application/json"}]
    if body is not None:
        headers.insert(0, {"key": "Content-Type", "value": "application/json"})
    if tenant:
        headers.append({"key": "x-tenant", "value": tenant})

    r = {"method": method, "header": headers, "url": url(path, query)}
    if body is not None:
        r["body"] = {"mode": "raw", "raw": json.dumps(body, indent=2)}
    if desc:
        r["description"] = desc

    item = {"name": name, "request": r, "event": []}
    if prerequest:
        item["event"].append({"listen": "prerequest",
                              "script": {"type": "text/javascript", "exec": prerequest}})
    if tests:
        item["event"].append({"listen": "test",
                              "script": {"type": "text/javascript", "exec": tests}})
    return item


def folder(name, desc, items):
    return {"name": name, "description": desc, "item": items}


def collection(cid, name, desc, variables, prerequest, folders):
    return {
        "info": {"_postman_id": cid, "name": name, "description": desc,
                 "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
        "variable": [{"key": k, "value": v, "type": "string"} for k, v in variables],
        "auth": {"type": "bearer",
                 "bearer": [{"key": "token", "value": "{{token}}", "type": "string"}]},
        "event": [{"listen": "prerequest",
                   "script": {"type": "text/javascript", "exec": prerequest}}],
        "item": folders,
    }


def stamp_script(first_request, a_code, b_code, a_id, b_id, extra_clear=()):
    """Mints fresh college codes once per run, so the collection is re-runnable."""
    lines = [
        "// Mint a fresh pair of college codes at the start of every run, so the",
        "// collection can be re-run against the same database without colliding",
        "// on the unique institution_code. '%s' is the first request and" % first_request,
        "// therefore marks the start of a run.",
        "if (pm.info.requestName === '%s' || !pm.collectionVariables.get('run_stamp')) {" % first_request,
        "  const stamp = String(Date.now()).slice(-7);",
        "  const set = (k, v) => { pm.collectionVariables.set(k, v); pm.environment.set(k, v); };",
        "  set('run_stamp', stamp);",
        "  set('%s', 'C-A' + stamp);" % a_code,
        "  set('%s', 'C-B' + stamp);" % b_code,
        "  set('%s', '');" % a_id,
        "  set('%s', '');" % b_id,
    ]
    for v in extra_clear:
        lines.append("  set('%s', '');" % v)
    lines += [
        "}",
        "",
        "// Authentication is not implemented in Milestone 1. The bearer token is",
        "// wired up so neither collection needs restructuring once auth lands.",
    ]
    return lines


def setvar(key, expr):
    return [f"pm.collectionVariables.set('{key}', {expr});",
            f"pm.environment.set('{key}', {expr});"]


# ─────────────────────────────────────────────────────────────────────────────
# Collection 1 — AIMS Platform (tenant management)
# ─────────────────────────────────────────────────────────────────────────────

PLATFORM_DESC = (
    "**AIMS Platform — tenant management.**\n\n"
    "The platform layer only: onboarding a college as a tenant, its lifecycle, "
    "its PostgreSQL schema and migrations, and how a request resolves to one.\n\n"
    "Everything here operates on the `public` schema or on tenant *metadata*. "
    "No academic domain data appears — departments, programmes, courses and "
    "curricula live in the separate **AIMS ERP** collection.\n\n"
    "Run it top to bottom: requests capture ids into collection variables that "
    "later requests read. Fresh college codes are minted each run, so it is "
    "safe to re-run against the same database.\n\n"
    "Tenant resolution uses the `x-tenant` header carrying the college's "
    "institution code. In Milestone 1 that is **unauthenticated** — see the "
    "README."
)

plat_health = req(
    "Health", "GET", "/api/v1/health",
    desc="Liveness, the tenant-migration version line, any colleges lagging behind it, "
         "and the server clock in both UTC and local time.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('reports ok', () => pm.expect(d.status).to.eql('ok'));",
        "pm.test('exposes the tenant migration line', () => {",
        "  pm.expect(d).to.have.property('latest_tenant_migration');",
        "});",
        "pm.test('stores UTC, presents local — both reported', () => {",
        "  pm.expect(d.server_time_utc).to.match(/Z$/);",
        "  pm.expect(d.server_time_local).to.match(/\\+05:30$/);",
        "  pm.expect(d.default_time_zone).to.eql('Asia/Kolkata');",
        "});",
    ])

plat_patterns = req(
    "List Academic Term Patterns", "GET", "/api/v1/academic-term-patterns",
    desc="Term patterns are platform-wide reference data held in `public`, not copied "
         "into each tenant schema (architecture contradiction C-11). A college could "
         "otherwise redefine SEMESTER as three terms.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const patterns = pm.response.json().data;",
        "const codes = patterns.map(p => p.code);",
        "pm.test('seeds SEMESTER, TRIMESTER, ANNUAL', () => {",
        "  pm.expect(codes).to.include.members(['SEMESTER', 'TRIMESTER', 'ANNUAL']);",
        "});",
        "pm.test('SEMESTER is 2 terms per year', () => {",
        "  pm.expect(patterns.find(p => p.code === 'SEMESTER').terms_per_year).to.eql(2);",
        "});",
    ])

plat_create_a = req(
    "Onboard College A — Engineering / Autonomous", "POST", "/api/v1/tenants",
    body={"institution_code": "{{tenant_a_code}}",
          "institution_name": "ABC Institute of Technology",
          "institution_type": "ENGINEERING",
          "autonomy_status": "AUTONOMOUS",
          "time_zone": "Asia/Kolkata"},
    desc="Registers the college, creates its PostgreSQL schema through Triplex, runs "
         "every tenant migration and marks it ACTIVE — returning 201 only when all of "
         "that succeeded.\n\n"
         "`time_zone` is optional and defaults to Asia/Kolkata. It affects presentation "
         "only; storage is always UTC.",
    tests=[
        "pm.test('201 Created', () => pm.response.to.have.status(201));",
        "const d = pm.response.json().data;",
    ] + setvar("tenant_a_id", "d.id") + [
        "pm.test('ACTIVE, not merely registered', () => {",
        "  pm.expect(d.lifecycle_status).to.eql('ACTIVE');",
        "});",
        "pm.test('slug and schema derived from the institution code', () => {",
        "  const expected = pm.collectionVariables.get('tenant_a_code')",
        "    .toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');",
        "  pm.expect(d.tenant_slug).to.eql(expected);",
        "  pm.expect(d.schema_name).to.eql('tenant_' + expected);",
        "});",
        "pm.test('Location header points at the college', () => {",
        "  pm.expect(pm.response.headers.get('location')).to.eql('/api/v1/tenants/' + d.id);",
        "});",
        "pm.test('timestamps carry an explicit +05:30 offset', () => {",
        "  pm.expect(d.time_zone).to.eql('Asia/Kolkata');",
        "  pm.expect(d.inserted_at).to.match(/\\+05:30$/);",
        "  pm.expect(isNaN(Date.parse(d.inserted_at))).to.be.false;",
        "});",
    ])

plat_create_b = req(
    "Onboard College B — Arts & Science / Affiliated", "POST", "/api/v1/tenants",
    body={"institution_code": "{{tenant_b_code}}",
          "institution_name": "St Xavier College of Arts and Science",
          "institution_type": "ARTS_SCIENCE",
          "autonomy_status": "AFFILIATED",
          "affiliating_university": "University of Madras"},
    desc="An affiliated college must name its parent university — invariant I-10. It "
         "reports Board of Studies and syllabus compliance against it.",
    tests=[
        "pm.test('201 Created', () => pm.response.to.have.status(201));",
        "const d = pm.response.json().data;",
    ] + setvar("tenant_b_id", "d.id") + [
        "pm.test('ACTIVE', () => pm.expect(d.lifecycle_status).to.eql('ACTIVE'));",
        "pm.test('records the affiliating university', () => {",
        "  pm.expect(d.affiliating_university).to.eql('University of Madras');",
        "});",
        "pm.test('has its own schema, distinct from College A', () => {",
        "  pm.expect(d.schema_name).to.not.eql('tenant_' +",
        "    pm.collectionVariables.get('tenant_a_code').toLowerCase()",
        "      .replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''));",
        "});",
    ])

plat_get = req(
    "Get College", "GET", "/api/v1/tenants/{{tenant_a_id}}",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('is the college we asked for', () => {",
        "  pm.expect(pm.response.json().data.institution_code)",
        "    .to.eql(pm.collectionVariables.get('tenant_a_code'));",
        "});",
    ])

plat_list = req(
    "List Colleges", "GET", "/api/v1/tenants",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const codes = pm.response.json().data.map(t => t.institution_code);",
        "pm.test('includes both onboarded colleges', () => {",
        "  pm.expect(codes).to.include(pm.collectionVariables.get('tenant_a_code'));",
        "  pm.expect(codes).to.include(pm.collectionVariables.get('tenant_b_code'));",
        "});",
    ])

plat_list_filtered = req(
    "List Colleges — filtered by status", "GET", "/api/v1/tenants",
    query=[("status", "ACTIVE")],
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('every row is ACTIVE', () => {",
        "  pm.response.json().data.forEach(t => {",
        "    pm.expect(t.lifecycle_status).to.eql('ACTIVE');",
        "  });",
        "});",
    ])

plat_resolve_a = req(
    "Resolve College A — 150-mark engineering profile", "GET", "/api/v1/tenant",
    tenant="{{tenant_a_code}}",
    desc="Engineering + Autonomous resolves to a 150-mark scale with OBE and BoS "
         "revision enabled.\n\n"
         "This is the mechanism that keeps the four-way institution matrix out of the "
         "rest of the codebase: the two flags are resolved once, at the edge, and "
         "everything downstream reads a named feature flag.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('resolved the right college', () => {",
        "  pm.expect(d.institution_code).to.eql(pm.collectionVariables.get('tenant_a_code'));",
        "});",
        "pm.test('assessed out of 150', () => pm.expect(d.profile.criteria_scale).to.eql(150));",
        "pm.test('OBE enabled', () => pm.expect(d.profile.features.obe_mapping).to.be.true);",
        "pm.test('BoS revision enabled', () => {",
        "  pm.expect(d.profile.features.bos_curriculum_revision).to.be.true;",
        "});",
        "pm.test('faculty BoS participation off — it is the affiliated counterpart', () => {",
        "  pm.expect(d.profile.features.faculty_bos_participation).to.be.false;",
        "});",
        "pm.test('experiential variant is industry', () => {",
        "  pm.expect(d.profile.experiential_variant).to.eql('industry');",
        "});",
        "pm.test('echoes the resolved college in a response header', () => {",
        "  pm.expect(pm.response.headers.get('x-resolved-tenant'))",
        "    .to.eql(pm.collectionVariables.get('tenant_a_code'));",
        "});",
    ])

plat_resolve_b = req(
    "Resolve College B — 100-mark arts & science profile", "GET", "/api/v1/tenant",
    tenant="{{tenant_b_code}}",
    desc="The same endpoint, a different college, a different profile. Arts & Science + "
         "Affiliated resolves to a 100-mark scale, OBE off, and faculty BoS "
         "participation on in place of BoS revision.\n\n"
         "Also the resolution-level isolation check: switching the header switches the "
         "schema every subsequent query will use.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('assessed out of 100', () => pm.expect(d.profile.criteria_scale).to.eql(100));",
        "pm.test('OBE disabled', () => pm.expect(d.profile.features.obe_mapping).to.be.false);",
        "pm.test('BoS revision disabled — it does not design its own syllabus', () => {",
        "  pm.expect(d.profile.features.bos_curriculum_revision).to.be.false;",
        "});",
        "pm.test('faculty BoS participation on instead', () => {",
        "  pm.expect(d.profile.features.faculty_bos_participation).to.be.true;",
        "});",
        "pm.test('experiential variant is field', () => {",
        "  pm.expect(d.profile.experiential_variant).to.eql('field');",
        "});",
        "pm.test('resolves to a different schema than College A', () => {",
        "  const a = pm.collectionVariables.get('tenant_a_code').toLowerCase()",
        "    .replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');",
        "  pm.expect(d.schema_name).to.not.eql('tenant_' + a);",
        "});",
    ])

plat_update = req(
    "Update College — rename and change zone", "PATCH", "/api/v1/tenants/{{tenant_a_id}}",
    body={"institution_name": "ABC Institute of Technology (Autonomous)",
          "time_zone": "Asia/Kolkata"},
    desc="Only `institution_name`, `affiliating_university` and `time_zone` are editable.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('renamed', () => {",
        "  pm.expect(pm.response.json().data.institution_name)",
        "    .to.eql('ABC Institute of Technology (Autonomous)');",
        "});",
    ])

plat_update_immutable = req(
    "Update College — immutable fields are ignored", "PATCH",
    "/api/v1/tenants/{{tenant_a_id}}",
    body={"institution_name": "ABC Institute of Technology (Autonomous)",
          "institution_type": "ARTS_SCIENCE",
          "autonomy_status": "AFFILIATED",
          "institution_code": "C-HIJACK",
          "tenant_slug": "public"},
    desc="Mass-assignment guard.\n\n"
         "`institution_code` and `tenant_slug` are physical identity. "
         "`institution_type` and `autonomy_status` are invariant I-40: changing them "
         "would silently invalidate every frozen report assessed on the old mark scale. "
         "All four are dropped rather than applied.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('institution_type unchanged', () => {",
        "  pm.expect(d.institution_type).to.eql('ENGINEERING');",
        "});",
        "pm.test('autonomy_status unchanged', () => {",
        "  pm.expect(d.autonomy_status).to.eql('AUTONOMOUS');",
        "});",
        "pm.test('institution_code unchanged', () => {",
        "  pm.expect(d.institution_code).to.eql(pm.collectionVariables.get('tenant_a_code'));",
        "});",
        "pm.test('tenant_slug unchanged — the schema cannot be hijacked', () => {",
        "  pm.expect(d.tenant_slug).to.not.eql('public');",
        "});",
    ])

plat_schema = req(
    "Schema Status", "GET", "/api/v1/tenants/{{tenant_a_id}}/schema",
    desc="Whether the college's PostgreSQL schema exists, which tenant migrations it "
         "carries and which are pending.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('schema exists', () => pm.expect(d.schema_exists).to.be.true);",
        "pm.test('no pending migrations', () => pm.expect(d.pending_versions).to.eql([]));",
        "pm.test('reported up to date', () => pm.expect(d.up_to_date).to.be.true);",
    ])

plat_migrate_one = req(
    "Migrate One College", "POST", "/api/v1/tenants/{{tenant_a_id}}/migrations",
    desc="Applies pending tenant migrations to one college. Safe to repeat — a college "
         "already at the current version is a no-op, which is what makes an interrupted "
         "rollout resumable.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('up to date afterwards', () => {",
        "  pm.expect(pm.response.json().data.up_to_date).to.be.true;",
        "});",
    ])

plat_migrate_all = req(
    "Migrate All Colleges", "POST", "/api/v1/tenants/migrations",
    desc="Rolls pending tenant migrations out to every serving college, one at a time. "
         "Each is independent: one failing does not strand the rest, and the response "
         "names exactly which failed.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "const d = pm.response.json().data;",
        "pm.test('nothing failed', () => pm.expect(d.failed_count).to.eql(0));",
        "pm.test('both colleges reported', () => {",
        "  pm.expect(d.migrated).to.include(pm.collectionVariables.get('tenant_a_code'));",
        "  pm.expect(d.migrated).to.include(pm.collectionVariables.get('tenant_b_code'));",
        "});",
    ])

plat_suspend = req(
    "Suspend College", "POST", "/api/v1/tenants/{{tenant_b_id}}/suspend",
    desc="A suspended college keeps all its data and simply stops serving requests.",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('now SUSPENDED', () => {",
        "  pm.expect(pm.response.json().data.lifecycle_status).to.eql('SUSPENDED');",
        "});",
    ])

plat_suspended_403 = req(
    "Suspended college cannot serve requests (403)", "GET", "/api/v1/tenant",
    tenant="{{tenant_b_code}}",
    desc="Distinguishes an inactive college (403) from an unknown one (404). Collapsing "
         "the two would make a typo indistinguishable from a suspension.",
    tests=[
        "pm.test('403 Forbidden', () => pm.response.to.have.status(403));",
        "const e = pm.response.json().errors;",
        "pm.test('reports tenant_inactive', () => pm.expect(e.code).to.eql('tenant_inactive'));",
        "pm.test('names the actual status', () => pm.expect(e.detail).to.include('SUSPENDED'));",
    ])

plat_activate = req(
    "Activate College", "POST", "/api/v1/tenants/{{tenant_b_id}}/activate",
    tests=[
        "pm.test('200 OK', () => pm.response.to.have.status(200));",
        "pm.test('back to ACTIVE', () => {",
        "  pm.expect(pm.response.json().data.lifecycle_status).to.eql('ACTIVE');",
        "});",
    ])

plat_delete_409 = req(
    "Delete refuses a college that has served requests (409)", "DELETE",
    "/api/v1/tenants/{{tenant_a_id}}",
    desc="Only a PROVISION_FAILED college can be discarded. One that has ever been "
         "ACTIVE holds accreditation records, and its terminal state is ARCHIVED "
         "(invariant I-19).",
    tests=[
        "pm.test('409 Conflict', () => pm.response.to.have.status(409));",
        "pm.test('reports not_discardable', () => {",
        "  pm.expect(pm.response.json().errors.code).to.eql('not_discardable');",
        "});",
    ])

plat_retry_500 = req(
    "Retry refuses a healthy college (500)", "POST",
    "/api/v1/tenants/{{tenant_a_id}}/retry",
    desc="Retry exists to repair a failed provision, not to rebuild a live college's "
         "schema.",
    tests=[
        "pm.test('500 with an explicit reason', () => pm.response.to.have.status(500));",
        "pm.test('reports provisioning_failed', () => {",
        "  pm.expect(pm.response.json().errors.code).to.eql('provisioning_failed');",
        "});",
    ])

plat_res_none = req(
    "No tenant specified (400)", "GET", "/api/v1/tenant",
    desc="Tenant-scoped endpoints must say which college they are for.",
    tests=[
        "pm.test('400 Bad Request', () => pm.response.to.have.status(400));",
        "const e = pm.response.json().errors;",
        "pm.test('reports tenant_not_specified', () => {",
        "  pm.expect(e.code).to.eql('tenant_not_specified');",
        "});",
        "pm.test('tells the caller how to fix it', () => {",
        "  pm.expect(e.detail).to.include('x-tenant');",
        "});",
    ])

plat_res_unknown = req(
    "Unknown college (404)", "GET", "/api/v1/tenant", tenant="C-DOES-NOT-EXIST",
    tests=[
        "pm.test('404 Not Found', () => pm.response.to.have.status(404));",
        "pm.test('reports tenant_not_found', () => {",
        "  pm.expect(pm.response.json().errors.code).to.eql('tenant_not_found');",
        "});",
    ])

plat_res_injection = req(
    "SQL in the tenant header is a lookup miss, never a query (404)", "GET",
    "/api/v1/tenant", tenant="'; DROP TABLE tenants; --",
    desc="The institution code is a bound parameter, and the schema identifier is "
         "derived server-side from a validated grammar — `[a-z0-9_]{1,55}`, enforced in "
         "the module, in a changeset and again by a database CHECK. Injection cannot "
         "reach DDL.",
    tests=[
        "pm.test('404 Not Found', () => pm.response.to.have.status(404));",
        "pm.test('reports tenant_not_found', () => {",
        "  pm.expect(pm.response.json().errors.code).to.eql('tenant_not_found');",
        "});",
    ])

plat_res_intact = req(
    "The registry survived the injection attempt", "GET", "/api/v1/tenants",
    desc="Runs straight after the injection attempt. If `DROP TABLE tenants` had "
         "landed, this would not return a list.",
    tests=[
        "pm.test('200 OK — tenants table is intact', () => pm.response.to.have.status(200));",
        "pm.test('still lists the onboarded colleges', () => {",
        "  const codes = pm.response.json().data.map(t => t.institution_code);",
        "  pm.expect(codes).to.include(pm.collectionVariables.get('tenant_a_code'));",
        "});",
    ])


def fail(name, body, checks, desc=None, method="POST", path="/api/v1/tenants"):
    return req(name, method, path, body=body, desc=desc,
               tests=["pm.test('422 Unprocessable Entity', () => pm.response.to.have.status(422));",
                      "const e = pm.response.json().errors;"] + checks)


plat_failures = [
    fail("Missing required fields (422)", {},
         ["pm.test('errors are keyed by field', () => {",
          "  pm.expect(e.institution_code).to.eql([\"can't be blank\"]);",
          "  pm.expect(e.institution_name).to.eql([\"can't be blank\"]);",
          "  pm.expect(e.institution_type).to.eql([\"can't be blank\"]);",
          "  pm.expect(e.autonomy_status).to.eql([\"can't be blank\"]);",
          "});",
          "pm.test('a validation payload carries no detail key', () => {",
          "  pm.expect(e).to.not.have.property('detail');",
          "});"]),
    fail("Affiliated without a university (422)",
         {"institution_code": "C-BADAFF", "institution_name": "Incomplete Affiliated College",
          "institution_type": "ARTS_SCIENCE", "autonomy_status": "AFFILIATED"},
         ["pm.test('names the affiliating university', () => {",
          "  pm.expect(e).to.have.property('affiliating_university');",
          "});"],
         desc="Invariant I-10, enforced in the changeset and again by a database CHECK."),
    fail("Unsupported institution type (422)",
         {"institution_code": "C-COMBI", "institution_name": "Combined University",
          "institution_type": "COMBINED", "autonomy_status": "AUTONOMOUS"},
         ["pm.test('institution_type is invalid', () => {",
          "  pm.expect(e.institution_type).to.eql(['is invalid']);",
          "});"],
         desc="COMBINED was explicitly ruled out by decision D-02: a tenant is one "
              "atomic college, never a multi-domain university."),
    fail("Duplicate institution code (422)",
         {"institution_code": "{{tenant_a_code}}", "institution_name": "Duplicate College",
          "institution_type": "ENGINEERING", "autonomy_status": "AUTONOMOUS"},
         ["pm.test('code already taken', () => {",
          "  pm.expect(e.institution_code).to.eql(['has already been taken']);",
          "});"]),
    fail("Institution code yields no usable slug (422)",
         {"institution_code": "!!!!", "institution_name": "Unnameable College",
          "institution_type": "ENGINEERING", "autonomy_status": "AUTONOMOUS"},
         ["pm.test('the institution code is rejected', () => {",
          "  pm.expect(e).to.have.property('institution_code');",
          "});"],
         desc="Nothing survives normalisation, so no PostgreSQL schema identifier can "
              "be derived. Rejected rather than silently given a degenerate name."),
    fail("Unrecognised time zone (422)",
         {"institution_code": "C-BADTZ", "institution_name": "Bad Zone College",
          "institution_type": "ENGINEERING", "autonomy_status": "AUTONOMOUS",
          "time_zone": "Mars/Olympus_Mons"},
         ["pm.test('names the time_zone field', () => {",
          "  pm.expect(e).to.have.property('time_zone');",
          "});"],
         desc="Validated against the IANA database on write, so an unusable zone is "
              "caught here rather than silently degrading every later response."),
    req("Unknown college id (404)", "GET", "/api/v1/tenants/999999",
        tests=["pm.test('404 Not Found', () => pm.response.to.have.status(404));",
               "pm.test('reports not_found', () => {",
               "  pm.expect(pm.response.json().errors.code).to.eql('not_found');",
               "});"]),
]


def archive(name, var):
    return req(name, "POST", f"/api/v1/tenants/{{{{{var}}}}}/archive",
               desc="Archives the college this run created, so repeated runs do not leave "
                    "ACTIVE test colleges behind. Archiving retains the schema and all "
                    "data — a college that has served requests holds accreditation "
                    "records and is never dropped (invariant I-19).",
               tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
                      "pm.test('now ARCHIVED', () => {",
                      "  pm.expect(pm.response.json().data.lifecycle_status).to.eql('ARCHIVED');",
                      "});",
                      "pm.test('schema is retained, not dropped', () => {",
                      "  pm.expect(pm.response.json().data.schema_name).to.be.a('string').and.not.empty;",
                      "});"])


platform = collection(
    "aims-platform-0001-4a00-9000-tenantmgmt", "AIMS Platform · Tenant Management",
    PLATFORM_DESC,
    [("base_url", "http://localhost:4000"), ("token", ""), ("run_stamp", ""),
     ("tenant_a_code", ""), ("tenant_b_code", ""), ("tenant_a_id", ""), ("tenant_b_id", "")],
    stamp_script("Health", "tenant_a_code", "tenant_b_code", "tenant_a_id", "tenant_b_id"),
    [
        folder("1 · Health & Reference",
               "Service liveness and the platform-wide reference data every college shares.",
               [plat_health, plat_patterns]),
        folder("2 · Onboarding",
               "Provisioning a college: registry row, PostgreSQL schema, tenant migrations, ACTIVE.",
               [plat_create_a, plat_create_b, plat_get, plat_list, plat_list_filtered]),
        folder("3 · Configuration & Profile",
               "The two flags that configure a college, and the capability profile they resolve to.",
               [plat_resolve_a, plat_resolve_b, plat_update, plat_update_immutable]),
        folder("4 · Schema & Migrations",
               "The tenant migration line, and rolling it out across colleges.",
               [plat_schema, plat_migrate_one, plat_migrate_all]),
        folder("5 · Lifecycle",
               "PROVISIONING → ACTIVE ⇄ SUSPENDED → ARCHIVED. There is no delete for a "
               "college that has served requests.",
               [plat_suspend, plat_suspended_403, plat_activate, plat_delete_409, plat_retry_500]),
        folder("6 · Tenant Resolution",
               "How a request finds its college, and how it fails when it cannot.",
               [plat_res_none, plat_res_unknown, plat_res_injection, plat_res_intact]),
        folder("7 · Validation Failures",
               "Every documented 4xx shape for onboarding.",
               plat_failures),
        folder("8 · Cleanup",
               "Archives the colleges this run created. Run last.",
               [archive("Archive College A", "tenant_a_id"),
                archive("Archive College B", "tenant_b_id")]),
    ])

# ─────────────────────────────────────────────────────────────────────────────
# Collection 2 — AIMS ERP (academic domain)
# ─────────────────────────────────────────────────────────────────────────────

ERP_DESC = (
    "**AIMS ERP — academic domain.**\n\n"
    "Everything inside a college's own PostgreSQL schema. Milestone 1 ships one "
    "table, `departments`, as the first slice of the Academic Structure context; "
    "programmes, courses, curricula and NAAC data follow in later milestones.\n\n"
    "Onboarding a college, its lifecycle and its migrations live in the separate "
    "**AIMS Platform** collection.\n\n"
    "This collection is self-contained: folder 0 provisions its own two colleges "
    "through the platform API, so it can be run on a fresh database without the "
    "platform collection having been run first.\n\n"
    "Every request outside folder 0 carries `x-tenant`, and operates only inside "
    "that college's schema."
)

erp_setup_a = req(
    "Onboard College A", "POST", "/api/v1/tenants",
    body={"institution_code": "{{erp_a_code}}",
          "institution_name": "ABC Institute of Technology",
          "institution_type": "ENGINEERING", "autonomy_status": "AUTONOMOUS"},
    desc="Setup only. Two colleges are needed before any domain data can exist, and a "
         "second one is needed before isolation means anything.",
    tests=["pm.test('201 Created', () => pm.response.to.have.status(201));",
           "const d = pm.response.json().data;"] + setvar("erp_a_id", "d.id") + [
        "pm.test('ACTIVE and ready for domain data', () => {",
        "  pm.expect(d.lifecycle_status).to.eql('ACTIVE');",
        "});"])

erp_setup_b = req(
    "Onboard College B", "POST", "/api/v1/tenants",
    body={"institution_code": "{{erp_b_code}}",
          "institution_name": "St Xavier College of Arts and Science",
          "institution_type": "ARTS_SCIENCE", "autonomy_status": "AFFILIATED",
          "affiliating_university": "University of Madras"},
    tests=["pm.test('201 Created', () => pm.response.to.have.status(201));",
           "const d = pm.response.json().data;"] + setvar("erp_b_id", "d.id") + [
        "pm.test('ACTIVE', () => pm.expect(d.lifecycle_status).to.eql('ACTIVE'));"])

erp_dept_a = req(
    "Create Department — College A", "POST", "/api/v1/departments",
    tenant="{{erp_a_code}}", body={"code": "cse", "name": "Department of Computer Science and Engineering"},
    desc="Created inside College A's schema. There is no `tenant_id` in the payload or "
         "the table — the schema boundary *is* the tenancy.",
    tests=["pm.test('201 Created', () => pm.response.to.have.status(201));",
           "const d = pm.response.json().data;"] + setvar("dept_a_id", "d.id") + [
        "pm.test('code is upcased so casing cannot create duplicates', () => {",
        "  pm.expect(d.code).to.eql('CSE');",
        "});",
        "pm.test('active by default', () => pm.expect(d.is_active).to.be.true);",
        "pm.test('timestamps render in the college time zone', () => {",
        "  pm.expect(d.inserted_at).to.match(/\\+05:30$/);",
        "});"])

erp_dept_b_same = req(
    "Create Department — College B, same code", "POST", "/api/v1/departments",
    tenant="{{erp_b_code}}", body={"code": "CSE", "name": "Department of Computer Science (B)"},
    desc="The same department code is free in a different college, because uniqueness is "
         "per schema. In a shared-table design with a `tenant_id` column this would need "
         "a compound unique constraint, and forgetting it is a classic leak.",
    tests=["pm.test('201 Created — the code is not globally unique', () => {",
           "  pm.response.to.have.status(201);",
           "});",
           "const d = pm.response.json().data;"] + setvar("dept_b_id", "d.id"))

erp_dept_b_only = req(
    "Create Department — College B only", "POST", "/api/v1/departments",
    tenant="{{erp_b_code}}", body={"code": "HIS", "name": "Department of History"},
    desc="Gives College B an id that does not exist in College A at all.\n\n"
         "Without this the isolation checks would be worthless: both colleges' first "
         "department is `id = 1`, because each schema has its own sequence, so a leak "
         "would still look like a successful fetch.",
    tests=["pm.test('201 Created', () => pm.response.to.have.status(201));",
           "const d = pm.response.json().data;"] + setvar("dept_b_only_id", "d.id"))

erp_list_a = req(
    "List Departments — College A", "GET", "/api/v1/departments", tenant="{{erp_a_code}}",
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "const codes = pm.response.json().data.map(d => d.code);",
           "pm.test('sees only its own department', () => pm.expect(codes).to.eql(['CSE']));",
           "pm.test('does not see College B HIS', () => pm.expect(codes).to.not.include('HIS'));"])

erp_list_b = req(
    "List Departments — College B", "GET", "/api/v1/departments", tenant="{{erp_b_code}}",
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "const codes = pm.response.json().data.map(d => d.code);",
           "pm.test('sees its own two departments', () => {",
           "  pm.expect(codes).to.have.members(['CSE', 'HIS']);",
           "});"])

erp_get = req(
    "Get Department", "GET", "/api/v1/departments/{{dept_a_id}}", tenant="{{erp_a_code}}",
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "pm.test('is College A CSE', () => {",
           "  pm.expect(pm.response.json().data.name)",
           "    .to.eql('Department of Computer Science and Engineering');",
           "});"])

erp_update = req(
    "Update Department", "PATCH", "/api/v1/departments/{{dept_a_id}}",
    tenant="{{erp_a_code}}", body={"name": "Department of Computer Science & Engineering"},
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "pm.test('renamed', () => {",
           "  pm.expect(pm.response.json().data.name)",
           "    .to.eql('Department of Computer Science & Engineering');",
           "});"])

erp_deactivate = req(
    "Deactivate Department", "POST", "/api/v1/departments/{{dept_b_id}}/deactivate",
    tenant="{{erp_b_code}}",
    desc="Soft-deactivates. Departments are never hard-deleted — they own programmes and "
         "courses that carry accreditation evidence (invariant I-19).",
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "pm.test('now inactive', () => {",
           "  pm.expect(pm.response.json().data.is_active).to.be.false;",
           "});"])

erp_list_active = req(
    "List Active Departments Only", "GET", "/api/v1/departments",
    tenant="{{erp_b_code}}", query=[("active", "true")],
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "const codes = pm.response.json().data.map(d => d.code);",
           "pm.test('the deactivated department is filtered out', () => {",
           "  pm.expect(codes).to.not.include('CSE');",
           "});"])

erp_iso_read = req(
    "College A cannot read a department that exists only in College B", "GET",
    "/api/v1/departments/{{dept_b_only_id}}", tenant="{{erp_a_code}}",
    desc="This id exists in College B's schema and not in College A's, so a leak would "
         "surface here as a successful fetch.",
    tests=["pm.test('404 Not Found', () => pm.response.to.have.status(404));",
           "pm.test('reports not_found', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql('not_found');",
           "});"])

erp_iso_own = req(
    "A colliding id resolves to the caller's own row", "GET",
    "/api/v1/departments/{{dept_a_id}}", tenant="{{erp_b_code}}",
    desc="Both colleges' first department shares an id, because each schema has its own "
         "sequence. Asserting only on found/not-found would pass even under a leak — the "
         "*contents* are what prove the boundary held.",
    tests=["pm.test('200 OK — College B has a row at this id too', () => {",
           "  pm.response.to.have.status(200);",
           "});",
           "pm.test(\"it is College B's row, not College A's\", () => {",
           "  pm.expect(pm.response.json().data.name).to.include('(B)');",
           "});"])

erp_iso_update = req(
    "College A cannot update a College B department", "PATCH",
    "/api/v1/departments/{{dept_b_only_id}}", tenant="{{erp_a_code}}",
    body={"name": "Hijacked"},
    tests=["pm.test('404 Not Found', () => pm.response.to.have.status(404));",
           "pm.test('reports not_found', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql('not_found');",
           "});"])

erp_iso_deactivate = req(
    "College A cannot deactivate a College B department", "POST",
    "/api/v1/departments/{{dept_b_only_id}}/deactivate", tenant="{{erp_a_code}}",
    tests=["pm.test('404 Not Found', () => pm.response.to.have.status(404));",
           "pm.test('reports not_found', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql('not_found');",
           "});"])

erp_iso_unaffected = req(
    "College B's data is unaffected by any of it", "GET", "/api/v1/departments",
    tenant="{{erp_b_code}}",
    desc="Runs after every cross-tenant attempt above. If any had succeeded, this list "
         "would show it.",
    tests=["pm.test('200 OK', () => pm.response.to.have.status(200));",
           "const names = pm.response.json().data.map(d => d.name);",
           "pm.test('nothing was hijacked', () => {",
           "  pm.expect(names).to.not.include('Hijacked');",
           "});",
           "pm.test('History is still active', () => {",
           "  const his = pm.response.json().data.find(d => d.code === 'HIS');",
           "  pm.expect(his.is_active).to.be.true;",
           "});"])

erp_no_tenant = req(
    "Tenant-scoped request with no tenant header (400)", "GET", "/api/v1/departments",
    tests=["pm.test('400 Bad Request', () => pm.response.to.have.status(400));",
           "pm.test('reports tenant_not_specified', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql('tenant_not_specified');",
           "});"])

erp_unknown_tenant = req(
    "Unknown college (404)", "GET", "/api/v1/departments", tenant="C-DOES-NOT-EXIST",
    tests=["pm.test('404 Not Found', () => pm.response.to.have.status(404));",
           "pm.test('reports tenant_not_found', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql('tenant_not_found');",
           "});"])

erp_fail_missing = req(
    "Create Department — missing fields (422)", "POST", "/api/v1/departments",
    tenant="{{erp_a_code}}", body={},
    tests=["pm.test('422 Unprocessable Entity', () => pm.response.to.have.status(422));",
           "const e = pm.response.json().errors;",
           "pm.test('errors are keyed by field', () => {",
           "  pm.expect(e.code).to.eql([\"can't be blank\"]);",
           "  pm.expect(e.name).to.eql([\"can't be blank\"]);",
           "});"])

erp_fail_code = req(
    "Create Department — invalid code (422)", "POST", "/api/v1/departments",
    tenant="{{erp_a_code}}", body={"code": "C S E!", "name": "Bad Code Department"},
    tests=["pm.test('422 Unprocessable Entity', () => pm.response.to.have.status(422));",
           "pm.test('the code is rejected', () => {",
           "  pm.expect(pm.response.json().errors).to.have.property('code');",
           "});"])

erp_fail_dupe = req(
    "Create Department — duplicate code in the same college (422)", "POST",
    "/api/v1/departments", tenant="{{erp_a_code}}",
    body={"code": "CSE", "name": "Duplicate Department"},
    tests=["pm.test('422 Unprocessable Entity', () => pm.response.to.have.status(422));",
           "pm.test('code already taken', () => {",
           "  pm.expect(pm.response.json().errors.code).to.eql(['has already been taken']);",
           "});"])

erp = collection(
    "aims-erp-0002-4b00-9000-academicdomain", "AIMS ERP · Academic Domain", ERP_DESC,
    [("base_url", "http://localhost:4000"), ("token", ""), ("run_stamp", ""),
     ("erp_a_code", ""), ("erp_b_code", ""), ("erp_a_id", ""), ("erp_b_id", ""),
     ("dept_a_id", ""), ("dept_b_id", ""), ("dept_b_only_id", "")],
    stamp_script("Onboard College A", "erp_a_code", "erp_b_code", "erp_a_id", "erp_b_id",
                 extra_clear=("dept_a_id", "dept_b_id", "dept_b_only_id")),
    [
        folder("0 · Setup",
               "Provisions the two colleges this collection needs, so it can run on a "
               "fresh database without the Platform collection. Uses the platform API.",
               [erp_setup_a, erp_setup_b]),
        folder("1 · Departments",
               "The first slice of the Academic Structure context. Programmes and the "
               "course catalogue follow in Milestone 3.",
               [erp_dept_a, erp_dept_b_same, erp_dept_b_only, erp_list_a, erp_list_b,
                erp_get, erp_update, erp_deactivate, erp_list_active]),
        folder("2 · Tenant Data Isolation",
               "The security proof at the data layer. Every cross-college attempt must "
               "be refused, and College B's data must be untouched afterwards.",
               [erp_iso_read, erp_iso_own, erp_iso_update, erp_iso_deactivate,
                erp_iso_unaffected, erp_no_tenant, erp_unknown_tenant]),
        folder("3 · Validation Failures",
               "Domain validation shapes.",
               [erp_fail_missing, erp_fail_code, erp_fail_dupe]),
        folder("4 · Cleanup",
               "Archives the colleges this run created. Run last.",
               [archive("Archive College A", "erp_a_id"),
                archive("Archive College B", "erp_b_id")]),
    ])


def write(obj, path):
    with io.open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    n = sum(len(fo["item"]) for fo in obj["item"])
    print(f"{path}: {len(obj['item'])} folders, {n} requests")


write(platform, os.path.join(OUT, "AIMS-Platform.postman_collection.json"))
write(erp, os.path.join(OUT, "AIMS-ERP.postman_collection.json"))
