defmodule Aims.Platform.TenantProfile do
  @moduledoc """
  The resolved configuration of one college, computed once at the edge of a
  request from its two flags.

  This is the mechanism the approved architecture prescribes in §20 to keep the
  four-way institution matrix out of the rest of the codebase. The rule it
  exists to enforce:

      Nothing below the resolver branches on `institution_type` or
      `autonomy_status`. Callers read a named feature flag.

  That discipline is what makes "an Arts & Science college that voluntarily
  adopted OBE" — which the source explicitly anticipates at p.2 and p.16 — a
  data change rather than a code change.

  The profile also carries `tenant_slug` (which schema to query) and `time_zone`
  (how to render timestamps back), so a request needs nothing else from the
  registry once it is resolved.
  """

  alias Aims.Platform.{Tenant, TenantSlug}

  @type feature ::
          :obe_mapping
          | :bos_curriculum_revision
          | :faculty_bos_participation
          | :value_added_30_hour_rule

  @type t :: %__MODULE__{
          tenant_id: integer(),
          institution_code: String.t(),
          institution_name: String.t(),
          institution_type: String.t(),
          autonomy_status: String.t(),
          tenant_slug: String.t(),
          schema_name: String.t(),
          time_zone: String.t(),
          criteria_scale: 100 | 150,
          experiential_variant: :industry | :field,
          features: %{feature() => boolean()}
        }

  @enforce_keys [
    :tenant_id,
    :institution_code,
    :institution_name,
    :institution_type,
    :autonomy_status,
    :tenant_slug,
    :schema_name,
    :time_zone,
    :criteria_scale,
    :experiential_variant,
    :features
  ]

  defstruct @enforce_keys

  @doc "Resolves a registry row into its immutable runtime profile."
  @spec for_tenant(Tenant.t()) :: t()
  def for_tenant(%Tenant{} = tenant) do
    %__MODULE__{
      tenant_id: tenant.id,
      institution_code: tenant.institution_code,
      institution_name: tenant.institution_name,
      institution_type: tenant.institution_type,
      autonomy_status: tenant.autonomy_status,
      tenant_slug: tenant.tenant_slug,
      schema_name: TenantSlug.to_schema(tenant.tenant_slug),
      time_zone: tenant.time_zone || Aims.Time.default_zone(),
      criteria_scale: criteria_scale(tenant.autonomy_status),
      experiential_variant: experiential_variant(tenant.institution_type),
      features: features(tenant)
    }
  end

  @doc """
  Whether a named capability is enabled for this college.

  The only sanctioned way for domain code to vary behaviour by institution.
  """
  @spec feature?(t(), feature()) :: boolean()
  def feature?(%__MODULE__{features: features}, feature) do
    Map.get(features, feature, false)
  end

  # Autonomy decides the marks. Source p.1, p.13, p.18: 100 affiliated, 150 autonomous.
  defp criteria_scale("AUTONOMOUS"), do: 150
  defp criteria_scale("AFFILIATED"), do: 100

  # Institution type decides the fields. Source p.6: engineering records an
  # industry mentor, arts & science a field site or community agency.
  defp experiential_variant("ENGINEERING"), do: :industry
  defp experiential_variant("ARTS_SCIENCE"), do: :field

  defp features(%Tenant{institution_type: type, autonomy_status: autonomy}) do
    %{
      # Source p.2, p.16: mandatory for engineering, optional for arts & science.
      # Modelled as a flag precisely so opting in later needs no code change.
      obe_mapping: type == "ENGINEERING",

      # Source p.12: an affiliated college does not design its own syllabus, so
      # BoS revision metrics are disabled for it.
      bos_curriculum_revision: autonomy == "AUTONOMOUS",

      # Source p.2, p.5: an affiliated college reports its faculty's
      # participation in the parent university's Board of Studies instead.
      faculty_bos_participation: autonomy == "AFFILIATED",

      # Source p.5, p.11: applies to all four configurations.
      value_added_30_hour_rule: true
    }
  end
end
