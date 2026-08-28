defmodule AimsWeb.PlatformController do
  @moduledoc "Platform reference data and service health."

  use AimsWeb, :controller

  alias Aims.Platform

  action_fallback AimsWeb.FallbackController

  @doc "Delivery patterns. Platform-wide reference data, not per tenant (C-11)."
  def academic_patterns(conn, _params) do
    json(conn, %{data: Platform.list_academic_patterns()})
  end

  @doc "Liveness plus the current tenant-migration version line."
  def health(conn, _params) do
    json(conn, %{
      data: %{
        status: "ok",
        latest_tenant_migration: Aims.Platform.TenantMigrator.latest_version(),
        lagging_tenants: Aims.Platform.TenantMigrator.lagging_tenants() |> Enum.map(& &1.code)
      }
    })
  end
end
