defmodule Aims.Tenancy.Context do
  @moduledoc """
  The current tenant, scoped to the executing process.

  ## Why a process-scoped context

  In the approved architecture a tenant is a PostgreSQL schema, not a column.
  Domain code therefore must never take a `tenant_id` argument — there is no
  such column to filter on. Something has to carry "which schema" from the
  request boundary down to the repo, and in Phoenix a request is exactly one
  process, so the process dictionary is the natural carrier.

      Aims.Tenancy.Context.put(profile)
      Aims.Academics.list_departments()   # no tenant argument anywhere

  ## Caveat that matters

  The process dictionary does not cross process boundaries. Work handed to
  `Task.async/1`, a `GenServer`, or an `Oban` job starts with an empty context.
  Capture the profile in the parent and re-establish it in the child with
  `with_tenant/2`; `Aims.Tenancy.Repo` raises rather than guessing, so a missed
  hand-off fails loudly at the first query instead of reading the wrong schema.
  """

  alias Aims.Platform.TenantProfile

  @key :aims_tenant_profile

  @doc "Installs `profile` as the current tenant for this process."
  @spec put(TenantProfile.t()) :: :ok
  def put(%TenantProfile{} = profile) do
    Process.put(@key, profile)
    :ok
  end

  @doc "The current tenant profile, or `nil` when none is set."
  @spec get() :: TenantProfile.t() | nil
  def get, do: Process.get(@key)

  @doc """
  The current tenant profile, or raises.

  Used by anything that cannot meaningfully proceed without a tenant.
  """
  @spec fetch!() :: TenantProfile.t()
  def fetch! do
    case get() do
      %TenantProfile{} = profile ->
        profile

      nil ->
        raise Aims.Tenancy.MissingTenantError,
              "no tenant is set for this process. Establish one with " <>
                "Aims.Tenancy.Context.put/1 (the ResolveTenant plug does this " <>
                "for web requests) before running tenant-scoped queries."
    end
  end

  @doc "The PostgreSQL schema of the current tenant, or raises."
  @spec schema!() :: String.t()
  def schema!, do: fetch!().schema_name

  @doc "True when a tenant is established for this process."
  @spec set?() :: boolean()
  def set?, do: not is_nil(get())

  @doc "Removes the current tenant from this process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc """
  Runs `fun` with `profile` installed, restoring the previous context after.

  Restoring rather than clearing keeps nesting honest, which matters in tests
  and in any background worker that processes several tenants in sequence.
  """
  @spec with_tenant(TenantProfile.t(), (-> result)) :: result when result: term()
  def with_tenant(%TenantProfile{} = profile, fun) when is_function(fun, 0) do
    previous = get()
    put(profile)

    try do
      fun.()
    after
      case previous do
        nil -> clear()
        %TenantProfile{} = prev -> put(prev)
      end
    end
  end
end

defmodule Aims.Tenancy.MissingTenantError do
  @moduledoc "Raised when tenant-scoped work is attempted with no tenant established."
  defexception [:message]
end
