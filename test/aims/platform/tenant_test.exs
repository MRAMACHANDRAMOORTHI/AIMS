defmodule Aims.Platform.TenantTest do
  use ExUnit.Case, async: true

  alias Aims.Platform.Tenant

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "code" => "C-41207",
        "name" => "ABC Institute of Technology",
        "institution_type" => "ENGINEERING",
        "autonomy_status" => "AUTONOMOUS"
      },
      overrides
    )
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end

  describe "create_changeset/2" do
    test "accepts a well-formed autonomous engineering college" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs())
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == "PROVISIONING"
    end

    test "derives schema_name from code rather than trusting the caller" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :schema_name) == "tenant_c_41207"
    end

    test "ignores a caller-supplied schema_name entirely" do
      changeset =
        Tenant.create_changeset(%Tenant{}, valid_attrs(%{"schema_name" => "public"}))

      assert Ecto.Changeset.get_change(changeset, :schema_name) == "tenant_c_41207"
    end

    test "requires the core fields" do
      changeset = Tenant.create_changeset(%Tenant{}, %{})
      refute changeset.valid?

      assert %{
               code: ["can't be blank"],
               name: ["can't be blank"],
               institution_type: ["can't be blank"],
               autonomy_status: ["can't be blank"]
             } = errors(changeset)
    end

    test "restricts institution_type to the two supported domains" do
      changeset =
        Tenant.create_changeset(%Tenant{}, valid_attrs(%{"institution_type" => "COMBINED"}))

      refute changeset.valid?
      assert %{institution_type: ["is invalid"]} = errors(changeset)
    end

    test "restricts autonomy_status to the two supported governance models" do
      changeset =
        Tenant.create_changeset(%Tenant{}, valid_attrs(%{"autonomy_status" => "DEEMED"}))

      refute changeset.valid?
      assert %{autonomy_status: ["is invalid"]} = errors(changeset)
    end

    test "requires an affiliating university for an affiliated college" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          valid_attrs(%{"autonomy_status" => "AFFILIATED", "institution_type" => "ARTS_SCIENCE"})
        )

      refute changeset.valid?
      assert %{affiliating_university: [_]} = errors(changeset)
    end

    test "treats a blank affiliating university as missing" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          valid_attrs(%{"autonomy_status" => "AFFILIATED", "affiliating_university" => "   "})
        )

      refute changeset.valid?
      assert %{affiliating_university: [_]} = errors(changeset)
    end

    test "does not require an affiliating university for an autonomous college" do
      assert Tenant.create_changeset(%Tenant{}, valid_attrs()).valid?
    end

    test "rejects a code from which no schema name can be derived" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs(%{"code" => "!!!!"}))
      refute changeset.valid?
      assert %{code: [_ | _]} = errors(changeset)
    end

    test "trims surrounding whitespace" do
      changeset =
        Tenant.create_changeset(%Tenant{}, valid_attrs(%{"name" => "  ABC Institute  "}))

      assert Ecto.Changeset.get_change(changeset, :name) == "ABC Institute"
    end

    test "forces status to PROVISIONING even when ACTIVE is supplied" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs(%{"status" => "ACTIVE"}))
      assert Ecto.Changeset.get_field(changeset, :status) == "PROVISIONING"
    end
  end

  describe "update_changeset/2" do
    setup do
      %{
        tenant: %Tenant{
          id: 1,
          code: "C-41207",
          name: "ABC Institute",
          schema_name: "tenant_c_41207",
          institution_type: "ENGINEERING",
          autonomy_status: "AUTONOMOUS",
          status: "ACTIVE"
        }
      }
    end

    test "allows renaming", %{tenant: tenant} do
      changeset = Tenant.update_changeset(tenant, %{"name" => "ABC Institute of Technology"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "ABC Institute of Technology"
    end

    test "refuses to change institution_type (invariant I-40)", %{tenant: tenant} do
      changeset = Tenant.update_changeset(tenant, %{"institution_type" => "ARTS_SCIENCE"})
      refute Ecto.Changeset.get_change(changeset, :institution_type)
    end

    test "refuses to change autonomy_status (invariant I-40)", %{tenant: tenant} do
      changeset = Tenant.update_changeset(tenant, %{"autonomy_status" => "AFFILIATED"})
      refute Ecto.Changeset.get_change(changeset, :autonomy_status)
    end

    test "refuses to change code or schema_name", %{tenant: tenant} do
      changeset =
        Tenant.update_changeset(tenant, %{"code" => "C-999", "schema_name" => "public"})

      refute Ecto.Changeset.get_change(changeset, :code)
      refute Ecto.Changeset.get_change(changeset, :schema_name)
    end

    test "still enforces the affiliation rule", %{tenant: tenant} do
      affiliated = %{tenant | autonomy_status: "AFFILIATED", affiliating_university: "Anna Univ"}
      changeset = Tenant.update_changeset(affiliated, %{"affiliating_university" => ""})
      refute changeset.valid?
    end
  end
end
