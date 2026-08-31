defmodule Aims.Repo.Migrations.CreateTenantMigrationVersions do
  use Ecto.Migration

  @moduledoc """
  `public.tenant_migration_versions` — which tenant migration each college's
  schema has received.

  Renamed from `tenant_schema_versions`, and the column from `version` to
  `migration_version`: the table tracks applied *migrations*, not versions of
  the schema as an artefact, and the old name suggested the latter.

  ## Authority

  Ecto maintains a `schema_migrations` table **inside each tenant schema**, and
  Triplex reads it to decide what is pending. That is the source of truth.

  This table is a projection refreshed after every run, so the rollout
  orchestrator can answer "which colleges are behind?" with one query against
  `public` instead of opening N schemas. It never decides whether a migration
  runs.
  """

  def up do
    create table(:tenant_migration_versions, primary_key: false) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), primary_key: true, null: false
      add :migration_version, :bigint, primary_key: true, null: false
      add :applied_at, :timestamptz, null: false, default: fragment("now()")
    end

    create index(:tenant_migration_versions, [:migration_version])
  end

  def down do
    drop table(:tenant_migration_versions)
  end
end
