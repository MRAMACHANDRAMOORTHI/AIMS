defmodule Aims.Repo.Migrations.CreateTenantSchemaVersions do
  use Ecto.Migration

  @moduledoc """
  `public.tenant_schema_versions` — platform-level index of which tenant schema
  has received which tenant migration.

  Note on authority. Ecto maintains a `schema_migrations` table *inside* each
  tenant schema, and that is the source of truth the migrator itself reads and
  writes. This table is a denormalised projection maintained by
  `Aims.Platform.TenantMigrator` so that the rollout orchestrator can answer
  "which tenants are behind?" with one query against `public`, instead of
  opening N schemas. It is never used to decide whether a migration runs.
  """

  def up do
    create table(:tenant_schema_versions, primary_key: false) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), primary_key: true, null: false
      add :version, :bigint, primary_key: true, null: false
      add :applied_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:tenant_schema_versions, [:version])
  end

  def down do
    drop table(:tenant_schema_versions)
  end
end
