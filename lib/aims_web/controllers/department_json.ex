defmodule AimsWeb.DepartmentJSON do
  @moduledoc """
  Serialisation for departments.

  Every department response is tenant-scoped, so timestamps render in that
  college's own time zone. The zone comes from the resolved profile rather than
  being looked up again, so a response can never disagree with the tenant that
  produced it.
  """

  alias Aims.Academics.Department
  alias Aims.Tenancy.Context
  alias Aims.Time

  def index(%{departments: departments}) do
    zone = current_zone()
    %{data: for(department <- departments, do: data(department, zone))}
  end

  def show(%{department: department}) do
    %{data: data(department, current_zone())}
  end

  def data(%Department{} = department, zone) do
    %{
      id: department.id,
      code: department.code,
      name: department.name,
      hod_user_id: department.hod_user_id,
      is_active: department.is_active,
      inserted_at: Time.render(department.inserted_at, zone),
      updated_at: Time.render(department.updated_at, zone)
    }
  end

  # The context is always set here — these views only render behind
  # ResolveTenant — but falling back keeps a view usable from IEx or a script.
  defp current_zone do
    case Context.get() do
      %{time_zone: zone} when is_binary(zone) -> zone
      _ -> Time.default_zone()
    end
  end
end
