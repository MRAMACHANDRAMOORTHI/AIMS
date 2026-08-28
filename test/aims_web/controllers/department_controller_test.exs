defmodule AimsWeb.DepartmentControllerTest do
  @moduledoc """
  Tenant-scoped API behaviour, including the cross-tenant access attempts that
  the isolation boundary has to refuse over HTTP — not merely at the context
  layer.
  """

  use AimsWeb.ConnCase, async: false

  import Aims.PlatformFixtures

  setup %{conn: conn} do
    tenant_a = tenant_fixture(%{"code" => "C-WEBAAA", "name" => "Alpha Institute"})

    tenant_b =
      tenant_fixture(%{
        "code" => "C-WEBBBB",
        "name" => "Beta College",
        "institution_type" => "ARTS_SCIENCE"
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), a: tenant_a, b: tenant_b}
  end

  defp as(conn, tenant), do: put_req_header(conn, "x-tenant", tenant.code)

  describe "POST /api/v1/departments" do
    test "creates a department in the calling tenant's schema", %{conn: conn, a: a} do
      conn =
        conn
        |> as(a)
        |> post(~p"/api/v1/departments", %{"code" => "cse", "name" => "Computer Science"})

      assert %{"data" => %{"id" => id, "code" => "CSE", "is_active" => true}} =
               json_response(conn, 201)

      assert is_integer(id)
    end

    test "upcases the code so casing cannot create duplicates", %{conn: conn, a: a} do
      conn = conn |> as(a) |> post(~p"/api/v1/departments", %{"code" => "mat", "name" => "Maths"})
      assert %{"data" => %{"code" => "MAT"}} = json_response(conn, 201)
    end

    test "returns 422 for missing fields", %{conn: conn, a: a} do
      conn = conn |> as(a) |> post(~p"/api/v1/departments", %{})

      assert %{"errors" => %{"code" => ["can't be blank"], "name" => ["can't be blank"]}} =
               json_response(conn, 422)
    end

    test "rejects a code with unusable characters", %{conn: conn, a: a} do
      conn =
        conn |> as(a) |> post(~p"/api/v1/departments", %{"code" => "C S E!", "name" => "Nope"})

      assert %{"errors" => %{"code" => [_ | _]}} = json_response(conn, 422)
    end

    test "rejects a duplicate code within the same tenant", %{conn: conn, a: a} do
      attrs = %{"code" => "CSE", "name" => "Computer Science"}
      assert json_response(post(as(conn, a), ~p"/api/v1/departments", attrs), 201)

      conn = build_conn() |> put_req_header("accept", "application/json") |> as(a)

      assert %{"errors" => %{"code" => ["has already been taken"]}} =
               json_response(post(conn, ~p"/api/v1/departments", attrs), 422)
    end

    test "the same code is free in a different tenant", %{conn: conn, a: a, b: b} do
      attrs = %{"code" => "CSE", "name" => "Computer Science"}
      assert json_response(post(as(conn, a), ~p"/api/v1/departments", attrs), 201)

      conn_b = build_conn() |> put_req_header("accept", "application/json") |> as(b)
      assert json_response(post(conn_b, ~p"/api/v1/departments", attrs), 201)
    end
  end

  describe "cross-tenant access over HTTP" do
    setup %{conn: conn, a: a, b: b} do
      %{"data" => %{"id" => dept_a_id}} =
        conn
        |> as(a)
        |> post(~p"/api/v1/departments", %{"code" => "CSE", "name" => "Computer Science"})
        |> json_response(201)

      conn_b = build_conn() |> put_req_header("accept", "application/json") |> as(b)

      %{"data" => %{"id" => _}} =
        conn_b
        |> post(~p"/api/v1/departments", %{"code" => "ENG", "name" => "English"})
        |> json_response(201)

      %{"data" => %{"id" => dept_b_extra_id}} =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> as(b)
        |> post(~p"/api/v1/departments", %{"code" => "HIS", "name" => "History"})
        |> json_response(201)

      %{dept_a_id: dept_a_id, dept_b_extra_id: dept_b_extra_id}
    end

    test "each tenant's index shows only its own departments", %{conn: conn, a: a, b: b} do
      assert %{"data" => a_data} =
               json_response(get(as(conn, a), ~p"/api/v1/departments"), 200)

      assert Enum.map(a_data, & &1["code"]) == ["CSE"]

      conn_b = build_conn() |> put_req_header("accept", "application/json") |> as(b)
      assert %{"data" => b_data} = json_response(get(conn_b, ~p"/api/v1/departments"), 200)
      assert Enum.map(b_data, & &1["code"]) == ["ENG", "HIS"]
    end

    test "tenant A gets 404 for an id that exists only in tenant B", %{
      conn: conn,
      a: a,
      dept_b_extra_id: id
    } do
      conn = conn |> as(a) |> get(~p"/api/v1/departments/#{id}")
      assert %{"errors" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "a colliding id resolves to the caller's own row", %{
      conn: conn,
      a: a,
      b: b,
      dept_a_id: dept_a_id
    } do
      assert %{"data" => %{"code" => "CSE"}} =
               json_response(get(as(conn, a), ~p"/api/v1/departments/#{dept_a_id}"), 200)

      conn_b = build_conn() |> put_req_header("accept", "application/json") |> as(b)

      assert %{"data" => %{"code" => "ENG"}} =
               json_response(get(conn_b, ~p"/api/v1/departments/#{dept_a_id}"), 200)
    end

    test "tenant A cannot update tenant B's department", %{
      conn: conn,
      a: a,
      dept_b_extra_id: id
    } do
      conn = conn |> as(a) |> patch(~p"/api/v1/departments/#{id}", %{"name" => "Hijacked"})
      assert %{"errors" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "tenant A cannot deactivate tenant B's department", %{
      conn: conn,
      a: a,
      dept_b_extra_id: id
    } do
      conn = conn |> as(a) |> post(~p"/api/v1/departments/#{id}/deactivate")
      assert %{"errors" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "switching the header switches the schema, with no bleed", %{conn: conn, a: a, b: b} do
      assert %{"data" => [%{"code" => "CSE"}]} =
               json_response(get(as(conn, a), ~p"/api/v1/departments"), 200)

      conn_b = build_conn() |> put_req_header("accept", "application/json") |> as(b)
      assert %{"data" => data} = json_response(get(conn_b, ~p"/api/v1/departments"), 200)
      refute "CSE" in Enum.map(data, & &1["code"])
    end
  end

  describe "tenant-scoped endpoints require a tenant" do
    test "400 without a tenant header", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/departments")
      assert %{"errors" => %{"code" => "tenant_not_specified"}} = json_response(conn, 400)
    end

    test "404 for an unknown tenant", %{conn: conn} do
      conn = conn |> put_req_header("x-tenant", "C-GHOST") |> get(~p"/api/v1/departments")
      assert %{"errors" => %{"code" => "tenant_not_found"}} = json_response(conn, 404)
    end

    test "403 for a suspended tenant", %{conn: conn, a: a} do
      {:ok, _} = Aims.Platform.suspend_tenant(a)
      conn = conn |> as(a) |> get(~p"/api/v1/departments")
      assert %{"errors" => %{"code" => "tenant_inactive"}} = json_response(conn, 403)
    end
  end

  describe "update and deactivate" do
    test "renames a department", %{conn: conn, a: a} do
      %{"data" => %{"id" => id}} =
        conn
        |> as(a)
        |> post(~p"/api/v1/departments", %{"code" => "CSE", "name" => "Computer Science"})
        |> json_response(201)

      conn = build_conn() |> put_req_header("accept", "application/json") |> as(a)

      assert %{"data" => %{"name" => "Computer Science & Engineering"}} =
               conn
               |> patch(~p"/api/v1/departments/#{id}", %{
                 "name" => "Computer Science & Engineering"
               })
               |> json_response(200)
    end

    test "deactivate soft-deletes rather than removing the row", %{conn: conn, a: a} do
      %{"data" => %{"id" => id}} =
        conn
        |> as(a)
        |> post(~p"/api/v1/departments", %{"code" => "CSE", "name" => "Computer Science"})
        |> json_response(201)

      conn = build_conn() |> put_req_header("accept", "application/json") |> as(a)

      assert %{"data" => %{"is_active" => false}} =
               conn |> post(~p"/api/v1/departments/#{id}/deactivate") |> json_response(200)

      # Still present, just inactive.
      conn2 = build_conn() |> put_req_header("accept", "application/json") |> as(a)

      assert %{"data" => %{"id" => ^id}} =
               conn2 |> get(~p"/api/v1/departments/#{id}") |> json_response(200)
    end

    test "?active=true filters out deactivated departments", %{conn: conn, a: a} do
      %{"data" => %{"id" => id}} =
        conn
        |> as(a)
        |> post(~p"/api/v1/departments", %{"code" => "OLD", "name" => "Retired Dept"})
        |> json_response(201)

      build_conn()
      |> put_req_header("accept", "application/json")
      |> as(a)
      |> post(~p"/api/v1/departments/#{id}/deactivate")
      |> json_response(200)

      conn2 = build_conn() |> put_req_header("accept", "application/json") |> as(a)
      assert %{"data" => []} = json_response(get(conn2, ~p"/api/v1/departments?active=true"), 200)
    end
  end
end
