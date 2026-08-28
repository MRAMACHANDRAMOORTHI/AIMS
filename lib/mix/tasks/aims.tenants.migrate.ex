defmodule Mix.Tasks.Aims.Tenants.Migrate do
  @shortdoc "Runs pending tenant migrations against every tenant schema"

  @moduledoc """
  Rolls the tenant migration line out to tenant schemas.

      mix aims.tenants.migrate                 # every serving tenant
      mix aims.tenants.migrate --tenant C-1234 # one tenant, by code
      mix aims.tenants.migrate --all-statuses  # include ARCHIVED / PROVISION_FAILED

  This is the counterpart to `mix ecto.migrate`, which handles `public` only.
  The two version lines are separate because they change for different reasons.

  Tenants are processed one at a time and independently: a failure is reported
  and the run continues, so one broken schema cannot strand the rest. Re-running
  is safe — a tenant already at the current version is a no-op — which is what
  makes an interrupted rollout resumable.
  """

  use Mix.Task

  alias Aims.Platform
  alias Aims.Platform.TenantMigrator

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [tenant: :string, all_statuses: :boolean],
        aliases: [t: :tenant]
      )

    # A CLI report should read as a report, not as a query log.
    Logger.configure(level: :info)

    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = Application.ensure_all_started(:aims)

    case opts[:tenant] do
      nil -> migrate_all(opts)
      code -> migrate_one(code)
    end
  end

  defp migrate_all(opts) do
    migrate_opts =
      if opts[:all_statuses] do
        [statuses: Aims.Platform.Tenant.statuses()]
      else
        []
      end

    latest = TenantMigrator.latest_version()
    Mix.shell().info("Tenant migration line is at version #{inspect(latest)}")

    %{ok: ok, failed: failed} = TenantMigrator.migrate_all(migrate_opts)

    Enum.each(ok, &Mix.shell().info("  ok      #{&1}"))

    Enum.each(failed, fn {code, reason} ->
      Mix.shell().error("  FAILED  #{code}: #{describe(reason)}")
    end)

    Mix.shell().info("\n#{length(ok)} migrated, #{length(failed)} failed")

    if failed != [], do: exit({:shutdown, 1})
  end

  defp migrate_one(code) do
    case Platform.fetch_tenant_by_code(code) do
      {:ok, tenant} ->
        case TenantMigrator.migrate(tenant) do
          {:ok, applied} ->
            Mix.shell().info(
              "ok  #{tenant.code} (#{tenant.schema_name}) — applied #{length(applied)} migration(s)"
            )

          {:error, reason} ->
            Mix.shell().error("FAILED #{tenant.code}: #{describe(reason)}")
            exit({:shutdown, 1})
        end

      {:error, :not_found} ->
        Mix.shell().error("No tenant with code #{inspect(code)}")
        exit({:shutdown, 1})
    end
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)
end
