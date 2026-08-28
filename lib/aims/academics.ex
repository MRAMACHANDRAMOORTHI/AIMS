defmodule Aims.Academics do
  @moduledoc """
  The Academic Structure bounded context: departments, and — from Milestone 2 —
  programmes and the course catalogue.

  Every function here is **implicitly tenant-scoped**. None takes a tenant
  argument, because in a schema-per-tenant model there is no tenant column to
  filter on; the schema comes from `Aims.Tenancy.Context` via
  `Aims.Tenancy.Repo`. Calling any of these with no tenant established raises
  `Aims.Tenancy.MissingTenantError` rather than silently querying `public`.
  """

  import Ecto.Query, warn: false

  alias Aims.Academics.Department
  alias Aims.Tenancy.Repo, as: TenantRepo

  @doc "Departments of the current tenant, by code."
  @spec list_departments(keyword()) :: [Department.t()]
  def list_departments(opts \\ []) do
    Department
    |> filter_active(Keyword.get(opts, :active_only, false))
    |> order_by([d], asc: d.code)
    |> TenantRepo.all()
  end

  @doc "Fetches a department of the current tenant by id."
  @spec fetch_department(integer() | String.t()) ::
          {:ok, Department.t()} | {:error, :not_found}
  def fetch_department(id) do
    case TenantRepo.get(Department, id) do
      nil -> {:error, :not_found}
      department -> {:ok, department}
    end
  end

  @doc "Fetches a department of the current tenant by code."
  @spec fetch_department_by_code(String.t()) :: {:ok, Department.t()} | {:error, :not_found}
  def fetch_department_by_code(code) when is_binary(code) do
    case TenantRepo.get_by(Department, code: String.upcase(String.trim(code))) do
      nil -> {:error, :not_found}
      department -> {:ok, department}
    end
  end

  @doc "Creates a department in the current tenant's schema."
  @spec create_department(map()) :: {:ok, Department.t()} | {:error, Ecto.Changeset.t()}
  def create_department(attrs) do
    %Department{}
    |> Department.changeset(attrs)
    |> TenantRepo.insert()
  end

  @doc "Updates a department of the current tenant."
  @spec update_department(Department.t(), map()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t()}
  def update_department(%Department{} = department, attrs) do
    department
    |> Department.changeset(attrs)
    |> TenantRepo.update()
  end

  @doc """
  Deactivates a department.

  Not a delete. Departments own programmes and courses, which in turn carry
  accreditation evidence; the architecture's delete policy is RESTRICT plus
  soft-archive throughout (invariant I-19, finding F-4).
  """
  @spec deactivate_department(Department.t()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t()}
  def deactivate_department(%Department{} = department) do
    department
    |> Department.changeset(%{is_active: false})
    |> TenantRepo.update()
  end

  @doc "How many departments the current tenant has."
  @spec count_departments() :: non_neg_integer()
  def count_departments, do: TenantRepo.aggregate(Department, :count)

  @doc "A changeset for validation surfaces."
  @spec change_department(Department.t(), map()) :: Ecto.Changeset.t()
  def change_department(%Department{} = department, attrs \\ %{}),
    do: Department.changeset(department, attrs)

  defp filter_active(query, true), do: where(query, [d], d.is_active)
  defp filter_active(query, _), do: query
end
