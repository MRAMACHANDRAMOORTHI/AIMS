defmodule Aims.Platform.TenantMigratorTest do
  @moduledoc """
  The migration mechanism must work for college N, not just college 1. These
  tests exercise a fresh tenant, an existing one being upgraded, and a
  multi-tenant rollout — all through Triplex.
  """

  use Aims.DataCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Platform
  alias Aims.Platform.{Tenant, TenantMigrator}

  describe "schema lifecycle" do
    test "create builds the schema and applies every migration" do
      {:ok, tenant} = insert_registry_row()

      refute TenantMigrator.schema_exists?(tenant)
      assert {:ok, ^tenant} = TenantMigrator.create(tenant)
      assert TenantMigrator.schema_exists?(tenant)
      assert TenantMigrator.pending_versions(tenant) == []
    end

    test "drop removes the schema and is safe to repeat" do
      tenant = tenant_fixture()
      assert TenantMigrator.schema_exists?(tenant)

      assert :ok = TenantMigrator.drop(tenant)
      refute TenantMigrator.schema_exists?(tenant)
      assert :ok = TenantMigrator.drop(tenant)
    end

    test "schema_exists? is false for a slug that was never created" do
      refute TenantMigrator.schema_exists?("never_created_at_all")
    end

    test "every schema-touching function refuses an unsafe identifier" do
      injection = ~s(x"; DROP TABLE tenants; --)

      assert_raise ArgumentError, fn -> TenantMigrator.drop(injection) end
      assert_raise ArgumentError, fn -> TenantMigrator.schema_exists?(injection) end
      assert_raise ArgumentError, fn -> TenantMigrator.applied_versions(injection) end
    end

    test "refuses reserved schema names even though they match the grammar" do
      for reserved <- ["public", "pg_catalog", "information_schema", "postgres"] do
        assert_raise ArgumentError, fn -> TenantMigrator.drop(reserved) end
      end
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
      {:ok, tenant} = insert_registry_row()
      assert TenantMigrator.applied_versions(tenant) == []
      assert TenantMigrator.pending_versions(tenant) == TenantMigrator.available_versions()
    end

    test "a provisioned college has everything applied and nothing pending" do
      tenant = tenant_fixture()

      assert TenantMigrator.applied_versions(tenant) == TenantMigrator.available_versions()
      assert TenantMigrator.pending_versions(tenant) == []
    end
  end

  describe "migrate/1" do
    test "creates the schema when it does not exist yet" do
      {:ok, tenant} = insert_registry_row()

      refute TenantMigrator.schema_exists?(tenant)
      assert {:ok, _} = TenantMigrator.migrate(tenant)
      assert TenantMigrator.schema_exists?(tenant)
      assert TenantMigrator.pending_versions(tenant) == []
    end

    test "re-running against an up-to-date college is a no-op, which makes rollout resumable" do
      tenant = tenant_fixture()
      assert {:ok, applied} = TenantMigrator.migrate(tenant)
      assert applied == []
      assert TenantMigrator.pending_versions(tenant) == []
    end

    test "refreshes the public version projection" do
      tenant = tenant_fixture()

      versions =
        Repo.all(
          from v in "tenant_migration_versions",
            where: v.tenant_id == ^tenant.id,
            select: v.migration_version,
            order_by: v.migration_version
        )

      assert versions == TenantMigrator.available_versions()
    end
  end

  describe "migrate_all/1 — the rollout that must work for college N" do
    test "brings every serving college forward" do
      a = tenant_fixture()
      b = tenant_fixture(%{"institution_type" => "ARTS_SCIENCE"})
      c = tenant_fixture()

      assert %{ok: ok, failed: []} = TenantMigrator.migrate_all()

      for tenant <- [a, b, c] do
        assert tenant.institution_code in ok
        assert TenantMigrator.pending_versions(tenant) == []
      end
    end

    test "skips archived colleges by default" do
      active = tenant_fixture()
      archived = tenant_fixture()
      {:ok, archived} = Platform.archive_tenant(archived)

      assert %{ok: ok} = TenantMigrator.migrate_all()
      assert active.institution_code in ok
      refute archived.institution_code in ok
    end

    test "includes archived colleges when asked" do
      archived = tenant_fixture()
      {:ok, archived} = Platform.archive_tenant(archived)

      assert %{ok: ok} = TenantMigrator.migrate_all(statuses: Tenant.lifecycle_statuses())
      assert archived.institution_code in ok
    end

    test "a broken migration set fails every college, and names each one" do
      good = tenant_fixture()
      other = tenant_fixture()

      assert %{failed: failed} = with_broken_migrations(fn -> TenantMigrator.migrate_all() end)

      codes = Enum.map(failed, fn {code, _reason} -> code end)
      assert good.institution_code in codes
      assert other.institution_code in codes
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

    test "names a college whose projection is missing the latest version" do
      tenant = tenant_fixture()
      latest = TenantMigrator.latest_version()

      Repo.delete_all(
        from v in "tenant_migration_versions",
          where: v.tenant_id == ^tenant.id and v.migration_version == ^latest
      )

      assert tenant.institution_code in Enum.map(
               TenantMigrator.lagging_tenants(),
               & &1.institution_code
             )
    end
  end

  # A registry row with no schema yet — the state provisioning starts from.
  defp insert_registry_row do
    %Tenant{}
    |> Tenant.create_changeset(engineering_attrs())
    |> Repo.insert()
  end
end
