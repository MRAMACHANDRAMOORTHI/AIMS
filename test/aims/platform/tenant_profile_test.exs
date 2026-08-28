defmodule Aims.Platform.TenantProfileTest do
  @moduledoc """
  The profile is what keeps the four-way institution matrix out of the rest of
  the codebase, so all four configurations are asserted explicitly.
  """

  use ExUnit.Case, async: true

  alias Aims.Platform.{Tenant, TenantProfile}

  defp tenant(type, autonomy) do
    %Tenant{
      id: 1,
      code: "C-1",
      name: "Test College",
      schema_name: "tenant_c_1",
      institution_type: type,
      autonomy_status: autonomy,
      status: "ACTIVE"
    }
  end

  describe "criteria scale — set by autonomy, never by domain" do
    test "autonomous colleges are assessed out of 150" do
      assert TenantProfile.for_tenant(tenant("ENGINEERING", "AUTONOMOUS")).criteria_scale == 150
      assert TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AUTONOMOUS")).criteria_scale == 150
    end

    test "affiliated colleges are assessed out of 100" do
      assert TenantProfile.for_tenant(tenant("ENGINEERING", "AFFILIATED")).criteria_scale == 100
      assert TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AFFILIATED")).criteria_scale == 100
    end
  end

  describe "features" do
    test "OBE is on for engineering and off for arts & science by default" do
      assert TenantProfile.feature?(
               TenantProfile.for_tenant(tenant("ENGINEERING", "AUTONOMOUS")),
               :obe_mapping
             )

      refute TenantProfile.feature?(
               TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AUTONOMOUS")),
               :obe_mapping
             )
    end

    test "BoS curriculum revision follows autonomy, not domain" do
      for type <- ["ENGINEERING", "ARTS_SCIENCE"] do
        assert TenantProfile.feature?(
                 TenantProfile.for_tenant(tenant(type, "AUTONOMOUS")),
                 :bos_curriculum_revision
               )

        refute TenantProfile.feature?(
                 TenantProfile.for_tenant(tenant(type, "AFFILIATED")),
                 :bos_curriculum_revision
               )
      end
    end

    test "faculty BoS participation is the affiliated counterpart and is mutually exclusive" do
      affiliated = TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AFFILIATED"))
      autonomous = TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AUTONOMOUS"))

      assert TenantProfile.feature?(affiliated, :faculty_bos_participation)
      refute TenantProfile.feature?(affiliated, :bos_curriculum_revision)

      refute TenantProfile.feature?(autonomous, :faculty_bos_participation)
      assert TenantProfile.feature?(autonomous, :bos_curriculum_revision)
    end

    test "the 30-hour value-added rule applies to all four configurations" do
      for type <- ["ENGINEERING", "ARTS_SCIENCE"], autonomy <- ["AFFILIATED", "AUTONOMOUS"] do
        assert TenantProfile.feature?(
                 TenantProfile.for_tenant(tenant(type, autonomy)),
                 :value_added_30_hour_rule
               )
      end
    end

    test "an unknown feature reads as disabled rather than raising" do
      refute TenantProfile.feature?(
               TenantProfile.for_tenant(tenant("ENGINEERING", "AUTONOMOUS")),
               :not_a_real_feature
             )
    end
  end

  describe "experiential variant" do
    test "engineering records an industry mentor" do
      assert TenantProfile.for_tenant(tenant("ENGINEERING", "AUTONOMOUS")).experiential_variant ==
               :industry
    end

    test "arts & science records a field site" do
      assert TenantProfile.for_tenant(tenant("ARTS_SCIENCE", "AFFILIATED")).experiential_variant ==
               :field
    end
  end

  test "carries the schema name that scopes every query" do
    profile = TenantProfile.for_tenant(tenant("ENGINEERING", "AUTONOMOUS"))
    assert profile.schema_name == "tenant_c_1"
    assert profile.tenant_id == 1
  end
end
