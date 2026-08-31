defmodule AimsWeb.PlatformController do
  @moduledoc "Platform reference data and service health."

  use AimsWeb, :controller

  alias Aims.Platform
  alias Aims.Platform.TenantMigrator
  alias Aims.Time

  action_fallback AimsWeb.FallbackController

  @doc "Term patterns. Platform-wide reference data, not per tenant (C-11)."
  def academic_term_patterns(conn, _params) do
    json(conn, %{data: Platform.list_academic_term_patterns()})
  end

  @doc """
  Liveness, the tenant-migration version line, and the server clock.

  The clock is reported twice — once in UTC and once in the platform's local
  zone — so an operator can confirm at a glance that storage is UTC and
  presentation is IST, rather than having to infer it.
  """
  def health(conn, _params) do
    now = Time.utc_now()

    json(conn, %{
      data: %{
        status: "ok",
        latest_tenant_migration: TenantMigrator.latest_version(),
        lagging_tenants: Enum.map(TenantMigrator.lagging_tenants(), & &1.institution_code),
        server_time_utc: Time.render(now, "Etc/UTC"),
        server_time_local: Time.render(now),
        default_time_zone: Time.default_zone()
      }
    })
  end
end
