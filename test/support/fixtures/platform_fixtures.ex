defmodule Aims.PlatformFixtures do
  @moduledoc """
  Fixtures for provisioned tenants.

  `tenant_fixture/1` performs a **real** provisioning run: it creates the
  PostgreSQL schema and applies the tenant migrations. Tests that assert
  isolation must exercise the real mechanism, because a stubbed tenant would
  prove nothing about whether the schema boundary actually holds.
  """

  alias Aims.Platform

  @doc "Attributes for an engineering, autonomous college."
  def engineering_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "code" => "C-#{System.unique_integer([:positive])}",
        "name" => "Test Institute of Technology",
        "institution_type" => "ENGINEERING",
        "autonomy_status" => "AUTONOMOUS"
      },
      overrides
    )
  end

  @doc "Attributes for an arts & science, affiliated college."
  def arts_science_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "code" => "C-#{System.unique_integer([:positive])}",
        "name" => "Test College of Arts and Science",
        "institution_type" => "ARTS_SCIENCE",
        "autonomy_status" => "AFFILIATED",
        "affiliating_university" => "Test University"
      },
      overrides
    )
  end

  @doc "Provisions a tenant for real and returns it."
  def tenant_fixture(overrides \\ %{}) do
    attrs =
      case Map.get(overrides, "institution_type") do
        "ARTS_SCIENCE" -> arts_science_attrs(overrides)
        _ -> engineering_attrs(overrides)
      end

    {:ok, tenant} = Platform.create_tenant(attrs)
    tenant
  end

  @doc "Provisions a tenant and returns its runtime profile."
  def tenant_profile_fixture(overrides \\ %{}) do
    overrides |> tenant_fixture() |> Platform.tenant_profile()
  end

  @doc "Runs `fun` with `tenant` installed as the process's tenant."
  def with_tenant(tenant, fun) do
    Aims.Tenancy.Context.with_tenant(Platform.tenant_profile(tenant), fun)
  end
end
