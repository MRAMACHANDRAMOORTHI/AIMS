defmodule AimsWeb.FallbackController do
  @moduledoc """
  Turns the error tuples returned by contexts into HTTP responses.

  Keeping this in one place is what lets controllers stay thin: an action
  returns whatever its context returned, and the mapping from domain failure to
  status code is decided once, here.
  """

  use AimsWeb, :controller

  alias AimsWeb.ErrorJSON

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.validation(changeset))
  end

  def call(conn, {:error, {:invalid, %Ecto.Changeset{} = changeset}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.validation(changeset))
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(ErrorJSON.error("not_found", "The requested resource does not exist."))
  end

  def call(conn, {:error, {:schema_collision, schema_name}}) do
    conn
    |> put_status(:conflict)
    |> json(
      ErrorJSON.error(
        "schema_collision",
        "A PostgreSQL schema named #{inspect(schema_name)} already exists. " <>
          "Resolve the collision before provisioning this college."
      )
    )
  end

  def call(conn, {:error, {:provisioning_failed, tenant, reason}}) do
    conn
    |> put_status(:internal_server_error)
    |> json(
      ErrorJSON.error(
        "provisioning_failed",
        "Provisioning #{tenant.code} failed and the college was left as #{tenant.status}. " <>
          "Retry it once the cause is fixed. Reason: #{describe(reason)}"
      )
    )
  end

  def call(conn, {:error, :not_retryable}) do
    conn
    |> put_status(:conflict)
    |> json(
      ErrorJSON.error(
        "not_retryable",
        "Only a college in PROVISION_FAILED or PROVISIONING can be re-provisioned."
      )
    )
  end

  def call(conn, {:error, :not_discardable}) do
    conn
    |> put_status(:conflict)
    |> json(
      ErrorJSON.error(
        "not_discardable",
        "Only a college in PROVISION_FAILED can be discarded. " <>
          "A college that has been active holds accreditation records; archive it instead."
      )
    )
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ErrorJSON.error(to_string(reason), "The request could not be completed."))
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)
end
