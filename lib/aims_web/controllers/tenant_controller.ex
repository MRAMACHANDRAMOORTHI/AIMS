defmodule AimsWeb.TenantController do
  @moduledoc """
  Platform-level tenant management.

  These endpoints operate on `public.tenants` and are **not** tenant-scoped:
  they run outside the `ResolveTenant` pipeline, because provisioning a college
  cannot require that college to already be resolvable.
  """

  use AimsWeb, :controller

  alias Aims.Platform
  alias Aims.Platform.{Provisioner, TenantMigrator}

  action_fallback AimsWeb.FallbackController

  @doc "Lists tenants, optionally filtered by `?status=ACTIVE`."
  def index(conn, params) do
    tenants = Platform.list_tenants(status: params["status"])
    render(conn, :index, tenants: tenants)
  end

  @doc """
  Registers and provisions a college.

  Returns 201 only when the schema exists, tenant migrations have run and the
  tenant is ACTIVE. A partial failure returns 500 with the tenant left in
  PROVISION_FAILED, never a 201.
  """
  def create(conn, params) do
    attrs = Map.get(params, "tenant", params)

    with {:ok, tenant} <- Platform.create_tenant(attrs) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/tenants/#{tenant.id}")
      |> render(:show, tenant: tenant)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id) do
      render(conn, :show, tenant: tenant)
    end
  end

  @doc """
  Updates editable metadata.

  `code`, `schema_name`, `institution_type` and `autonomy_status` are not
  editable. The last two are invariant I-40: changing them would silently
  invalidate every frozen report assessed on the old mark scale.
  """
  def update(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "tenant", Map.drop(params, ["id"]))

    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, tenant} <- Platform.update_tenant(tenant, attrs) do
      render(conn, :show, tenant: tenant)
    end
  end

  @doc "Discards a PROVISION_FAILED tenant: schema dropped, registry row removed."
  def delete(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, _tenant} <- Provisioner.discard_failed(tenant) do
      send_resp(conn, :no_content, "")
    end
  end

  def retry(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, tenant} <- Platform.retry_provisioning(tenant) do
      render(conn, :show, tenant: tenant)
    end
  end

  def suspend(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, tenant} <- Platform.suspend_tenant(tenant) do
      render(conn, :show, tenant: tenant)
    end
  end

  def activate(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, tenant} <- Platform.activate_tenant(tenant) do
      render(conn, :show, tenant: tenant)
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id),
         {:ok, tenant} <- Platform.archive_tenant(tenant) do
      render(conn, :show, tenant: tenant)
    end
  end

  @doc "Reports whether a tenant's schema exists and which migrations it carries."
  def schema_status(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id) do
      render(conn, :schema_status,
        tenant: tenant,
        exists: TenantMigrator.schema_exists?(tenant.schema_name),
        applied: TenantMigrator.applied_versions(tenant.schema_name),
        pending: TenantMigrator.pending_versions(tenant.schema_name)
      )
    end
  end

  @doc "Runs pending tenant migrations against one tenant."
  def migrate(conn, %{"id" => id}) do
    with {:ok, tenant} <- Platform.fetch_tenant(id) do
      case TenantMigrator.migrate(tenant) do
        {:ok, _versions} ->
          render(conn, :schema_status,
            tenant: tenant,
            exists: true,
            applied: TenantMigrator.applied_versions(tenant.schema_name),
            pending: TenantMigrator.pending_versions(tenant.schema_name)
          )

        {:error, reason} ->
          {:error, {:provisioning_failed, tenant, reason}}
      end
    end
  end

  @doc """
  Rolls pending tenant migrations out to every serving tenant.

  Each tenant is independent; the response names exactly which ones failed.
  """
  def migrate_all(conn, _params) do
    render(conn, :migration_result, TenantMigrator.migrate_all())
  end
end
