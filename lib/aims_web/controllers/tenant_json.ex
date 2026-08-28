defmodule AimsWeb.TenantJSON do
  @moduledoc "Serialisation for tenants, profiles and provisioning state."

  alias Aims.Platform.{Tenant, TenantProfile}

  def index(%{tenants: tenants}) do
    %{data: for(tenant <- tenants, do: data(tenant))}
  end

  def show(%{tenant: tenant}) do
    %{data: data(tenant)}
  end

  @doc "The resolved tenant together with the configuration it drives."
  def context(%{tenant: tenant, profile: profile}) do
    %{data: Map.put(data(tenant), :profile, profile_data(profile))}
  end

  @doc "Provisioning and migration state of one tenant's PostgreSQL schema."
  def schema_status(%{tenant: tenant, exists: exists, applied: applied, pending: pending}) do
    %{
      data: %{
        tenant_id: tenant.id,
        tenant_code: tenant.code,
        schema_name: tenant.schema_name,
        status: tenant.status,
        schema_exists: exists,
        applied_versions: applied,
        pending_versions: pending,
        up_to_date: pending == []
      }
    }
  end

  @doc "Outcome of a tenant-migration rollout."
  def migration_result(%{ok: ok, failed: failed}) do
    %{
      data: %{
        migrated: ok,
        failed:
          Enum.map(failed, fn {code, reason} ->
            %{tenant_code: code, reason: describe(reason)}
          end),
        succeeded_count: length(ok),
        failed_count: length(failed)
      }
    }
  end

  def data(%Tenant{} = tenant) do
    %{
      id: tenant.id,
      code: tenant.code,
      name: tenant.name,
      schema_name: tenant.schema_name,
      institution_type: tenant.institution_type,
      autonomy_status: tenant.autonomy_status,
      affiliating_university: tenant.affiliating_university,
      status: tenant.status,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }
  end

  def profile_data(%TenantProfile{} = profile) do
    %{
      criteria_scale: profile.criteria_scale,
      experiential_variant: profile.experiential_variant,
      features: profile.features
    }
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)
end
