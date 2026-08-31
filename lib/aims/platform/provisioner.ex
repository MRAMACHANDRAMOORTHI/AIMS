defmodule Aims.Platform.Provisioner do
  @moduledoc """
  Onboards a college: registry row, PostgreSQL schema, tenant migrations,
  initial records, ACTIVE.

  ## Why this is not one transaction

  The registry row lives in `public`; the schema and its migrations are DDL
  driven by Triplex, which runs `Ecto.Migrator` with its own transaction and
  advisory lock. Wrapping the whole workflow in one outer transaction would
  either deadlock against that lock or silently defeat it.

  So the workflow is a **saga with an explicit terminal state**, which satisfies
  the requirement that a half-failed college is never left looking successful:

      insert row (PROVISIONING)   <- committed, so an orphan schema is impossible
      Triplex.create              <- schema + migrations, atomic within itself
      seed initial records
      mark ACTIVE                 <- the only status the application will serve

  A failure at any step after the insert drops the schema and moves the row to
  `PROVISION_FAILED`. That status is visible, queryable and retryable. It is
  never ACTIVE, and `fetch_active_tenant_by_code/1` — the only lookup the
  request path uses — refuses everything else. A partially provisioned college
  therefore cannot serve a request, and cannot be mistaken for a healthy one
  during an audit.

  Ordering matters: the row is committed *before* the schema is created. The
  reverse would allow a schema with no registry row — an orphan nothing knows to
  clean up. This way the worst case is a registry row with no schema, which
  `PROVISION_FAILED` names explicitly and `retry/1` repairs.
  """

  require Logger

  alias Aims.Platform.{Tenant, TenantMigrator, TenantProfile}
  alias Aims.Repo

  @type failure_reason ::
          {:invalid, Ecto.Changeset.t()}
          | {:schema_collision, String.t()}
          | {:provisioning_failed, Tenant.t(), term()}

  @doc """
  Registers and provisions a college.

  Returns `{:ok, tenant}` only when it is fully ACTIVE with a migrated schema.
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
  Re-runs provisioning for a college that failed or is stuck in PROVISIONING.

  Refuses colleges that are already ACTIVE so it cannot rebuild a live schema;
  use `Aims.Platform.TenantMigrator.migrate/1` to bring a healthy college
  forward.
  """
  @spec retry(Tenant.t()) :: {:ok, Tenant.t()} | {:error, failure_reason()}
  def retry(%Tenant{lifecycle_status: status} = tenant)
      when status in ["PROVISION_FAILED", "PROVISIONING"] do
    build_tenant_schema(tenant)
  end

  def retry(%Tenant{} = tenant) do
    {:error, {:provisioning_failed, tenant, :not_retryable}}
  end

  @doc """
  Removes a failed college entirely: schema dropped, registry row deleted.

  Deliberately restricted to `PROVISION_FAILED`. A college that has ever been
  ACTIVE holds accreditation records and is archived, never dropped
  (invariant I-19).
  """
  @spec discard_failed(Tenant.t()) :: {:ok, Tenant.t()} | {:error, :not_discardable}
  def discard_failed(%Tenant{lifecycle_status: "PROVISION_FAILED"} = tenant) do
    TenantMigrator.drop(tenant)
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
  # debris, or a slug collided. Either way, refuse rather than migrate into a
  # schema whose contents are unknown.
  defp ensure_no_schema_collision(%Tenant{} = tenant) do
    if TenantMigrator.schema_exists?(tenant) do
      schema = Tenant.schema_name(tenant)

      Logger.warning(
        "schema #{schema} already exists while provisioning #{tenant.institution_code}"
      )

      mark_failed(tenant)
      {:error, {:schema_collision, schema}}
    else
      :ok
    end
  end

  defp build_tenant_schema(%Tenant{} = tenant) do
    with {:ok, _} <- TenantMigrator.create(tenant),
         :ok <- seed_initial_records(tenant) do
      case Repo.update(Tenant.lifecycle_changeset(tenant, "ACTIVE")) do
        {:ok, active} ->
          Logger.info("provisioned #{active.institution_code} into #{Tenant.schema_name(active)}")

          {:ok, active}

        {:error, changeset} ->
          abort(tenant, changeset)
      end
    else
      {:error, reason} -> abort(tenant, reason)
    end
  end

  # Extension point. Milestone 1 seeds nothing: term patterns live in
  # `public.academic_term_patterns` (contradiction C-11), so a fresh tenant
  # schema is legitimately empty. Kept as an explicit step so later seed data
  # has an obvious home rather than being scattered into provisioning.
  defp seed_initial_records(%Tenant{}), do: :ok

  defp abort(%Tenant{} = tenant, reason) do
    Logger.error("provisioning failed for #{tenant.institution_code}: #{inspect(reason)}")
    TenantMigrator.drop(tenant)
    {:ok, failed} = mark_failed(tenant)
    {:error, {:provisioning_failed, failed, reason}}
  end

  defp mark_failed(%Tenant{} = tenant) do
    Repo.update(Tenant.lifecycle_changeset(tenant, "PROVISION_FAILED"))
  end

  @doc "Convenience: the runtime profile for a provisioned college."
  @spec profile(Tenant.t()) :: TenantProfile.t()
  def profile(%Tenant{} = tenant), do: TenantProfile.for_tenant(tenant)
end
