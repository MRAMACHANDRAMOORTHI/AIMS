defmodule AimsWeb.ErrorJSONTest do
  use AimsWeb.ConnCase, async: true

  alias AimsWeb.ErrorJSON

  describe "render/2 for unhandled statuses" do
    test "renders 404 with a machine-readable code" do
      assert ErrorJSON.render("404.json", %{}) ==
               %{errors: %{code: "not_found", detail: "Not Found"}}
    end

    test "renders 500 with a machine-readable code" do
      assert ErrorJSON.render("500.json", %{}) ==
               %{errors: %{code: "internal_server_error", detail: "Internal Server Error"}}
    end
  end

  describe "error/2" do
    test "nests code and detail under errors" do
      assert ErrorJSON.error("tenant_not_found", "No college with that code.") ==
               %{errors: %{code: "tenant_not_found", detail: "No college with that code."}}
    end
  end

  describe "validation/1" do
    test "keys messages by field and applies interpolations" do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> Ecto.Changeset.validate_required([:name])

      assert ErrorJSON.validation(changeset) == %{errors: %{name: ["can't be blank"]}}
    end

    test "interpolates count-style messages rather than leaking the placeholder" do
      changeset =
        {%{}, %{code: :string}}
        |> Ecto.Changeset.cast(%{code: "x"}, [:code])
        |> Ecto.Changeset.validate_length(:code, min: 3)

      assert %{errors: %{code: [message]}} = ErrorJSON.validation(changeset)
      assert message == "should be at least 3 character(s)"
      refute message =~ "%{"
    end

    test "a validation payload carries no detail key, so the two shapes stay unambiguous" do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> Ecto.Changeset.validate_required([:name])

      refute Map.has_key?(ErrorJSON.validation(changeset).errors, :detail)
    end
  end
end
