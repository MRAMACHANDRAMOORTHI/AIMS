defmodule Aims.PlatformFixtures do
  @moduledoc """
  Fixtures for provisioned colleges.

  `tenant_fixture/1` performs a **real** provisioning run: it creates the
  PostgreSQL schema through Triplex and applies the tenant migrations. Tests
  that assert isolation must exercise the real mechanism, because a stubbed
  tenant would prove nothing about whether the schema boundary actually holds.
  """

  alias Aims.Platform

  @doc "Attributes for an engineering, autonomous college."
  def engineering_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "institution_code" => "C-#{System.unique_integer([:positive])}",
        "institution_name" => "Test Institute of Technology",
        "institution_type" => "ENGINEERING",
        "autonomy_status" => "AUTONOMOUS"
      },
      overrides
    )
  end

  @doc "Attributes for an arts & science, affiliated college."
  def arts_science_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "institution_code" => "C-#{System.unique_integer([:positive])}",
        "institution_name" => "Test College of Arts and Science",
        "institution_type" => "ARTS_SCIENCE",
        "autonomy_status" => "AFFILIATED",
        "affiliating_university" => "Test University"
      },
      overrides
    )
  end

  @doc "Provisions a college for real and returns it."
  def tenant_fixture(overrides \\ %{}) do
    attrs =
      case Map.get(overrides, "institution_type") do
        "ARTS_SCIENCE" -> arts_science_attrs(overrides)
        _ -> engineering_attrs(overrides)
      end

    {:ok, tenant} = Platform.create_tenant(attrs)
    tenant
  end

  @doc "Provisions a college and returns its runtime profile."
  def tenant_profile_fixture(overrides \\ %{}) do
    overrides |> tenant_fixture() |> Platform.tenant_profile()
  end

  @doc "Runs `fun` with `tenant` installed as the process's college."
  def with_tenant(tenant, fun) do
    Aims.Tenancy.Context.with_tenant(Platform.tenant_profile(tenant), fun)
  end

  @doc """
  Runs `fun` with the tenant migration set pointed at a migration that fails.

  Triplex resolves its migration directory from `config :triplex,
  :migrations_path`, relative to the repo's `priv/repo`, so the override has to
  go through Triplex rather than through application config — and the directory
  has to be created inside the built application's `priv`, which is where
  `Ecto.Migrator.migrations_path/1` looks.

  An empty or missing directory would not do: the migrator treats it as
  "nothing to apply" and succeeds, which is precisely the false negative these
  failure tests exist to avoid.
  """
  def with_broken_migrations(fun) do
    name = "broken_tenant_migrations_#{System.unique_integer([:positive])}"
    dir = Path.join(Application.app_dir(:aims, "priv/repo"), name)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "20250101999999_deliberately_broken.exs"), """
    defmodule Aims.Repo.TenantMigrations.DeliberatelyBroken#{System.unique_integer([:positive])} do
      use Ecto.Migration

      def up do
        # References a table that does not exist, so PostgreSQL rejects it.
        execute "ALTER TABLE no_such_table_here ADD COLUMN nope integer"
      end

      def down, do: :ok
    end
    """)

    original = Application.get_env(:triplex, :migrations_path)
    Application.put_env(:triplex, :migrations_path, name)

    try do
      fun.()
    after
      if original do
        Application.put_env(:triplex, :migrations_path, original)
      else
        Application.delete_env(:triplex, :migrations_path)
      end

      File.rm_rf!(dir)
    end
  end
end
