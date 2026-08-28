defmodule AimsWeb.Plugs.ResolveTenantTest do
  @moduledoc """
  Tenant resolution is the front door to the isolation boundary, so its failure
  modes matter as much as its success path.
  """

  use AimsWeb.ConnCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Platform
  alias Aims.Tenancy.Context

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "successful resolution" do
    test "resolves from the x-tenant header", %{conn: conn} do
      tenant = tenant_fixture()

      conn =
        conn
        |> put_req_header("x-tenant", tenant.code)
        |> get(~p"/api/v1/tenant")

      assert %{"data" => %{"code" => code, "schema_name" => schema}} = json_response(conn, 200)
      assert code == tenant.code
      assert schema == tenant.schema_name
    end

    test "resolves from a subdomain", %{conn: conn} do
      _tenant = tenant_fixture(%{"code" => "alpha"})

      conn = %{conn | host: "alpha.aims.example.com"} |> get(~p"/api/v1/tenant")

      assert %{"data" => %{"code" => "alpha"}} = json_response(conn, 200)
    end

    test "a subdomain wins over a header, because it is the less forgeable of the two",
         %{conn: conn} do
      subdomain_tenant = tenant_fixture(%{"code" => "beta"})
      header_tenant = tenant_fixture()

      conn =
        %{conn | host: "beta.aims.example.com"}
        |> put_req_header("x-tenant", header_tenant.code)
        |> get(~p"/api/v1/tenant")

      assert %{"data" => %{"code" => code}} = json_response(conn, 200)
      assert code == subdomain_tenant.code
    end

    test "ignores reserved subdomains and falls through to the header", %{conn: conn} do
      tenant = tenant_fixture()

      conn =
        %{conn | host: "api.aims.example.com"}
        |> put_req_header("x-tenant", tenant.code)
        |> get(~p"/api/v1/tenant")

      assert %{"data" => %{"code" => code}} = json_response(conn, 200)
      assert code == tenant.code
    end

    test "echoes the resolved tenant in a response header", %{conn: conn} do
      tenant = tenant_fixture()
      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")
      assert get_resp_header(conn, "x-resolved-tenant") == [tenant.code]
    end

    test "exposes the profile the two flags resolve to", %{conn: conn} do
      tenant = tenant_fixture()

      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")

      assert %{
               "data" => %{
                 "profile" => %{
                   "criteria_scale" => 150,
                   "experiential_variant" => "industry",
                   "features" => %{
                     "obe_mapping" => true,
                     "bos_curriculum_revision" => true,
                     "faculty_bos_participation" => false,
                     "value_added_30_hour_rule" => true
                   }
                 }
               }
             } = json_response(conn, 200)
    end

    test "an affiliated arts & science college resolves to the 100-mark profile", %{conn: conn} do
      tenant = tenant_fixture(%{"institution_type" => "ARTS_SCIENCE"})

      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")

      assert %{
               "data" => %{
                 "profile" => %{
                   "criteria_scale" => 100,
                   "experiential_variant" => "field",
                   "features" => %{
                     "obe_mapping" => false,
                     "bos_curriculum_revision" => false,
                     "faculty_bos_participation" => true
                   }
                 }
               }
             } = json_response(conn, 200)
    end
  end

  describe "failed resolution" do
    test "400 when no tenant is specified at all", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenant")

      assert %{"errors" => %{"code" => "tenant_not_specified", "detail" => detail}} =
               json_response(conn, 400)

      assert detail =~ "x-tenant"
    end

    test "404 for an unknown tenant code", %{conn: conn} do
      conn = conn |> put_req_header("x-tenant", "C-NOPE") |> get(~p"/api/v1/tenant")

      assert %{"errors" => %{"code" => "tenant_not_found"}} = json_response(conn, 404)
    end

    test "403 for a suspended tenant, distinct from unknown", %{conn: conn} do
      tenant = tenant_fixture()
      {:ok, _} = Platform.suspend_tenant(tenant)

      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")

      assert %{"errors" => %{"code" => "tenant_inactive", "detail" => detail}} =
               json_response(conn, 403)

      assert detail =~ "SUSPENDED"
    end

    test "403 for an archived tenant", %{conn: conn} do
      tenant = tenant_fixture()
      {:ok, _} = Platform.archive_tenant(tenant)

      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")
      assert %{"errors" => %{"code" => "tenant_inactive"}} = json_response(conn, 403)
    end

    test "a blank header is treated as absent, not as an empty code", %{conn: conn} do
      conn = conn |> put_req_header("x-tenant", "   ") |> get(~p"/api/v1/tenant")
      assert %{"errors" => %{"code" => "tenant_not_specified"}} = json_response(conn, 400)
    end

    test "a header carrying SQL is a lookup miss, never a query", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-tenant", "'; DROP TABLE tenants; --")
        |> get(~p"/api/v1/tenant")

      assert %{"errors" => %{"code" => "tenant_not_found"}} = json_response(conn, 404)

      # The registry is intact.
      assert is_list(Platform.list_tenants())
    end

    test "halts before the controller runs", %{conn: conn} do
      conn = conn |> put_req_header("x-tenant", "C-NOPE") |> get(~p"/api/v1/departments")
      assert conn.halted
      assert json_response(conn, 404)
    end
  end

  describe "process context lifecycle" do
    test "the context does not survive the response", %{conn: conn} do
      tenant = tenant_fixture()
      Context.clear()

      conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")

      # The plug registers a before_send that clears it, so a reused process
      # cannot inherit the previous request's tenant.
      refute Context.set?()
    end
  end

  describe "client-supplied resolution can be switched off" do
    setup do
      Application.put_env(:aims, :allow_client_supplied_tenant, false)
      on_exit(fn -> Application.delete_env(:aims, :allow_client_supplied_tenant) end)
      :ok
    end

    test "403 once the authenticated strategy is authoritative", %{conn: conn} do
      tenant = tenant_fixture()

      conn = conn |> put_req_header("x-tenant", tenant.code) |> get(~p"/api/v1/tenant")

      assert %{"errors" => %{"code" => "tenant_resolution_forbidden"}} = json_response(conn, 403)
    end
  end
end
