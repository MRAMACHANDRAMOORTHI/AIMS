defmodule Aims.Platform do
  @moduledoc """
  The platform / tenant-management context.

  Owns everything in the `public` schema: the tenant registry, platform
  reference data, and tenant lifecycle. This context knows about tenants; it
  knows nothing about departments, curricula or NAAC metrics. Those live inside
  a tenant schema and are reached only through `Aims.Tenancy`.
  """

  import Ecto.Query, warn: false

  alias Aims.Platform.{AcademicPattern, Provisioner, Tenant, TenantProfile}
  alias Aims.Repo

  # ── Tenants ────────────────────────────────────────────────────────────────

  @doc "All tenants, newest first."
  @spec list_tenants(keyword()) :: [Tenant.t()]
  def list_tenants(opts \\ []) do
    Tenant
    |> filter_by_status(Keyword.get(opts, :status))
    |> order_by([t], desc: t.id)
    |> Repo.all()
  end

  @doc "Fetches a tenant by id."
  @spec fetch_tenant(integer() | String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def fetch_tenant(id) do
    case Repo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  @doc "Fetches a tenant by its AISHE / NAAC code."
  @spec fetch_tenant_by_code(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def fetch_tenant_by_code(code) when is_binary(code) do
    case Repo.get_by(Tenant, code: code) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  def fetch_tenant_by_code(_), do: {:error, :not_found}

  @doc """
  Fetches a tenant by code, but only when it can serve requests.

  This is the lookup the request path uses. It distinguishes "no such college"
  from "that college is not currently servable", because the two need different
  HTTP responses and because collapsing them would let a suspended tenant look
  identical to a typo.
  """
  @spec fetch_active_tenant_by_code(String.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found} | {:error, {:inactive, Tenant.t()}}
  def fetch_active_tenant_by_code(code) do
    with {:ok, tenant} <- fetch_tenant_by_code(code) do
      case tenant.status do
        "ACTIVE" -> {:ok, tenant}
        _ -> {:error, {:inactive, tenant}}
      end
    end
  end

  @doc "Registers and provisions a new tenant. See `Aims.Platform.Provisioner`."
  @spec create_tenant(map()) :: {:ok, Tenant.t()} | {:error, Provisioner.failure_reason()}
  defdelegate create_tenant(attrs), to: Provisioner, as: :provision

  @doc "Retries provisioning for a failed or stuck tenant."
  @spec retry_provisioning(Tenant.t()) :: {:ok, Tenant.t()} | {:error, term()}
  defdelegate retry_provisioning(tenant), to: Provisioner, as: :retry

  @doc "Updates editable tenant metadata."
  @spec update_tenant(Tenant.t(), map()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def update_tenant(%Tenant{} = tenant, attrs) do
    tenant
    |> Tenant.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Suspends an active tenant. Its data is retained; it simply stops serving.

  There is no delete. A tenant that has been ACTIVE holds accreditation records
  (invariant I-19); the terminal state is ARCHIVED.
  """
  @spec suspend_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def suspend_tenant(%Tenant{} = tenant),
    do: Repo.update(Tenant.status_changeset(tenant, "SUSPENDED"))

  @doc "Returns a suspended tenant to service."
  @spec activate_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def activate_tenant(%Tenant{} = tenant),
    do: Repo.update(Tenant.status_changeset(tenant, "ACTIVE"))

  @doc "Archives a tenant. Terminal, non-serving, data retained."
  @spec archive_tenant(Tenant.t()) :: {:ok, Tenant.t()} | {:error, Ecto.Changeset.t()}
  def archive_tenant(%Tenant{} = tenant),
    do: Repo.update(Tenant.status_changeset(tenant, "ARCHIVED"))

  @doc "A changeset for form/validation surfaces."
  @spec change_tenant(Tenant.t(), map()) :: Ecto.Changeset.t()
  def change_tenant(%Tenant{} = tenant, attrs \\ %{}),
    do: Tenant.create_changeset(tenant, attrs)

  @doc "The immutable runtime profile derived from a tenant's configuration."
  @spec tenant_profile(Tenant.t()) :: TenantProfile.t()
  defdelegate tenant_profile(tenant), to: TenantProfile, as: :for_tenant

  # ── Platform reference data ────────────────────────────────────────────────

  @doc "Delivery patterns. Platform-wide, not per tenant (contradiction C-11)."
  @spec list_academic_patterns() :: [AcademicPattern.t()]
  def list_academic_patterns do
    AcademicPattern |> order_by([p], asc: p.terms_per_year) |> Repo.all()
  end

  @doc "Fetches a delivery pattern by code."
  @spec fetch_academic_pattern(String.t()) ::
          {:ok, AcademicPattern.t()} | {:error, :not_found}
  def fetch_academic_pattern(code) when is_binary(code) do
    case Repo.get(AcademicPattern, code) do
      nil -> {:error, :not_found}
      pattern -> {:ok, pattern}
    end
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [t], t.status == ^status)
end
