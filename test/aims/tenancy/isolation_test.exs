defmodule Aims.Tenancy.IsolationTest do
  @moduledoc """
  The mandatory tenant isolation proof.

  Isolation is the security boundary of this system: a failure here is not a
  leaked row, it is one college reading another college's accreditation data.
  These tests therefore assert the boundary from several directions rather than
  once — at the context layer, at the SQL layer, across ids, and under an
  explicit attempt to cross it.
  """

  use Aims.DataCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Academics
  alias Aims.Platform
  alias Aims.Tenancy.Context

  setup do
    tenant_a =
      tenant_fixture(%{"code" => "C-AAA111", "name" => "Alpha Institute of Technology"})

    tenant_b =
      tenant_fixture(%{
        "code" => "C-BBB222",
        "name" => "Beta College of Arts and Science",
        "institution_type" => "ARTS_SCIENCE"
      })

    %{
      tenant_a: tenant_a,
      tenant_b: tenant_b,
      profile_a: Platform.tenant_profile(tenant_a),
      profile_b: Platform.tenant_profile(tenant_b)
    }
  end

  describe "the two tenants are physically distinct" do
    test "each has its own schema", %{tenant_a: a, tenant_b: b} do
      assert a.schema_name == "tenant_c_aaa111"
      assert b.schema_name == "tenant_c_bbb222"
      refute a.schema_name == b.schema_name
    end

    test "both schemas exist independently", %{tenant_a: a, tenant_b: b} do
      alias Aims.Platform.TenantMigrator
      assert TenantMigrator.schema_exists?(a.schema_name)
      assert TenantMigrator.schema_exists?(b.schema_name)
    end
  end

  describe "data written under one tenant is invisible to the other" do
    setup %{profile_a: profile_a, profile_b: profile_b} do
      dept_a =
        Context.with_tenant(profile_a, fn ->
          {:ok, d} =
            Academics.create_department(%{
              "code" => "CSE",
              "name" => "Computer Science and Engineering"
            })

          d
        end)

      {dept_b, dept_b_second} =
        Context.with_tenant(profile_b, fn ->
          {:ok, first} =
            Academics.create_department(%{"code" => "ENG", "name" => "English Literature"})

          # A second row in B only, so B holds an id that does not exist in A.
          # Without this, every id collides and "not found" can never be
          # distinguished from "found my own row", which is the trap this
          # suite has to avoid asserting past.
          {:ok, second} = Academics.create_department(%{"code" => "HIS", "name" => "History"})

          {first, second}
        end)

      %{dept_a: dept_a, dept_b: dept_b, dept_b_second: dept_b_second}
    end

    test "each tenant lists only its own departments", %{
      profile_a: pa,
      profile_b: pb
    } do
      assert Context.with_tenant(pa, fn -> Enum.map(Academics.list_departments(), & &1.code) end) ==
               ["CSE"]

      assert Context.with_tenant(pb, fn -> Enum.map(Academics.list_departments(), & &1.code) end) ==
               ["ENG", "HIS"]
    end

    test "tenant A cannot see tenant B's department by code", %{profile_a: pa} do
      assert Context.with_tenant(pa, fn -> Academics.fetch_department_by_code("ENG") end) ==
               {:error, :not_found}
    end

    test "tenant B cannot see tenant A's department by code", %{profile_b: pb} do
      assert Context.with_tenant(pb, fn -> Academics.fetch_department_by_code("CSE") end) ==
               {:error, :not_found}
    end

    test "tenant A cannot fetch a primary key that exists only in tenant B", %{
      profile_a: pa,
      dept_b_second: dept_b_second
    } do
      # This id exists in B's schema and not in A's, so a leak would surface
      # here as a successful fetch.
      assert Context.with_tenant(pa, fn -> Academics.fetch_department(dept_b_second.id) end) ==
               {:error, :not_found}
    end

    test "a colliding primary key resolves to the caller's own row, never the other tenant's", %{
      profile_a: pa,
      profile_b: pb,
      dept_a: dept_a,
      dept_b: dept_b
    } do
      # Both schemas have their own sequence, so both first rows share an id.
      # Asserting only on "found / not found" would pass even under a leak;
      # the contents are what prove the boundary held.
      assert dept_a.id == dept_b.id

      assert {:ok, %{code: "CSE", name: "Computer Science and Engineering"}} =
               Context.with_tenant(pa, fn -> Academics.fetch_department(dept_a.id) end)

      assert {:ok, %{code: "ENG", name: "English Literature"}} =
               Context.with_tenant(pb, fn -> Academics.fetch_department(dept_b.id) end)
    end

    test "counts do not bleed", %{profile_a: pa, profile_b: pb} do
      Context.with_tenant(pa, fn ->
        {:ok, _} = Academics.create_department(%{"code" => "MAT", "name" => "Mathematics"})
      end)

      assert Context.with_tenant(pa, fn -> Academics.count_departments() end) == 2
      assert Context.with_tenant(pb, fn -> Academics.count_departments() end) == 2
    end

    test "the same code can exist independently in both tenants", %{
      profile_a: pa,
      profile_b: pb
    } do
      Context.with_tenant(pa, fn ->
        {:ok, _} = Academics.create_department(%{"code" => "SHARED", "name" => "A's version"})
      end)

      # Would raise on a unique violation if both lived in one table.
      Context.with_tenant(pb, fn ->
        assert {:ok, _} =
                 Academics.create_department(%{"code" => "SHARED", "name" => "B's version"})
      end)

      assert Context.with_tenant(pa, fn ->
               elem(Academics.fetch_department_by_code("SHARED"), 1).name
             end) == "A's version"

      assert Context.with_tenant(pb, fn ->
               elem(Academics.fetch_department_by_code("SHARED"), 1).name
             end) == "B's version"
    end

    test "an update under one tenant does not touch the other", %{
      profile_a: pa,
      profile_b: pb,
      dept_a: dept_a
    } do
      Context.with_tenant(pa, fn ->
        {:ok, _} = Academics.update_department(dept_a, %{"name" => "Renamed under A"})
      end)

      assert Context.with_tenant(pb, fn ->
               elem(Academics.fetch_department_by_code("ENG"), 1).name
             end) == "English Literature"
    end
  end

  describe "the SQL itself is scoped" do
    test "queries name the tenant schema explicitly", %{profile_a: pa} do
      query = Ecto.Queryable.to_query(Academics.Department)
      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

      # Without a prefix Ecto emits an unqualified table name; the prefix is
      # what turns it into a schema-qualified one.
      refute sql =~ "tenant_"

      prefixed = %{query | prefix: pa.schema_name}
      {prefixed_sql, _} = Ecto.Adapters.SQL.to_sql(:all, Repo, prefixed)
      assert prefixed_sql =~ ~s("tenant_c_aaa111"."departments")
    end

    test "a raw cross-schema read confirms the rows really are in different schemas",
         %{tenant_a: a, tenant_b: b, profile_a: pa, profile_b: pb} do
      Context.with_tenant(pa, fn ->
        {:ok, _} = Academics.create_department(%{"code" => "CSE", "name" => "Computer Science"})
      end)

      Context.with_tenant(pb, fn ->
        {:ok, _} = Academics.create_department(%{"code" => "ENG", "name" => "English"})
        {:ok, _} = Academics.create_department(%{"code" => "HIS", "name" => "History"})
      end)

      %{rows: [[count_a]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s|SELECT count(*) FROM "#{a.schema_name}".departments|,
          []
        )

      %{rows: [[count_b]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          ~s|SELECT count(*) FROM "#{b.schema_name}".departments|,
          []
        )

      assert count_a == 1
      assert count_b == 2
    end
  end

  describe "the boundary fails closed" do
    test "tenant-scoped work with no tenant raises instead of reading public" do
      Context.clear()

      assert_raise Aims.Tenancy.MissingTenantError, fn ->
        Academics.list_departments()
      end
    end

    test "creating with no tenant raises rather than writing somewhere arbitrary" do
      Context.clear()

      assert_raise Aims.Tenancy.MissingTenantError, fn ->
        Academics.create_department(%{"code" => "X", "name" => "Nowhere"})
      end
    end

    test "the context does not survive a process boundary", %{profile_a: pa} do
      Context.put(pa)
      assert Context.set?()

      # A task starts with an empty process dictionary. Better to raise here
      # than to silently inherit — or worse, silently not inherit and read the
      # wrong schema.
      task = Task.async(fn -> Context.set?() end)
      refute Task.await(task)
    end

    test "with_tenant restores the previous tenant rather than clearing it", %{
      profile_a: pa,
      profile_b: pb
    } do
      Context.put(pa)

      Context.with_tenant(pb, fn ->
        assert Context.fetch!().schema_name == pb.schema_name
      end)

      assert Context.fetch!().schema_name == pa.schema_name
    end

    test "with_tenant restores even when the body raises", %{profile_a: pa, profile_b: pb} do
      Context.put(pa)

      assert_raise RuntimeError, fn ->
        Context.with_tenant(pb, fn -> raise "boom" end)
      end

      assert Context.fetch!().schema_name == pa.schema_name
    end
  end
end
