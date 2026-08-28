defmodule AimsWeb.TenantControllerTest do
  use AimsWeb.ConnCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Platform
  alias Aims.Platform.TenantMigrator

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /api/v1/tenants" do
    test "provisions an engineering autonomous college", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", engineering_attrs(%{"code" => "C-API001"}))

      assert %{
               "data" => %{
                 "id" => id,
                 "code" => "C-API001",
                 "schema_name" => "tenant_c_api001",
                 "institution_type" => "ENGINEERING",
                 "autonomy_status" => "AUTONOMOUS",
                 "status" => "ACTIVE"
               }
             } = json_response(conn, 201)

      assert is_integer(id)
      assert TenantMigrator.schema_exists?("tenant_c_api001")
    end

    test "sets a Location header pointing at the new tenant", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", engineering_attrs())
      %{"data" => %{"id" => id}} = json_response(conn, 201)
      assert [location] = get_resp_header(conn, "location")
      assert location == "/api/v1/tenants/#{id}"
    end

    test "accepts a nested tenant payload as well as a flat one", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", %{"tenant" => engineering_attrs()})
      assert %{"data" => %{"status" => "ACTIVE"}} = json_response(conn, 201)
    end

    test "provisions an affiliated arts & science college", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", arts_science_attrs())

      assert %{
               "data" => %{
                 "institution_type" => "ARTS_SCIENCE",
                 "autonomy_status" => "AFFILIATED",
                 "affiliating_university" => "Test University"
               }
             } = json_response(conn, 201)
    end

    test "returns field-keyed 422 errors for missing attributes", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["code"] == ["can't be blank"]
      assert errors["name"] == ["can't be blank"]
      assert errors["institution_type"] == ["can't be blank"]
      assert errors["autonomy_status"] == ["can't be blank"]
    end

    test "rejects an unsupported institution type", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/tenants", engineering_attrs(%{"institution_type" => "COMBINED"}))

      assert %{"errors" => %{"institution_type" => ["is invalid"]}} = json_response(conn, 422)
    end

    test "requires an affiliating university for an affiliated college", %{conn: conn} do
      attrs = engineering_attrs(%{"autonomy_status" => "AFFILIATED"})
      conn = post(conn, ~p"/api/v1/tenants", attrs)

      assert %{"errors" => %{"affiliating_university" => [_]}} = json_response(conn, 422)
    end

    test "rejects a duplicate code", %{conn: conn} do
      attrs = engineering_attrs(%{"code" => "C-DUPE01"})
      assert json_response(post(conn, ~p"/api/v1/tenants", attrs), 201)

      conn = post(build_conn(), ~p"/api/v1/tenants", attrs)
      assert %{"errors" => %{"code" => ["has already been taken"]}} = json_response(conn, 422)
    end

    test "ignores a caller-supplied schema_name", %{conn: conn} do
      conn =
        post(
          conn,
          ~p"/api/v1/tenants",
          engineering_attrs(%{"code" => "C-SAFE01", "schema_name" => "public"})
        )

      assert %{"data" => %{"schema_name" => "tenant_c_safe01"}} = json_response(conn, 201)
    end

    test "ignores a caller-supplied status", %{conn: conn} do
      # A client must not be able to declare itself ACTIVE without provisioning.
      conn = post(conn, ~p"/api/v1/tenants", engineering_attrs(%{"status" => "ARCHIVED"}))
      assert %{"data" => %{"status" => "ACTIVE"}} = json_response(conn, 201)
    end

    test "rejects a code that cannot yield a schema name", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/tenants", engineering_attrs(%{"code" => "!!!!"}))
      assert %{"errors" => %{"code" => [_ | _]}} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/tenants" do
    test "lists tenants", %{conn: conn} do
      a = tenant_fixture()
      b = tenant_fixture()

      assert %{"data" => data} = json_response(get(conn, ~p"/api/v1/tenants"), 200)
      codes = Enum.map(data, & &1["code"])
      assert a.code in codes
      assert b.code in codes
    end

    test "filters by status", %{conn: conn} do
      active = tenant_fixture()
      suspended = tenant_fixture()
      {:ok, _} = Platform.suspend_tenant(suspended)

      assert %{"data" => data} =
               json_response(get(conn, ~p"/api/v1/tenants?status=SUSPENDED"), 200)

      codes = Enum.map(data, & &1["code"])
      assert suspended.code in codes
      refute active.code in codes
    end
  end

  describe "GET /api/v1/tenants/:id" do
    test "shows a tenant", %{conn: conn} do
      tenant = tenant_fixture()
      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}")
      assert %{"data" => %{"code" => code}} = json_response(conn, 200)
      assert code == tenant.code
    end

    test "404s for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/999999")
      assert %{"errors" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/tenants/:id" do
    test "renames a tenant", %{conn: conn} do
      tenant = tenant_fixture()
      conn = patch(conn, ~p"/api/v1/tenants/#{tenant.id}", %{"name" => "Renamed College"})
      assert %{"data" => %{"name" => "Renamed College"}} = json_response(conn, 200)
    end

    test "silently refuses to change institution_type or autonomy_status", %{conn: conn} do
      tenant = tenant_fixture()

      conn =
        patch(conn, ~p"/api/v1/tenants/#{tenant.id}", %{
          "name" => "Still Fine",
          "institution_type" => "ARTS_SCIENCE",
          "autonomy_status" => "AFFILIATED"
        })

      assert %{
               "data" => %{
                 "institution_type" => "ENGINEERING",
                 "autonomy_status" => "AUTONOMOUS"
               }
             } = json_response(conn, 200)
    end

    test "refuses to change code or schema_name", %{conn: conn} do
      tenant = tenant_fixture()

      conn =
        patch(conn, ~p"/api/v1/tenants/#{tenant.id}", %{
          "code" => "C-HIJACK",
          "schema_name" => "public"
        })

      assert %{"data" => %{"code" => code, "schema_name" => schema}} = json_response(conn, 200)
      assert code == tenant.code
      assert schema == tenant.schema_name
    end
  end

  describe "lifecycle transitions" do
    test "suspend then activate", %{conn: conn} do
      tenant = tenant_fixture()

      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/suspend")
      assert %{"data" => %{"status" => "SUSPENDED"}} = json_response(conn, 200)

      conn = post(build_conn(), ~p"/api/v1/tenants/#{tenant.id}/activate")
      assert %{"data" => %{"status" => "ACTIVE"}} = json_response(conn, 200)
    end

    test "archive", %{conn: conn} do
      tenant = tenant_fixture()
      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/archive")
      assert %{"data" => %{"status" => "ARCHIVED"}} = json_response(conn, 200)
    end

    test "retry refuses a healthy tenant", %{conn: conn} do
      tenant = tenant_fixture()
      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/retry")
      assert %{"errors" => %{"code" => "provisioning_failed"}} = json_response(conn, 500)
    end

    test "delete refuses a tenant holding accreditation records", %{conn: conn} do
      tenant = tenant_fixture()
      conn = delete(conn, ~p"/api/v1/tenants/#{tenant.id}")
      assert %{"errors" => %{"code" => "not_discardable"}} = json_response(conn, 409)
    end
  end

  describe "schema and migration endpoints" do
    test "reports schema status", %{conn: conn} do
      tenant = tenant_fixture()
      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/schema")

      assert %{
               "data" => %{
                 "schema_exists" => true,
                 "pending_versions" => [],
                 "up_to_date" => true,
                 "applied_versions" => applied
               }
             } = json_response(conn, 200)

      assert applied == TenantMigrator.available_versions()
    end

    test "migrates a single tenant", %{conn: conn} do
      tenant = tenant_fixture()
      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/migrations")
      assert %{"data" => %{"up_to_date" => true}} = json_response(conn, 200)
    end

    test "rolls migrations out to every tenant", %{conn: conn} do
      a = tenant_fixture()
      b = tenant_fixture()

      conn = post(conn, ~p"/api/v1/tenants/migrations")

      assert %{"data" => %{"migrated" => migrated, "failed" => [], "failed_count" => 0}} =
               json_response(conn, 200)

      assert a.code in migrated
      assert b.code in migrated
    end
  end

  describe "platform endpoints" do
    test "health reports the tenant migration line", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")

      assert %{"data" => %{"status" => "ok", "latest_tenant_migration" => latest}} =
               json_response(conn, 200)

      assert latest == TenantMigrator.latest_version()
    end

    test "academic patterns are platform-wide reference data", %{conn: conn} do
      assert %{"data" => patterns} = json_response(get(conn, ~p"/api/v1/academic-patterns"), 200)

      by_code = Map.new(patterns, &{&1["code"], &1["terms_per_year"]})
      assert by_code == %{"SEMESTER" => 2, "TRIMESTER" => 3, "ANNUAL" => 1}
    end
  end
end
