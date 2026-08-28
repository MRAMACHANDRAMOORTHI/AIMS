defmodule Aims.Platform.Provisioner do
  @moduledoc """
  Onboards a college: registry row, PostgreSQL schema, tenant migrations,
  initial records, ACTIVE.

  ## Why this is not one transaction

  The registry row lives in `public`; the schema creation and tenant migrations
  are DDL driven by `Ecto.Migrator`, which manages its own transactions and its
  own advisory lock. Wrapping the whole workflow in a single outer transaction
  would either deadlock against the migrator's lock or silently defeat it.

  So the workflow is a **saga with an explicit terminal state** rather than one
  atomic unit, which satisfies the requirement that a half-failed tenant is
  never left looking successful:

      insert row (PROVISIONING)   <- committed, so an orphan schema is impossible
      create schema
      run tenant migrations
      seed initial records
      mark ACTIVE                 <- the only status the application will serve

  A failure at any step after the insert drops the schema and moves the row to
  `PROVISION_FAILED`. That status is visible, queryable and retryable. It is
  never ACTIVE, and `Aims.Platform.Tenants.fetch_active/1` — the only lookup the
  request path uses — refuses everything but ACTIVE. A partially provisioned
  tenant therefore cannot serve a request, and cannot be mistaken for a healthy
  one during an audit.

  Ordering matters: the row is committed *before* the schema is created. The
  reverse would allow a schema with no registry row — an orphan nothing knows
  to clean up. This way the worst case is a registry row with no schema, which
  `PROVISION_FAILED` names explicitly and `retry/1` repairs.
  """

  require Logger

  alias Aims.Platform.{SchemaName, Tenant, TenantMigrator, TenantProfile}
  alias Aims.Repo

  @type failure_reason ::
          {:invalid, Ecto.Changeset.t()}
          | {:schema_collision, String.t()}
          | {:provisioning_failed, Tenant.t(), term()}

  @doc """
  Registers and provisions a tenant.

  Returns `{:ok, tenant}` only when the tenant is fully ACTIVE with a migrated
  schema.
  """
  @spec provision(map()) :: {:ok, Tenant.t()} | {:error, failure_reason()}
  def provision(attrs) do
    changeset = Tenant.create_changeset(%Tenant{}, attrs)

    with {:ok, tenant} <- insert_registry_row(changeset),
         :ok <- ensure_no_schema_collision(tenant) do
      build_tenant_schema(tenant)
    end
  end

  @doc """
  Re-runs provisioning for a tenant that failed or is stuck in PROVISIONING.

  The recovery mechanism the architecture requires. Refuses tenants that are
  already ACTIVE so it cannot be used to rebuild a live college's schema; use
  `Aims.Platform.TenantMigrator.migrate/1` to bring a healthy tenant forward.
  """
  @spec retry(Tenant.t()) :: {:ok, Tenant.t()} | {:error, failure_reason()}
  def retry(%Tenant{status: status} = tenant)
      when status in ["PROVISION_FAILED", "PROVISIONING"] do
    build_tenant_schema(tenant)
  end

  def retry(%Tenant{} = tenant) do
    {:error, {:provisioning_failed, tenant, :not_retryable}}
  end

  @doc """
  Removes a failed tenant entirely: schema dropped, registry row deleted.

  Deliberately restricted to `PROVISION_FAILED`. A tenant that has ever been
  ACTIVE holds accreditation records and is archived, never dropped
  (architecture §16, invariant I-19).
  """
  @spec discard_failed(Tenant.t()) :: {:ok, Tenant.t()} | {:error, :not_discardable}
  def discard_failed(%Tenant{status: "PROVISION_FAILED"} = tenant) do
    TenantMigrator.drop_schema(tenant.schema_name)
    Repo.delete(tenant)
  end

  def discard_failed(%Tenant{}), do: {:error, :not_discardable}

  defp insert_registry_row(changeset) do
    case Repo.insert(changeset) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, changeset} -> {:error, {:invalid, changeset}}
    end
  end

  # An existing schema with no matching registry row means a previous run left
  # debris, or a name collided. Either way, refuse rather than migrate into a
  # schema whose contents are unknown.
  defp ensure_no_schema_collision(%Tenant{} = tenant) do
    if TenantMigrator.schema_exists?(tenant.schema_name) do
      Logger.warning(
        "schema #{tenant.schema_name} already exists while provisioning tenant #{tenant.code}"
      )

      mark_failed(tenant)
      {:error, {:schema_collision, tenant.schema_name}}
    else
      :ok
    end
  end

  defp build_tenant_schema(%Tenant{} = tenant) do
    schema = SchemaName.safe!(tenant.schema_name)

    with :ok <- run_migrations(tenant),
         :ok <- seed_initial_records(tenant) do
      case Repo.update(Tenant.status_changeset(tenant, "ACTIVE")) do
        {:ok, active} ->
          Logger.info("provisioned tenant #{active.code} into schema #{schema}")
          {:ok, active}

        {:error, changeset} ->
          abort(tenant, changeset)
      end
    else
      {:error, reason} -> abort(tenant, reason)
    end
  end

  defp run_migrations(%Tenant{} = tenant) do
    case TenantMigrator.migrate(tenant) do
      {:ok, _versions} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Extension point. Milestone 1 seeds nothing: delivery patterns live in
  # `public.academic_patterns` (contradiction C-11), so a fresh tenant schema is
  # legitimately empty. Kept as an explicit step so later seed data has an
  # obvious, transactional home rather than being scattered into provisioning.
  defp seed_initial_records(%Tenant{}), do: :ok

  defp abort(%Tenant{} = tenant, reason) do
    Logger.error("provisioning failed for tenant #{tenant.code}: #{inspect(reason)}")
    TenantMigrator.drop_schema(tenant.schema_name)
    {:ok, failed} = mark_failed(tenant)
    {:error, {:provisioning_failed, failed, reason}}
  end

  defp mark_failed(%Tenant{} = tenant) do
    Repo.update(Tenant.status_changeset(tenant, "PROVISION_FAILED"))
  end

  @doc "Convenience: the runtime profile for a provisioned tenant."
  @spec profile(Tenant.t()) :: TenantProfile.t()
  def profile(%Tenant{} = tenant), do: TenantProfile.for_tenant(tenant)
end
