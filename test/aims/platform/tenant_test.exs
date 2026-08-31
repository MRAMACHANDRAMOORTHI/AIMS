defmodule Aims.Platform.TenantTest do
  use ExUnit.Case, async: true

  alias Aims.Platform.Tenant

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "institution_code" => "C-41207",
        "institution_name" => "ABC Institute of Technology",
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
      assert Ecto.Changeset.get_field(changeset, :lifecycle_status) == "PROVISIONING"
    end

    test "derives the tenant slug from the institution code, not from the caller" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs())
      assert Ecto.Changeset.get_change(changeset, :tenant_slug) == "c_41207"
    end

    test "ignores a caller-supplied tenant slug or schema name entirely" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          valid_attrs(%{"schema_name" => "public", "tenant_slug" => "public"})
        )

      assert Ecto.Changeset.get_change(changeset, :tenant_slug) == "c_41207"
    end

    test "requires the core fields" do
      changeset = Tenant.create_changeset(%Tenant{}, %{})
      refute changeset.valid?

      assert %{
               institution_code: ["can't be blank"],
               institution_name: ["can't be blank"],
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

    test "rejects an institution code from which no slug can be derived" do
      changeset = Tenant.create_changeset(%Tenant{}, valid_attrs(%{"institution_code" => "!!!!"}))
      refute changeset.valid?
      assert %{institution_code: [_ | _]} = errors(changeset)
    end

    test "trims surrounding whitespace" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          valid_attrs(%{"institution_name" => "  ABC Institute  "})
        )

      assert Ecto.Changeset.get_change(changeset, :institution_name) == "ABC Institute"
    end

    test "forces lifecycle_status to PROVISIONING even when ACTIVE is supplied" do
      changeset =
        Tenant.create_changeset(%Tenant{}, valid_attrs(%{"lifecycle_status" => "ACTIVE"}))

      assert Ecto.Changeset.get_field(changeset, :lifecycle_status) == "PROVISIONING"
    end
  end

  describe "update_changeset/2" do
    setup do
      %{
        tenant: %Tenant{
          id: 1,
          institution_code: "C-41207",
          institution_name: "ABC Institute",
          tenant_slug: "c_41207",
          institution_type: "ENGINEERING",
          autonomy_status: "AUTONOMOUS",
          lifecycle_status: "ACTIVE",
          time_zone: "Asia/Kolkata"
        }
      }
    end

    test "allows renaming", %{tenant: tenant} do
      changeset =
        Tenant.update_changeset(tenant, %{"institution_name" => "ABC Institute of Technology"})

      assert changeset.valid?

      assert Ecto.Changeset.get_change(changeset, :institution_name) ==
               "ABC Institute of Technology"
    end

    test "refuses to change institution_type (invariant I-40)", %{tenant: tenant} do
      changeset = Tenant.update_changeset(tenant, %{"institution_type" => "ARTS_SCIENCE"})
      refute Ecto.Changeset.get_change(changeset, :institution_type)
    end

    test "refuses to change autonomy_status (invariant I-40)", %{tenant: tenant} do
      changeset = Tenant.update_changeset(tenant, %{"autonomy_status" => "AFFILIATED"})
      refute Ecto.Changeset.get_change(changeset, :autonomy_status)
    end

    test "refuses to change institution_code or tenant_slug", %{tenant: tenant} do
      changeset =
        Tenant.update_changeset(tenant, %{
          "institution_code" => "C-999",
          "schema_name" => "public"
        })

      refute Ecto.Changeset.get_change(changeset, :institution_code)
      refute Ecto.Changeset.get_change(changeset, :tenant_slug)
    end

    test "still enforces the affiliation rule", %{tenant: tenant} do
      affiliated = %{tenant | autonomy_status: "AFFILIATED", affiliating_university: "Anna Univ"}
      changeset = Tenant.update_changeset(affiliated, %{"affiliating_university" => ""})
      refute changeset.valid?
    end
  end
end
