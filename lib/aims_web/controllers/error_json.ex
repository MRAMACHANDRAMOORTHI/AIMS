defmodule AimsWeb.ErrorJSON do
  @moduledoc """
  The single JSON error shape for the whole API.

  Two forms, both nested under `errors` so a client can branch on one key.

  A failure with a machine-readable reason:

      {"errors": {"code": "tenant_not_found", "detail": "No college is registered ..."}}

  A validation failure, keyed by field:

      {"errors": {"code": ["has already been taken"], "name": ["can't be blank"]}}

  Validation payloads carry no `detail`, and reasoned failures carry no field
  keys, so the two are unambiguous to parse.
  """

  @doc "A reasoned failure with a stable machine-readable `code`."
  @spec error(String.t(), String.t()) :: map()
  def error(code, detail) do
    %{errors: %{code: code, detail: detail}}
  end

  @doc "Changeset errors, keyed by field, with interpolations applied."
  @spec validation(Ecto.Changeset.t()) :: map()
  def validation(%Ecto.Changeset{} = changeset) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # Rendered by the endpoint for unhandled statuses.
  def render(template, _assigns) do
    error(
      template |> Path.rootname() |> String.replace(~r/\D/, "") |> reason_code(),
      Phoenix.Controller.status_message_from_template(template)
    )
  end

  defp reason_code("404"), do: "not_found"
  defp reason_code("401"), do: "unauthenticated"
  defp reason_code("403"), do: "forbidden"
  defp reason_code("422"), do: "unprocessable_entity"
  defp reason_code("500"), do: "internal_server_error"
  defp reason_code(other), do: "http_error_#{other}"

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
