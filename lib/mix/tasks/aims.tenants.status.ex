defmodule Mix.Tasks.Aims.Tenants.Status do
  @shortdoc "Shows every tenant, its schema and its migration state"

  @moduledoc """
  Operational view of the tenant estate.

      mix aims.tenants.status

  Reports, per tenant, whether its PostgreSQL schema exists and how many tenant
  migrations are pending. Use it before and after a rollout, and to find
  tenants stranded in PROVISION_FAILED.
  """

  use Mix.Task

  alias Aims.Platform
  alias Aims.Platform.TenantMigrator

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    # A CLI report should read as a report, not as a query log.
    Logger.configure(level: :info)

    Mix.Task.run("app.start", ["--no-start"])
    {:ok, _} = Application.ensure_all_started(:aims)

    latest = TenantMigrator.latest_version()
    tenants = Platform.list_tenants()

    Mix.shell().info("Tenant migration line: #{inspect(latest)}")
    Mix.shell().info("Tenants: #{length(tenants)}\n")

    Mix.shell().info(
      String.pad_trailing("CODE", 14) <>
        String.pad_trailing("SCHEMA", 24) <>
        String.pad_trailing("STATUS", 18) <>
        String.pad_trailing("TYPE", 14) <>
        String.pad_trailing("AUTONOMY", 12) <>
        "MIGRATIONS"
    )

    Enum.each(tenants, fn tenant ->
      exists = TenantMigrator.schema_exists?(tenant)
      pending = if exists, do: TenantMigrator.pending_versions(tenant), else: [:all]

      migrations =
        cond do
          not exists -> "NO SCHEMA"
          pending == [] -> "up to date"
          true -> "#{length(pending)} pending"
        end

      Mix.shell().info(
        String.pad_trailing(tenant.institution_code, 14) <>
          String.pad_trailing(Aims.Platform.Tenant.schema_name(tenant), 24) <>
          String.pad_trailing(tenant.lifecycle_status, 18) <>
          String.pad_trailing(tenant.institution_type, 14) <>
          String.pad_trailing(tenant.autonomy_status, 12) <>
          migrations
      )
    end)
  end
end
