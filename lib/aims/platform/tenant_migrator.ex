defmodule Aims.Platform.TenantMigrator do
  @moduledoc """
  Creates tenant schemas and keeps them at the current tenant migration version.

  ## Two independent migration lines

      priv/repo/migrations         -> public schema. `mix ecto.migrate`.
      priv/repo/tenant_migrations  -> every tenant schema. `mix aims.tenants.migrate`.

  They are versioned separately because they change for different reasons: the
  public line changes when the platform changes, the tenant line when the AIMS
  domain changes.

  ## How a tenant's version is tracked

  Ecto writes a `schema_migrations` table *inside each tenant schema*. That is
  the authority — it is what the migrator reads to decide what is pending, and
  it cannot drift from reality because the migrator maintains it transactionally
  alongside the DDL.

  `public.tenant_schema_versions` is a projection of those tables, refreshed
  after every run, so the rollout orchestrator can find lagging tenants with one
  query instead of opening every schema. It never decides whether a migration
  runs.

  ## Rollout

  `migrate_all/1` walks tenants one at a time. Each tenant is independent: one
  failing does not abort the rest, and the run is resumable because a tenant
  already at the current version is a no-op. This is the "background job,
  tenant by tenant, resumable" the architecture calls for in §7.
  """

  require Logger

  import Ecto.Query

  alias Aims.Platform.{SchemaName, Tenant}
  alias Aims.Repo
  alias Ecto.Adapters.SQL

  @default_migrations_path "priv/repo/tenant_migrations"

  @doc """
  Absolute path to the tenant migration directory.

  Overridable via `config :aims, :tenant_migrations_path` so tests can point the
  migrator at a deliberately broken path and exercise the failure branch.
  """
  @spec migrations_path() :: String.t()
  def migrations_path do
    configured = Application.get_env(:aims, :tenant_migrations_path, @default_migrations_path)

    case Path.type(configured) do
      :absolute -> configured
      _ -> Application.app_dir(:aims, configured)
    end
    |> normalise_separators()
  end

  # `Path.wildcard/1` treats a backslash as a glob escape, so a Windows-style
  # path silently matches nothing and the migrator reports "no migrations to
  # run" instead of failing. Normalising to forward slashes — which Windows
  # accepts everywhere — keeps discovery working on every platform.
  defp normalise_separators(path), do: String.replace(path, "\\", "/")

  @doc """
  Creates the tenant's PostgreSQL schema.

  Idempotent, so a retried provisioning run does not fail on an already-created
  schema. The identifier passes through `SchemaName.safe!/1` because it is
  interpolated into DDL, where no parameter binding is possible.
  """
  @spec create_schema(String.t()) :: :ok
  def create_schema(schema_name) do
    safe = SchemaName.safe!(schema_name)
    SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{safe}"), [])
    :ok
  end

  @doc """
  Drops the tenant's schema and everything in it.

  Destructive, and used only to roll back a failed provisioning attempt. It is
  never reachable from the API surface: a tenant that has ever been ACTIVE is
  archived, not dropped, because its data is an accreditation record.
  """
  @spec drop_schema(String.t()) :: :ok
  def drop_schema(schema_name) do
    safe = SchemaName.safe!(schema_name)
    SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "#{safe}" CASCADE), [])
    :ok
  end

  @doc "Whether the schema exists in this database."
  @spec schema_exists?(String.t()) :: boolean()
  def schema_exists?(schema_name) do
    safe = SchemaName.safe!(schema_name)

    %{rows: [[exists]]} =
      SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
        [safe]
      )

    exists
  end

  @doc "Every version defined in the tenant migration directory, ascending."
  @spec available_versions() :: [integer()]
  def available_versions do
    migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))
    |> Enum.sort()
  end

  @doc "The newest tenant migration version, or `nil` when none are defined."
  @spec latest_version() :: integer() | nil
  def latest_version, do: List.last(available_versions())

  @doc "Versions already applied inside `schema_name`."
  @spec applied_versions(String.t()) :: [integer()]
  def applied_versions(schema_name) do
    # Deliberately outside the rescue below: an unsafe identifier is a bug that
    # must surface, not a "nothing applied yet" condition.
    safe = SchemaName.safe!(schema_name)

    if schema_exists?(safe) do
      try do
        Ecto.Migrator.migrated_versions(Repo, prefix: safe, dynamic_repo: Repo)
      rescue
        # The schema exists but has no schema_migrations table yet.
        _ -> []
      end
    else
      []
    end
  end

  @doc "Versions defined but not yet applied to `schema_name`."
  @spec pending_versions(String.t()) :: [integer()]
  def pending_versions(schema_name) do
    available_versions() -- applied_versions(schema_name)
  end

  @doc """
  Brings one tenant schema up to the latest tenant migration.

  Creates the schema first if it does not exist, so this is the single entry
  point for both provisioning a new tenant and upgrading an existing one.
  """
  @spec migrate(Tenant.t(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def migrate(%Tenant{} = tenant, opts \\ []) do
    schema = SchemaName.safe!(tenant.schema_name)

    try do
      create_schema(schema)

      applied =
        Ecto.Migrator.run(
          Repo,
          migrations_path(),
          :up,
          Keyword.merge([all: true, prefix: schema, log: :debug, log_migrations_sql: false], opts)
        )

      record_versions(tenant, schema)
      {:ok, applied}
    rescue
      error ->
        Logger.error(
          "tenant migration failed for #{tenant.code} (#{schema}): #{Exception.message(error)}"
        )

        {:error, error}
    end
  end

  @doc """
  Rolls the latest tenant migrations out to every tenant.

  Each tenant is attempted independently, so one bad schema does not strand the
  rest, and the summary names exactly which tenants failed. Re-running is safe:
  tenants already current are no-ops.

  Pass `statuses: [...]` to widen the default, which deliberately skips
  ARCHIVED and PROVISION_FAILED tenants.
  """
  @spec migrate_all(keyword()) :: %{ok: [String.t()], failed: [{String.t(), term()}]}
  def migrate_all(opts \\ []) do
    statuses = Keyword.get(opts, :statuses, ["ACTIVE", "SUSPENDED", "PROVISIONING"])

    tenants =
      Repo.all(from t in Tenant, where: t.status in ^statuses, order_by: [asc: t.id])

    Logger.info("rolling tenant migrations out to #{length(tenants)} tenant(s)")

    Enum.reduce(tenants, %{ok: [], failed: []}, fn tenant, acc ->
      case migrate(tenant, Keyword.take(opts, [:log])) do
        {:ok, _applied} -> %{acc | ok: acc.ok ++ [tenant.code]}
        {:error, reason} -> %{acc | failed: acc.failed ++ [{tenant.code, reason}]}
      end
    end)
  end

  @doc "Tenants whose schema is behind the latest tenant migration."
  @spec lagging_tenants() :: [Tenant.t()]
  def lagging_tenants do
    case latest_version() do
      nil ->
        []

      latest ->
        Repo.all(
          from t in Tenant,
            where: t.status in ["ACTIVE", "SUSPENDED", "PROVISIONING"],
            where:
              fragment(
                "NOT EXISTS (SELECT 1 FROM tenant_schema_versions v WHERE v.tenant_id = ? AND v.version = ?)",
                t.id,
                ^latest
              ),
            order_by: [asc: t.id]
        )
    end
  end

  # Refresh the public projection from the tenant's own schema_migrations table.
  defp record_versions(%Tenant{id: tenant_id}, schema) do
    versions = Ecto.Migrator.migrated_versions(Repo, prefix: schema, dynamic_repo: Repo)
    now = DateTime.utc_now()

    entries =
      Enum.map(versions, fn version ->
        %{tenant_id: tenant_id, version: version, applied_at: now}
      end)

    if entries != [] do
      Repo.insert_all("tenant_schema_versions", entries,
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :version]
      )
    end

    :ok
  end
end
