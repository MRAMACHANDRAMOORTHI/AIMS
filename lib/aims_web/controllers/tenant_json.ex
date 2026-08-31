defmodule AimsWeb.TenantJSON do
  @moduledoc """
  Serialisation for colleges, profiles and provisioning state.

  Timestamps are rendered through `Aims.Time` in the **college's own** time
  zone, as ISO 8601 with an explicit offset. Listings and other platform-level
  views render in the platform default, because they span colleges and belong
  to none.
  """

  alias Aims.Platform.{Tenant, TenantProfile, TenantSlug}
  alias Aims.Time

  def index(%{tenants: tenants}) do
    %{data: for(tenant <- tenants, do: data(tenant))}
  end

  def show(%{tenant: tenant}) do
    %{data: data(tenant)}
  end

  @doc "The resolved college together with the configuration it drives."
  def context(%{tenant: tenant, profile: profile}) do
    %{data: Map.put(data(tenant), :profile, profile_data(profile))}
  end

  @doc "Provisioning and migration state of one college's PostgreSQL schema."
  def schema_status(%{tenant: tenant, exists: exists, applied: applied, pending: pending}) do
    %{
      data: %{
        tenant_id: tenant.id,
        institution_code: tenant.institution_code,
        tenant_slug: tenant.tenant_slug,
        schema_name: TenantSlug.to_schema(tenant.tenant_slug),
        lifecycle_status: tenant.lifecycle_status,
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
            %{institution_code: code, reason: describe(reason)}
          end),
        succeeded_count: length(ok),
        failed_count: length(failed)
      }
    }
  end

  def data(%Tenant{} = tenant) do
    zone = tenant.time_zone || Time.default_zone()

    %{
      id: tenant.id,
      institution_code: tenant.institution_code,
      institution_name: tenant.institution_name,
      institution_type: tenant.institution_type,
      autonomy_status: tenant.autonomy_status,
      affiliating_university: tenant.affiliating_university,
      tenant_slug: tenant.tenant_slug,
      schema_name: TenantSlug.to_schema(tenant.tenant_slug),
      lifecycle_status: tenant.lifecycle_status,
      time_zone: zone,
      inserted_at: Time.render(tenant.inserted_at, zone),
      updated_at: Time.render(tenant.updated_at, zone)
    }
  end

  def profile_data(%TenantProfile{} = profile) do
    %{
      criteria_scale: profile.criteria_scale,
      experiential_variant: profile.experiential_variant,
      time_zone: profile.time_zone,
      features: profile.features
    }
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(other), do: inspect(other)
end
