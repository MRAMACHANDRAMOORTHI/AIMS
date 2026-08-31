defmodule Aims.Platform.Tenant do
  @moduledoc """
  A tenant is one atomic college.

  The approved architecture rules out mixed institutions (decision D-02, source
  p.11: "Mixed colleges will not happen as we onboard colleges not
  universities"). A tenant therefore maps to exactly one operational strategy,
  and `institution_type` has no `COMBINED` member.

  Lives in the `public` schema. The `institution_*` prefixes are deliberate:
  the table is named for the platform concept, so the columns say which entity
  they describe.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Aims.Platform.TenantSlug

  @institution_types ~w(ENGINEERING ARTS_SCIENCE)
  @autonomy_statuses ~w(AFFILIATED AUTONOMOUS)
  @lifecycle_statuses ~w(PROVISIONING ACTIVE SUSPENDED ARCHIVED PROVISION_FAILED)

  schema "tenants" do
    field :institution_code, :string
    field :institution_name, :string
    field :institution_type, :string
    field :autonomy_status, :string
    field :affiliating_university, :string

    field :tenant_slug, :string
    field :lifecycle_status, :string, default: "PROVISIONING"
    field :time_zone, :string, default: "Asia/Kolkata"

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          institution_code: String.t() | nil,
          institution_name: String.t() | nil,
          institution_type: String.t() | nil,
          autonomy_status: String.t() | nil,
          affiliating_university: String.t() | nil,
          tenant_slug: String.t() | nil,
          lifecycle_status: String.t() | nil,
          time_zone: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def institution_types, do: @institution_types
  def autonomy_statuses, do: @autonomy_statuses
  def lifecycle_statuses, do: @lifecycle_statuses

  @doc "The PostgreSQL schema backing this tenant."
  @spec schema_name(t()) :: String.t()
  def schema_name(%__MODULE__{tenant_slug: slug}), do: TenantSlug.to_schema(slug)

  @doc """
  Changeset for registering a new college.

  `tenant_slug` is derived from `institution_code` rather than accepted from the
  caller. Letting a client choose its own PostgreSQL identifier would put an
  attacker-controlled string one validation bug away from DDL.
  """
  def create_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :institution_code,
      :institution_name,
      :institution_type,
      :autonomy_status,
      :affiliating_university,
      :time_zone
    ])
    |> validate_required([
      :institution_code,
      :institution_name,
      :institution_type,
      :autonomy_status
    ])
    |> update_change(:institution_code, &String.trim/1)
    |> update_change(:institution_name, &String.trim/1)
    |> update_change(:affiliating_university, &maybe_trim/1)
    |> validate_length(:institution_code, min: 2, max: 50)
    |> validate_length(:institution_name, min: 2, max: 255)
    |> validate_inclusion(:institution_type, @institution_types)
    |> validate_inclusion(:autonomy_status, @autonomy_statuses)
    |> validate_affiliating_university()
    |> validate_time_zone()
    |> put_tenant_slug()
    |> put_change(:lifecycle_status, "PROVISIONING")
    |> unique_constraint(:institution_code, name: :tenants_institution_code_index)
    |> unique_constraint(:tenant_slug, name: :tenants_tenant_slug_index)
    |> check_constraint(:affiliating_university,
      name: :tenants_affiliation_required,
      message: "is required for an affiliated college"
    )
    |> check_constraint(:tenant_slug,
      name: :tenants_slug_format,
      message: "is not a usable PostgreSQL schema identifier"
    )
  end

  @doc """
  Changeset for editable metadata.

  `institution_code`, `tenant_slug`, `institution_type` and `autonomy_status`
  are absent by design. The first two are physical identity. The latter two are
  invariant I-40: changing them silently invalidates every historical metric,
  because a frozen report was assessed on a 100- or 150-mark scale that must not
  move under it. Changing them is a migration, not an edit.

  `time_zone` is editable — it affects presentation only, never stored values.
  """
  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:institution_name, :affiliating_university, :time_zone])
    |> validate_required([:institution_name])
    |> update_change(:institution_name, &String.trim/1)
    |> update_change(:affiliating_university, &maybe_trim/1)
    |> validate_length(:institution_name, min: 2, max: 255)
    |> validate_affiliating_university()
    |> validate_time_zone()
    |> check_constraint(:affiliating_university,
      name: :tenants_affiliation_required,
      message: "is required for an affiliated college"
    )
  end

  @doc "Changeset for lifecycle transitions driven by the provisioner."
  def lifecycle_changeset(tenant, status) when status in @lifecycle_statuses do
    change(tenant, lifecycle_status: status)
  end

  defp maybe_trim(nil), do: nil
  defp maybe_trim(value) when is_binary(value), do: String.trim(value)
  defp maybe_trim(value), do: value

  # Mirrors the database CHECK so the caller gets a field error rather than a
  # constraint violation.
  defp validate_affiliating_university(changeset) do
    autonomy = get_field(changeset, :autonomy_status)
    university = get_field(changeset, :affiliating_university)

    if autonomy == "AFFILIATED" and (is_nil(university) or university == "") do
      add_error(changeset, :affiliating_university, "is required for an affiliated college")
    else
      changeset
    end
  end

  # Rejected on input rather than left to degrade every later response.
  defp validate_time_zone(changeset) do
    validate_change(changeset, :time_zone, fn :time_zone, zone ->
      if Aims.Time.valid_zone?(zone) do
        []
      else
        [time_zone: "is not a recognised IANA time zone, for example Asia/Kolkata"]
      end
    end)
  end

  defp put_tenant_slug(%{valid?: false} = changeset), do: changeset

  defp put_tenant_slug(changeset) do
    case TenantSlug.derive(get_field(changeset, :institution_code)) do
      {:ok, slug} ->
        put_change(changeset, :tenant_slug, slug)

      {:error, :underivable} ->
        add_error(
          changeset,
          :institution_code,
          "must contain at least one letter or digit to derive a tenant identifier"
        )
    end
  end
end
