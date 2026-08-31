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
      assert tenant.lifecycle_status == "ACTIVE"
      assert tenant.id
    end

    test "creates the PostgreSQL schema" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert TenantMigrator.schema_exists?(tenant)
    end

    test "applies every tenant migration" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())

      assert TenantMigrator.pending_versions(tenant) == []

      assert TenantMigrator.applied_versions(tenant) ==
               TenantMigrator.available_versions()
    end

    test "records the applied versions in the public projection" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())

      versions =
        Repo.all(
          from v in "tenant_migration_versions",
            where: v.tenant_id == ^tenant.id,
            select: v.migration_version
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
      assert tenant.lifecycle_status == "ACTIVE"
      assert tenant.autonomy_status == "AFFILIATED"
      assert tenant.affiliating_university == "Test University"
    end
  end

  describe "provision/1 — validation failures" do
    test "does not create a schema when the attributes are invalid" do
      before = list_tenant_schemas()

      assert {:error, {:invalid, changeset}} =
               Provisioner.provision(%{"institution_code" => "", "institution_name" => ""})

      refute changeset.valid?
      assert list_tenant_schemas() == before
    end

    test "refuses a duplicate tenant code" do
      attrs = engineering_attrs()
      assert {:ok, _} = Provisioner.provision(attrs)

      assert {:error, {:invalid, changeset}} = Provisioner.provision(attrs)
      assert %{institution_code: ["has already been taken"]} = errors_on(changeset)
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
      {:ok, slug} = Aims.Platform.TenantSlug.derive(attrs["institution_code"])

      # Simulate debris from an earlier run.
      Triplex.create_schema(slug, Repo)

      expected_schema = Triplex.to_prefix(slug)
      assert {:error, {:schema_collision, ^expected_schema}} = Provisioner.provision(attrs)

      {:ok, tenant} = Platform.fetch_tenant_by_code(attrs["institution_code"])
      assert tenant.lifecycle_status == "PROVISION_FAILED"
    end
  end

  describe "failure semantics" do
    test "a half-failed tenant is never ACTIVE and never servable" do
      attrs = engineering_attrs()

      assert {:error, {:provisioning_failed, tenant, _reason}} =
               with_broken_migrations(fn -> Provisioner.provision(attrs) end)

      assert tenant.lifecycle_status == "PROVISION_FAILED"

      # The request path refuses it.
      assert {:error, {:inactive, _}} =
               Platform.fetch_active_tenant_by_code(attrs["institution_code"])

      # And the schema was cleaned up rather than left as debris.
      refute TenantMigrator.schema_exists?(tenant)
    end

    test "a failed tenant is visible and queryable, not silently absent" do
      attrs = engineering_attrs()
      with_broken_migrations(fn -> Provisioner.provision(attrs) end)

      assert {:ok, tenant} = Platform.fetch_tenant_by_code(attrs["institution_code"])
      assert tenant.lifecycle_status == "PROVISION_FAILED"
      assert tenant in Platform.list_tenants(status: "PROVISION_FAILED")
    end
  end

  describe "retry/1" do
    test "repairs a failed tenant" do
      attrs = engineering_attrs()
      with_broken_migrations(fn -> Provisioner.provision(attrs) end)
      {:ok, failed} = Platform.fetch_tenant_by_code(attrs["institution_code"])
      assert failed.lifecycle_status == "PROVISION_FAILED"

      assert {:ok, repaired} = Provisioner.retry(failed)
      assert repaired.lifecycle_status == "ACTIVE"
      assert TenantMigrator.schema_exists?(repaired)
      assert TenantMigrator.pending_versions(repaired) == []
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
      {:ok, failed} = Platform.fetch_tenant_by_code(attrs["institution_code"])

      assert {:ok, _} = Provisioner.discard_failed(failed)
      assert {:error, :not_found} = Platform.fetch_tenant_by_code(attrs["institution_code"])
      refute TenantMigrator.schema_exists?(failed)
    end

    test "refuses to discard a tenant that holds accreditation records" do
      {:ok, tenant} = Provisioner.provision(engineering_attrs())
      assert {:error, :not_discardable} = Provisioner.discard_failed(tenant)

      {:ok, archived} = Platform.archive_tenant(tenant)
      assert {:error, :not_discardable} = Provisioner.discard_failed(archived)
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
