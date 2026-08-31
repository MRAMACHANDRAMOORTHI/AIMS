defmodule AimsWeb.Plugs.ResolveTenant do
  @moduledoc """
  Resolves the tenant for a request and installs it into the process context.

      HTTP request -> resolution -> validation -> TenantContext -> tenant schema

  ## Resolution strategies, in priority order

  1. **Authenticated context** — `conn.assigns.current_membership`, set by the
     auth pipeline. The architecture (§7) makes this authoritative: the user's
     tenant comes from `public.user_tenants`, never from the request.
  2. **Subdomain** — `abc.aims.example.com` resolves tenant code `abc`.
  3. **`x-tenant` header** — the tenant's AISHE / NAAC code.

  ## Milestone 1 security posture

  Authentication does not exist yet, so strategy 1 never fires and strategies 2
  and 3 are **unauthenticated**: any caller can name any tenant. That is
  acceptable for a milestone whose acceptance criteria are provisioning and
  isolation, and unacceptable in production.

  The seam is deliberate rather than incidental. When auth lands, strategy 1
  starts matching first and `:allow_client_supplied_tenant` is set to `false`,
  at which point a client-named tenant is refused outright. Nothing downstream
  changes, because everything downstream already reads the resolved profile.

  A tenant is installed only when it is ACTIVE. Unknown, suspended, archived
  and half-provisioned tenants all fail here, before any query is built.
  """

  import Plug.Conn

  require Logger

  alias Aims.Platform
  alias Aims.Tenancy.Context
  alias AimsWeb.ErrorJSON

  @behaviour Plug

  # Hosts that are never a tenant subdomain.
  @reserved_subdomains ~w(www api admin app localhost)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case resolve(conn, opts) do
      {:ok, tenant} ->
        profile = Platform.tenant_profile(tenant)
        Context.put(profile)

        conn
        |> assign(:tenant, tenant)
        |> assign(:tenant_profile, profile)
        |> put_resp_header("x-resolved-tenant", tenant.institution_code)
        # The context lives in the process dictionary and Phoenix processes are
        # per-request, but a supervisor may reuse one under some adapters.
        # Clearing on send makes the lifetime explicit rather than assumed.
        |> register_before_send(fn sent ->
          Context.clear()
          sent
        end)

      {:error, :no_tenant_specified} ->
        halt_with(
          conn,
          :bad_request,
          "tenant_not_specified",
          "No tenant was specified. Send the college's code in the x-tenant header " <>
            "or use its subdomain."
        )

      {:error, {:not_found, code}} ->
        halt_with(
          conn,
          :not_found,
          "tenant_not_found",
          "No college is registered with the code #{inspect(code)}."
        )

      {:error, {:inactive, tenant}} ->
        halt_with(
          conn,
          :forbidden,
          "tenant_inactive",
          "The college #{inspect(tenant.institution_code)} is #{tenant.lifecycle_status} and cannot serve requests."
        )

      {:error, :client_tenant_not_allowed} ->
        halt_with(
          conn,
          :forbidden,
          "tenant_resolution_forbidden",
          "The tenant must come from the authenticated session, not from the request."
        )
    end
  end

  @doc """
  Resolves without touching the connection.

  Exposed so tests and background workers can reuse exactly the resolution
  rules the request path uses, instead of reimplementing them.
  """
  @spec resolve(Plug.Conn.t(), keyword()) ::
          {:ok, Aims.Platform.Tenant.t()}
          | {:error,
             :no_tenant_specified
             | :client_tenant_not_allowed
             | {:not_found, String.t()}
             | {:inactive, Aims.Platform.Tenant.t()}}
  def resolve(conn, opts \\ []) do
    case authenticated_tenant(conn) do
      {:ok, tenant} -> {:ok, tenant}
      :none -> resolve_from_client(conn, opts)
    end
  end

  # Strategy 1. Inert until the auth pipeline exists.
  defp authenticated_tenant(conn) do
    case conn.assigns[:current_membership] do
      %{tenant: %Aims.Platform.Tenant{lifecycle_status: "ACTIVE"} = tenant} -> {:ok, tenant}
      _ -> :none
    end
  end

  defp resolve_from_client(conn, opts) do
    if client_resolution_allowed?(opts) do
      case tenant_code(conn) do
        nil -> {:error, :no_tenant_specified}
        code -> lookup(code)
      end
    else
      {:error, :client_tenant_not_allowed}
    end
  end

  defp client_resolution_allowed?(opts) do
    Keyword.get_lazy(opts, :allow_client_supplied_tenant, fn ->
      Application.get_env(:aims, :allow_client_supplied_tenant, true)
    end)
  end

  defp lookup(code) do
    case Platform.fetch_active_tenant_by_code(code) do
      {:ok, tenant} -> {:ok, tenant}
      {:error, :not_found} -> {:error, {:not_found, code}}
      {:error, {:inactive, tenant}} -> {:error, {:inactive, tenant}}
    end
  end

  # Strategy 2 then 3.
  defp tenant_code(conn) do
    subdomain_code(conn) || header_code(conn)
  end

  defp subdomain_code(%Plug.Conn{host: host}) when is_binary(host) do
    labels = String.split(host, ".")

    case labels do
      [first | rest] when rest != [] and length(rest) >= 2 ->
        first = String.downcase(first)
        if first in @reserved_subdomains, do: nil, else: presence(first)

      _ ->
        nil
    end
  end

  defp subdomain_code(_), do: nil

  defp header_code(conn) do
    conn
    |> get_req_header("x-tenant")
    |> List.first()
    |> presence()
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp halt_with(conn, status, code, message) do
    Logger.info("tenant resolution rejected: #{code} — #{message}")

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      Plug.Conn.Status.code(status),
      Jason.encode!(ErrorJSON.error(code, message))
    )
    |> halt()
  end
end
