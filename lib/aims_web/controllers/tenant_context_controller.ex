defmodule AimsWeb.TenantContextController do
  @moduledoc """
  Echoes the tenant resolved for this request, together with the configuration
  that resolution produced.

  Useful as a smoke test for tenant resolution, and as the canonical way for a
  client to discover which capabilities are enabled for the college it is
  talking to — rather than reimplementing the institution-type matrix itself.
  """

  use AimsWeb, :controller

  plug :put_view, json: AimsWeb.TenantJSON

  def show(conn, _params) do
    render(conn, :context,
      tenant: conn.assigns.tenant,
      profile: conn.assigns.tenant_profile
    )
  end
end
