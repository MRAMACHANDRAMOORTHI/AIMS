defmodule Aims.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  @moduledoc """
  `public.tenants` — the platform registry of onboarded colleges.

  ## Column naming

  A row in this table *is* an institution, but the table name says "tenant", so
  the institution-describing columns carry an explicit `institution_` prefix.
  Elsewhere — `departments.code`, `departments.name` — the table name already
  conveys the entity and bare column names are used. That is the naming rule
  applied throughout this schema.

  ## Two flags drive the whole application

    * `institution_type` decides which FIELDS apply (OBE / CO-PO for engineering)
    * `autonomy_status`  decides which MARKS apply (100 affiliated / 150 autonomous)

  Both are resolved once per request into a `TenantProfile`; nothing downstream
  branches on the raw values.

  ## `tenant_slug`, not `schema_name`

  The slug is the Triplex tenant identifier. The PostgreSQL schema is derived
  from it as `Triplex.to_prefix(slug)` — `"c_41207"` becomes `"tenant_c_41207"`.
  Storing only the slug keeps one source of truth: the prefix belongs to Triplex
  configuration, not to a duplicated column that could drift out of step with it.
  """

  def up do
    create table(:tenants) do
      # AISHE / NAAC track code. Also the tenant resolution key.
      add :institution_code, :string, size: 50, null: false
      add :institution_name, :string, size: 255, null: false
      add :institution_type, :string, size: 20, null: false
      add :autonomy_status, :string, size: 20, null: false
      add :affiliating_university, :string, size: 255

      # Triplex tenant identifier; schema = "tenant_" <> tenant_slug.
      add :tenant_slug, :string, size: 55, null: false

      add :lifecycle_status, :string, size: 20, null: false, default: "PROVISIONING"

      # IANA zone used to render this college's timestamps in API responses.
      # Storage is always UTC; this only affects presentation.
      add :time_zone, :string, size: 50, null: false, default: "Asia/Kolkata"

      timestamps(type: :timestamptz)
    end

    create unique_index(:tenants, [:institution_code])
    create unique_index(:tenants, [:tenant_slug])
    create index(:tenants, [:lifecycle_status])

    create constraint(:tenants, :tenants_institution_type_valid,
             check: "institution_type IN ('ENGINEERING','ARTS_SCIENCE')"
           )

    create constraint(:tenants, :tenants_autonomy_status_valid,
             check: "autonomy_status IN ('AFFILIATED','AUTONOMOUS')"
           )

    create constraint(:tenants, :tenants_lifecycle_status_valid,
             check:
               "lifecycle_status IN ('PROVISIONING','ACTIVE','SUSPENDED','ARCHIVED','PROVISION_FAILED')"
           )

    # Invariant I-10: an affiliated college must name its parent university,
    # because it reports BoS and syllabus compliance against it.
    create constraint(:tenants, :tenants_affiliation_required,
             check:
               "autonomy_status <> 'AFFILIATED' OR (affiliating_university IS NOT NULL AND length(btrim(affiliating_university)) > 0)"
           )

    # Defence in depth for Aims.Platform.TenantSlug. The slug reaches PostgreSQL
    # inside `CREATE SCHEMA`, where no parameter binding is possible, so the
    # database refuses to store anything that would be unsafe to interpolate.
    create constraint(:tenants, :tenants_slug_format, check: "tenant_slug ~ '^[a-z0-9_]{1,55}$'")
  end

  def down do
    drop table(:tenants)
  end
end
