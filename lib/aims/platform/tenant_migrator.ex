defmodule Aims.Platform.TenantMigrator do
  @moduledoc """
  Tenant schema lifecycle and the tenant migration line, on top of Triplex.

  ## What Triplex owns, what stays here

  Triplex handles the plumbing it is good at — `CREATE SCHEMA`, `DROP SCHEMA`,
  running `priv/repo/tenant_migrations` against a prefix, and the prefix itself.
  Its `create/2` is used in preference to a hand-rolled sequence because it
  wraps schema creation and migration in one transaction: if a migration fails,
  the half-built schema is rolled back rather than left as debris.

  What stays in this module is everything Triplex has no notion of:

    * the **grammar** for tenant identifiers (`Aims.Platform.TenantSlug`), since
      that is a security boundary and not a formatting convenience
    * the **rollout** across every college, with per-tenant failure isolation
    * the **projection** into `public.tenant_migration_versions`

  ## Two independent migration lines

      priv/repo/migrations         -> public schema.        mix ecto.migrate
      priv/repo/tenant_migrations  -> every tenant schema.  mix aims.tenants.migrate

  Separate because they change for different reasons: the public line when the
  platform changes, the tenant line when the AIMS domain changes.

  ## How a college's version is tracked

  Ecto writes `schema_migrations` **inside each tenant schema**, and that is the
  authority — it is what Triplex reads to decide what is pending.
  `public.tenant_migration_versions` is a projection refreshed after every run
  so the orchestrator can find lagging colleges with one query. It never decides
  whether a migration runs.
  """

  require Logger

  import Ecto.Query

  alias Aims.Platform.{Tenant, TenantSlug}
  alias Aims.Repo

  @doc "Absolute path to the tenant migration directory, as Triplex resolves it."
  @spec migrations_path() :: String.t()
  def migrations_path do
    case Application.get_env(:aims, :tenant_migrations_path) do
      nil -> Triplex.migrations_path(Repo)
      override -> resolve_override(override)
    end
    |> normalise_separators()
  end

  @doc """
  Creates the tenant's schema and runs every tenant migration into it.

  Delegates to `Triplex.create/2`, which does both inside one transaction.
  Idempotent at the migration level: a college already at the current version is
  a no-op, which is what makes an interrupted rollout resumable.
  """
  @spec create(Tenant.t()) :: {:ok, Tenant.t()} | {:error, term()}
  def create(%Tenant{} = tenant) do
    slug = TenantSlug.safe!(tenant.tenant_slug)

    case Triplex.create(slug, Repo) do
      {:ok, ^slug} ->
        record_versions(tenant)
        {:ok, tenant}

      {:error, reason} ->
        Logger.error(
          "tenant schema creation failed for #{tenant.institution_code} (#{slug}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Brings an existing tenant schema up to the latest migration.

  Creates the schema first if it is missing, so this is the single entry point
  for both repairing a college and upgrading one.
  """
  @spec migrate(Tenant.t()) :: {:ok, [integer()]} | {:error, term()}
  def migrate(%Tenant{} = tenant) do
    slug = TenantSlug.safe!(tenant.tenant_slug)

    try do
      unless schema_exists?(slug), do: Triplex.create_schema(slug, Repo)

      case Triplex.migrate(slug, Repo) do
        {:ok, applied} ->
          record_versions(tenant)
          {:ok, applied}

        {:error, reason} ->
          Logger.error(
            "tenant migration failed for #{tenant.institution_code}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    rescue
      error ->
        Logger.error(
          "tenant migration failed for #{tenant.institution_code} (#{slug}): #{Exception.message(error)}"
        )

        {:error, error}
    end
  end

  @doc """
  Drops the tenant's schema and everything in it.

  Destructive, and reachable only when rolling back a failed provisioning
  attempt. A college that has ever been ACTIVE is archived, never dropped,
  because its schema holds accreditation records (invariant I-19).
  """
  @spec drop(Tenant.t() | String.t()) :: :ok
  def drop(%Tenant{tenant_slug: slug}), do: drop(slug)

  def drop(slug) when is_binary(slug) do
    safe = TenantSlug.safe!(slug)
    if schema_exists?(safe), do: Triplex.drop(safe, Repo)
    :ok
  end

  @doc """
  Whether the tenant's schema exists in this database.

  Queried directly against `information_schema` rather than through
  `Triplex.exists?/2`. Two reasons, in order of importance:

    * Triplex 1.3.0 was built against an older Elixir and reaches the adapter
      with `repo.__adapter__` map notation, which Elixir now flags at **runtime**
      with a full stack trace. This function is called once per college in
      `migrate_all/1` and in `mix aims.tenants.status`, so routing it through
      Triplex buries the actual report under N warnings.
    * An existence check is a read-only catalogue lookup, not multi-tenancy
      plumbing. Triplex keeps everything that genuinely is: `CREATE SCHEMA`,
      `DROP SCHEMA`, the migration runner and the prefix.

  The slug is still bound as a parameter, never interpolated.
  """
  @spec schema_exists?(Tenant.t() | String.t()) :: boolean()
  def schema_exists?(%Tenant{tenant_slug: slug}), do: schema_exists?(slug)

  def schema_exists?(slug) when is_binary(slug) do
    schema = TenantSlug.to_schema(slug)

    %{rows: [[exists]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
        [schema]
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

  @doc "Versions already applied inside this tenant's schema."
  @spec applied_versions(Tenant.t() | String.t()) :: [integer()]
  def applied_versions(%Tenant{tenant_slug: slug}), do: applied_versions(slug)

  def applied_versions(slug) when is_binary(slug) do
    # Deliberately outside the rescue: an unsafe identifier is a bug that must
    # surface, not a "nothing applied yet" condition.
    safe = TenantSlug.safe!(slug)

    if schema_exists?(safe) do
      try do
        Ecto.Migrator.migrated_versions(Repo, prefix: Triplex.to_prefix(safe), dynamic_repo: Repo)
      rescue
        # Schema exists but has no schema_migrations table yet.
        _ -> []
      end
    else
      []
    end
  end

  @doc "Versions defined but not yet applied to this tenant."
  @spec pending_versions(Tenant.t() | String.t()) :: [integer()]
  def pending_versions(tenant_or_slug) do
    available_versions() -- applied_versions(tenant_or_slug)
  end

  @doc """
  Rolls the latest tenant migrations out to every college.

  Each is attempted independently, so one bad schema does not strand the rest,
  and the summary names exactly which failed. Re-running is safe.

  Pass `statuses: [...]` to widen the default, which skips ARCHIVED and
  PROVISION_FAILED colleges.
  """
  @spec migrate_all(keyword()) :: %{ok: [String.t()], failed: [{String.t(), term()}]}
  def migrate_all(opts \\ []) do
    statuses = Keyword.get(opts, :statuses, ["ACTIVE", "SUSPENDED", "PROVISIONING"])

    tenants =
      Repo.all(from t in Tenant, where: t.lifecycle_status in ^statuses, order_by: [asc: t.id])

    Logger.info("rolling tenant migrations out to #{length(tenants)} college(s)")

    Enum.reduce(tenants, %{ok: [], failed: []}, fn tenant, acc ->
      case migrate(tenant) do
        {:ok, _applied} -> %{acc | ok: acc.ok ++ [tenant.institution_code]}
        {:error, reason} -> %{acc | failed: acc.failed ++ [{tenant.institution_code, reason}]}
      end
    end)
  end

  @doc "Colleges whose schema is behind the latest tenant migration."
  @spec lagging_tenants() :: [Tenant.t()]
  def lagging_tenants do
    case latest_version() do
      nil ->
        []

      latest ->
        Repo.all(
          from t in Tenant,
            where: t.lifecycle_status in ["ACTIVE", "SUSPENDED", "PROVISIONING"],
            where:
              fragment(
                "NOT EXISTS (SELECT 1 FROM tenant_migration_versions v WHERE v.tenant_id = ? AND v.migration_version = ?)",
                t.id,
                ^latest
              ),
            order_by: [asc: t.id]
        )
    end
  end

  # Refresh the public projection from the tenant's own schema_migrations table.
  defp record_versions(%Tenant{id: tenant_id, tenant_slug: slug}) do
    versions =
      Ecto.Migrator.migrated_versions(Repo, prefix: Triplex.to_prefix(slug), dynamic_repo: Repo)

    now = DateTime.utc_now()

    entries =
      Enum.map(versions, &%{tenant_id: tenant_id, migration_version: &1, applied_at: now})

    if entries != [] do
      Repo.insert_all("tenant_migration_versions", entries,
        on_conflict: :nothing,
        conflict_target: [:tenant_id, :migration_version]
      )
    end

    :ok
  end

  defp resolve_override(path) do
    case Path.type(path) do
      :absolute -> path
      _ -> Application.app_dir(:aims, path)
    end
  end

  # `Path.wildcard/1` treats a backslash as a glob escape, so a Windows-style
  # path silently matches nothing and the migrator reports "no migrations to
  # run" instead of failing. Normalising to forward slashes — which Windows
  # accepts everywhere — keeps discovery working on every platform.
  defp normalise_separators(path), do: String.replace(path, "\\", "/")
end
