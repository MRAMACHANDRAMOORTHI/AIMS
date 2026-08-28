defmodule Aims.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  @moduledoc """
  `public.tenants` — the platform registry of onboarded colleges.

  Follows the approved architecture (§16, public schema). Two flags on this row
  configure the entire behaviour of the tenant application:

    * `institution_type` decides which FIELDS apply (OBE / CO-PO for engineering)
    * `autonomy_status`  decides which MARKS apply (100 affiliated / 150 autonomous)

  Both are resolved once per request into a `TenantProfile`; nothing downstream
  branches on the raw values.
  """

  def up do
    create table(:tenants) do
      # AISHE / NAAC track code. Present in the source at p.18 and lost by p.23;
      # restored here because NAAC submissions are keyed by track code.
      add :code, :string, size: 50, null: false
      add :name, :string, size: 255, null: false
      add :schema_name, :string, size: 63, null: false

      add :institution_type, :string, size: 20, null: false
      add :autonomy_status, :string, size: 20, null: false
      add :affiliating_university, :string, size: 255

      add :status, :string, size: 20, null: false, default: "PROVISIONING"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:code])
    create unique_index(:tenants, [:schema_name])
    create index(:tenants, [:status])

    create constraint(:tenants, :tenants_institution_type_valid,
             check: "institution_type IN ('ENGINEERING','ARTS_SCIENCE')"
           )

    create constraint(:tenants, :tenants_autonomy_status_valid,
             check: "autonomy_status IN ('AFFILIATED','AUTONOMOUS')"
           )

    create constraint(:tenants, :tenants_status_valid,
             check:
               "status IN ('PROVISIONING','ACTIVE','SUSPENDED','ARCHIVED','PROVISION_FAILED')"
           )

    # Architecture §16 / invariant I-10: an affiliated college must name its
    # parent university, because it reports BoS and syllabus compliance against it.
    create constraint(:tenants, :tenants_affiliation_required,
             check:
               "autonomy_status <> 'AFFILIATED' OR (affiliating_university IS NOT NULL AND length(btrim(affiliating_university)) > 0)"
           )

    # Defence in depth for Aims.Platform.SchemaName. Even if application
    # validation were bypassed, the database refuses to store an identifier
    # that is unsafe to interpolate into DDL.
    create constraint(:tenants, :tenants_schema_name_format,
             check: "schema_name ~ '^tenant_[a-z0-9_]{1,55}$'"
           )
  end

  def down do
    drop table(:tenants)
  end
end
