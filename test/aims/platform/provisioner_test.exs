defmodule Aims.Platform.ProvisionerTest do
  @moduledoc """
  Integration tests for the provisioning saga. These run against a real
  PostgreSQL database and create real schemas; the sandbox transaction rolls
  the DDL back afterwards.

  `async: false` because provisioning drives `Ecto.Migrator`, which needs the
  shared sandbox connection.
  """

  use Aims.DataCase, async: false

  import Aims.PlatformFixtures

  alias Aims.Platform
  alias Aims.Platform.{Provisioner, TenantMigrator}

  describe "provision/1 — happy path" do
    test "returns an ACTIVE tenant" do
      assert {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert tenant.status == "ACTIVE"
      assert tenant.id
    end

    test "creates the PostgreSQL schema" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert TenantMigrator.schema_exists?(tenant.schema_name)
    end

    test "applies every tenant migration" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())

      assert TenantMigrator.pending_versions(tenant.schema_name) == []

      assert TenantMigrator.applied_versions(tenant.schema_name) ==
               TenantMigrator.available_versions()
    end

    test "records the applied versions in the public projection" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())

      versions =
        Repo.all(
          from v in "tenant_schema_versions",
            where: v.tenant_id == ^tenant.id,
            select: v.version
        )

      assert Enum.sort(versions) == TenantMigrator.available_versions()
    end

    test "the provisioned schema is immediately usable" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())

      with_tenant(tenant, fn ->
        assert {:ok, dept} = Aims.Academics.create_department(%{"code" => "CSE", "name" => "CS"})
        assert dept.id
      end)
    end

    test "provisions an affiliated arts & science college" do
      assert {:ok, tenant} = Provisioner.provision(arts_science_attrs())
      assert tenant.status == "ACTIVE"
      assert tenant.autonomy_status == "AFFILIATED"
      assert tenant.affiliating_university == "Test University"
    end
  end

  describe "provision/1 — validation failures" do
    test "does not create a schema when the attributes are invalid" do
      before = list_tenant_schemas()

      assert {:error, {:invalid, changeset}} =
               Provisioner.provision(%{"code" => "", "name" => ""})

      refute changeset.valid?
      assert list_tenant_schemas() == before
    end

    test "refuses a duplicate tenant code" do
      attrs = engineering_attrs()
      assert {:ok, _} = Provisioner.provision(attrs)

      assert {:error, {:invalid, changeset}} = Provisioner.provision(attrs)
      assert %{code: ["has already been taken"]} = errors_on(changeset)
    end

    test "refuses an affiliated college with no affiliating university" do
      attrs = engineering_attrs(%{"autonomy_status" => "AFFILIATED"})
      assert {:error, {:invalid, changeset}} = Provisioner.provision(attrs)
      assert %{affiliating_university: [_]} = errors_on(changeset)
    end
  end

  describe "provision/1 — schema collision" do
    test "refuses to migrate into a schema it did not create, and marks the tenant failed" do
      attrs = engineering_attrs()
      {:ok, schema_name} = Aims.Platform.SchemaName.derive(attrs["code"])

      # Simulate debris from an earlier run.
      TenantMigrator.create_schema(schema_name)

      assert {:error, {:schema_collision, ^schema_name}} = Provisioner.provision(attrs)

      {:ok, tenant} = Platform.fetch_tenant_by_code(attrs["code"])
      assert tenant.status == "PROVISION_FAILED"
    end
  end

  describe "failure semantics" do
    test "a half-failed tenant is never ACTIVE and never servable" do
      # Force a migration failure by pointing the migrator at a broken path.
      attrs = engineering_attrs()

      assert {:error, {:provisioning_failed, tenant, _reason}} =
               with_broken_migrations(fn -> Provisioner.provision(attrs) end)

      assert tenant.status == "PROVISION_FAILED"

      # The request path refuses it.
      assert {:error, {:inactive, _}} = Platform.fetch_active_tenant_by_code(attrs["code"])

      # And the schema was cleaned up rather than left as debris.
      refute TenantMigrator.schema_exists?(tenant.schema_name)
    end

    test "a failed tenant is visible and queryable, not silently absent" do
      attrs = engineering_attrs()
      with_broken_migrations(fn -> Provisioner.provision(attrs) end)

      assert {:ok, tenant} = Platform.fetch_tenant_by_code(attrs["code"])
      assert tenant.status == "PROVISION_FAILED"
      assert tenant in Platform.list_tenants(status: "PROVISION_FAILED")
    end
  end

  describe "retry/1" do
    test "repairs a failed tenant" do
      attrs = engineering_attrs()
      with_broken_migrations(fn -> Provisioner.provision(attrs) end)
      {:ok, failed} = Platform.fetch_tenant_by_code(attrs["code"])
      assert failed.status == "PROVISION_FAILED"

      assert {:ok, repaired} = Provisioner.retry(failed)
      assert repaired.status == "ACTIVE"
      assert TenantMigrator.schema_exists?(repaired.schema_name)
      assert TenantMigrator.pending_versions(repaired.schema_name) == []
    end

    test "refuses to rebuild a healthy, active tenant" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert {:error, {:provisioning_failed, _, :not_retryable}} = Provisioner.retry(tenant)
    end
  end

  describe "discard_failed/1" do
    test "removes a failed tenant and its schema" do
      attrs = engineering_attrs()
      with_broken_migrations(fn -> Provisioner.provision(attrs) end)
      {:ok, failed} = Platform.fetch_tenant_by_code(attrs["code"])

      assert {:ok, _} = Provisioner.discard_failed(failed)
      assert {:error, :not_found} = Platform.fetch_tenant_by_code(attrs["code"])
      refute TenantMigrator.schema_exists?(failed.schema_name)
    end

    test "refuses to discard a tenant that holds accreditation records" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert {:error, :not_discardable} = Provisioner.discard_failed(tenant)

      {:ok, archived} = Platform.archive_tenant(tenant)
      assert {:error, :not_discardable} = Provisioner.discard_failed(archived)
    end
  end

  # Points the migrator at a directory holding a migration that raises, so the
  # abort path is driven by a real migration failure rather than a stub. An
  # empty or missing directory would not do: `Ecto.Migrator.run` treats it as
  # "nothing to apply" and succeeds, which is exactly the false-negative this
  # test exists to avoid.
  defp with_broken_migrations(fun) do
    dir =
      Path.join(System.tmp_dir!(), "aims_broken_migrations_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "20250101000001_deliberately_broken.exs"), """
    defmodule Aims.Repo.TenantMigrations.DeliberatelyBroken#{System.unique_integer([:positive])} do
      use Ecto.Migration

      def up do
        # References a table that does not exist, so PostgreSQL rejects it.
        execute "ALTER TABLE no_such_table_here ADD COLUMN nope integer"
      end

      def down, do: :ok
    end
    """)

    original = Application.get_env(:aims, :tenant_migrations_path)
    Application.put_env(:aims, :tenant_migrations_path, dir)

    try do
      fun.()
    after
      if original do
        Application.put_env(:aims, :tenant_migrations_path, original)
      else
        Application.delete_env(:aims, :tenant_migrations_path)
      end

      File.rm_rf!(dir)
    end
  end

  defp list_tenant_schemas do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'tenant_%' ORDER BY 1",
        []
      )

    List.flatten(rows)
  end
end
