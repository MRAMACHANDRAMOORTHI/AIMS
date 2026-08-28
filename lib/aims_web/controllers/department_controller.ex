defmodule AimsWeb.DepartmentController do
  @moduledoc """
  Departments of the **currently resolved tenant**.

  Every action runs behind `ResolveTenant`, so no action takes or accepts a
  tenant argument. The schema comes from the process context, which is what
  makes cross-tenant access structurally impossible here rather than merely
  filtered out: there is no tenant column a caller could tamper with.

  This is the first slice of the Academic Structure context; programmes and the
  course catalogue follow in Milestone 2.
  """

  use AimsWeb, :controller

  alias Aims.Academics

  action_fallback AimsWeb.FallbackController

  def index(conn, params) do
    departments = Academics.list_departments(active_only: params["active"] == "true")
    render(conn, :index, departments: departments)
  end

  def create(conn, params) do
    attrs = Map.get(params, "department", params)

    with {:ok, department} <- Academics.create_department(attrs) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/departments/#{department.id}")
      |> render(:show, department: department)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, department} <- Academics.fetch_department(id) do
      render(conn, :show, department: department)
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.get(params, "department", Map.drop(params, ["id"]))

    with {:ok, department} <- Academics.fetch_department(id),
         {:ok, department} <- Academics.update_department(department, attrs) do
      render(conn, :show, department: department)
    end
  end

  @doc "Soft-deactivates. Departments are never hard-deleted (invariant I-19)."
  def deactivate(conn, %{"id" => id}) do
    with {:ok, department} <- Academics.fetch_department(id),
         {:ok, department} <- Academics.deactivate_department(department) do
      render(conn, :show, department: department)
    end
  end
end
