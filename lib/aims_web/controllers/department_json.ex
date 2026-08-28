defmodule AimsWeb.DepartmentJSON do
  @moduledoc "Serialisation for departments."

  alias Aims.Academics.Department

  def index(%{departments: departments}) do
    %{data: for(department <- departments, do: data(department))}
  end

  def show(%{department: department}) do
    %{data: data(department)}
  end

  def data(%Department{} = department) do
    %{
      id: department.id,
      code: department.code,
      name: department.name,
      head_user_id: department.head_user_id,
      is_active: department.is_active,
      inserted_at: department.inserted_at,
      updated_at: department.updated_at
    }
  end
end
