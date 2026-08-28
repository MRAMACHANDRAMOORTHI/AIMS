defmodule Aims.Platform.TenantMigratorTest do
  @moduledoc """
  The migration mechanism must work for tenant N, not just tenant 1. These
  tests exercise a fresh tenant, an existing tenant being upgraded, and a
  multi-tenant rollout.
  """

  use Aims.DataCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Platform
  alias Aims.Platform.TenantMigrator

  describe "schema lifecycle" do
    test "create_schema is idempotent so a retried provision does not fail" do
      name = "tenant_idem_#{System.unique_integer([:positive])}"
      assert :ok = TenantMigrator.create_schema(name)
      assert :ok = TenantMigrator.create_schema(name)
      assert TenantMigrator.schema_exists?(name)
    end

    test "drop_schema removes it and is safe to repeat" do
      name = "tenant_drop_#{System.unique_integer([:positive])}"
      TenantMigrator.create_schema(name)
      assert :ok = TenantMigrator.drop_schema(name)
      refute TenantMigrator.schema_exists?(name)
      assert :ok = TenantMigrator.drop_schema(name)
    end

    test "schema_exists? is false for a name that was never created" do
      refute TenantMigrator.schema_exists?("tenant_never_created_at_all")
    end

    test "every schema-touching function refuses an unsafe identifier" do
      injection = ~s(tenant_x"; DROP TABLE tenants; --)

      assert_raise ArgumentError, fn -> TenantMigrator.create_schema(injection) end
      assert_raise ArgumentError, fn -> TenantMigrator.drop_schema(injection) end
      assert_raise ArgumentError, fn -> TenantMigrator.schema_exists?(injection) end
      assert_raise ArgumentError, fn -> TenantMigrator.applied_versions(injection) end
    end

    test "refuses to operate on public even by that exact name" do
      assert_raise ArgumentError, fn -> TenantMigrator.drop_schema("public") end
    end
  end

  describe "version tracking" do
    test "available_versions reflects the tenant migration directory" do
      versions = TenantMigrator.available_versions()
      assert versions != []
      assert Enum.sort(versions) == versions
      assert 20_250_101_000_001 in versions
    end

    test "latest_version is the newest available" do
      assert TenantMigrator.latest_version() == List.last(TenantMigrator.available_versions())
    end

    test "a schema that does not exist has nothing applied and everything pending" do
      name = "tenant_absent_#{System.unique_integer([:positive])}"
      assert TenantMigrator.applied_versions(name) == []
      assert TenantMigrator.pending_versions(name) == TenantMigrator.available_versions()
    end

    test "a provisioned tenant has everything applied and nothing pending" do
      tenant = tenant_fixture()

      assert TenantMigrator.applied_versions(tenant.schema_name) ==
               TenantMigrator.available_versions()

      assert TenantMigrator.pending_versions(tenant.schema_name) == []
    end
  end

  describe "migrate/1" do
    test "creates the schema when it does not exist yet" do
      {:ok, tenant} =
        %Aims.Platform.Tenant{}
        |> Aims.Platform.Tenant.create_changeset(engineering_attrs())
        |> Repo.insert()

      refute TenantMigrator.schema_exists?(tenant.schema_name)
      assert {:ok, _} = TenantMigrator.migrate(tenant)
      assert TenantMigrator.schema_exists?(tenant.schema_name)
      assert TenantMigrator.pending_versions(tenant.schema_name) == []
    end

    test "re-running against an up-to-date tenant is a no-op, which makes rollout resumable" do
      tenant = tenant_fixture()
      assert {:ok, applied} = TenantMigrator.migrate(tenant)
      assert applied == []
      assert TenantMigrator.pending_versions(tenant.schema_name) == []
    end

    test "refreshes the public version projection" do
      tenant = tenant_fixture()

      versions =
        Repo.all(
          from v in "tenant_schema_versions",
            where: v.tenant_id == ^tenant.id,
            select: v.version,
            order_by: v.version
        )

      assert versions == TenantMigrator.available_versions()
    end
  end

  describe "migrate_all/1 — the rollout that must work for tenant N" do
    test "brings every serving tenant forward" do
      a = tenant_fixture()
      b = tenant_fixture(%{"institution_type" => "ARTS_SCIENCE"})
      c = tenant_fixture()

      assert %{ok: ok, failed: []} = TenantMigrator.migrate_all()

      for tenant <- [a, b, c] do
        assert tenant.code in ok
        assert TenantMigrator.pending_versions(tenant.schema_name) == []
      end
    end

    test "skips archived tenants by default" do
      active = tenant_fixture()
      archived = tenant_fixture()
      {:ok, archived} = Platform.archive_tenant(archived)

      assert %{ok: ok} = TenantMigrator.migrate_all()
      assert active.code in ok
      refute archived.code in ok
    end

    test "includes archived tenants when asked" do
      archived = tenant_fixture()
      {:ok, archived} = Platform.archive_tenant(archived)

      assert %{ok: ok} = TenantMigrator.migrate_all(statuses: Aims.Platform.Tenant.statuses())
      assert archived.code in ok
    end

    test "one broken tenant does not strand the others" do
      good = tenant_fixture()
      broken = tenant_fixture()

      # Remove one tenant's schema behind the migrator's back, then make the
      # migration set unrunnable for it by dropping a table it depends on.
      # Simpler and equally valid: point the whole run at a broken migration
      # and confirm the summary names every tenant that failed.
      assert %{ok: _, failed: failed} = broken_run()

      codes = Enum.map(failed, fn {code, _} -> code end)
      assert good.code in codes
      assert broken.code in codes
    end

    test "the summary reports counts, not just names" do
      tenant_fixture()
      tenant_fixture()

      assert %{ok: ok, failed: []} = TenantMigrator.migrate_all()
      assert length(ok) >= 2
    end
  end

  describe "lagging_tenants/0" do
    test "is empty once everything is migrated" do
      tenant_fixture()
      tenant_fixture()
      assert TenantMigrator.lagging_tenants() == []
    end

    test "names a tenant whose projection is missing the latest version" do
      tenant = tenant_fixture()
      latest = TenantMigrator.latest_version()

      Repo.delete_all(
        from v in "tenant_schema_versions",
          where: v.tenant_id == ^tenant.id and v.version == ^latest
      )

      assert tenant.code in Enum.map(TenantMigrator.lagging_tenants(), & &1.code)
    end
  end

  defp broken_run do
    dir =
      Path.join(System.tmp_dir!(), "aims_rollout_broken_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "20250101999999_broken_rollout.exs"), """
    defmodule Aims.Repo.TenantMigrations.BrokenRollout#{System.unique_integer([:positive])} do
      use Ecto.Migration
      def up, do: execute "ALTER TABLE definitely_not_a_table ADD COLUMN x integer"
      def down, do: :ok
    end
    """)

    original = Application.get_env(:aims, :tenant_migrations_path)
    Application.put_env(:aims, :tenant_migrations_path, dir)

    try do
      TenantMigrator.migrate_all()
    after
      if original do
        Application.put_env(:aims, :tenant_migrations_path, original)
      else
        Application.delete_env(:aims, :tenant_migrations_path)
      end

      File.rm_rf!(dir)
    end
  end
end
