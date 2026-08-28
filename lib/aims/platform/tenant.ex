defmodule Aims.Platform.Tenant do
  @moduledoc """
  A tenant is one atomic college.

  The approved architecture rules out mixed / multi-domain institutions
  (decision D-02, source p.11: "Mixed colleges will not happen as we onboard
  colleges not universities"). A tenant therefore maps to exactly one
  operational strategy, and `institution_type` has no `COMBINED` member.

  Lives in the `public` schema.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Aims.Platform.SchemaName

  @institution_types ~w(ENGINEERING ARTS_SCIENCE)
  @autonomy_statuses ~w(AFFILIATED AUTONOMOUS)
  @statuses ~w(PROVISIONING ACTIVE SUSPENDED ARCHIVED PROVISION_FAILED)

  @derive {Jason.Encoder,
           only: [
             :id,
             :code,
             :name,
             :schema_name,
             :institution_type,
             :autonomy_status,
             :affiliating_university,
             :status,
             :inserted_at,
             :updated_at
           ]}

  schema "tenants" do
    field :code, :string
    field :name, :string
    field :schema_name, :string
    field :institution_type, :string
    field :autonomy_status, :string
    field :affiliating_university, :string
    field :status, :string, default: "PROVISIONING"

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          code: String.t() | nil,
          name: String.t() | nil,
          schema_name: String.t() | nil,
          institution_type: String.t() | nil,
          autonomy_status: String.t() | nil,
          affiliating_university: String.t() | nil,
          status: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def institution_types, do: @institution_types
  def autonomy_statuses, do: @autonomy_statuses
  def statuses, do: @statuses

  @doc """
  Changeset for registering a new tenant.

  `schema_name` is derived from `code` rather than accepted from the caller.
  Letting a client choose its own PostgreSQL identifier would put an
  attacker-controlled string one validation bug away from DDL.
  """
  def create_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:code, :name, :institution_type, :autonomy_status, :affiliating_university])
    |> validate_required([:code, :name, :institution_type, :autonomy_status])
    |> update_change(:code, &String.trim/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:affiliating_university, &maybe_trim/1)
    |> validate_length(:code, min: 2, max: 50)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_inclusion(:institution_type, @institution_types)
    |> validate_inclusion(:autonomy_status, @autonomy_statuses)
    |> validate_affiliating_university()
    |> put_schema_name()
    |> put_change(:status, "PROVISIONING")
    |> unique_constraint(:code, name: :tenants_code_index)
    |> unique_constraint(:schema_name, name: :tenants_schema_name_index)
    |> check_constraint(:affiliating_university,
      name: :tenants_affiliation_required,
      message: "is required for an affiliated college"
    )
    |> check_constraint(:schema_name,
      name: :tenants_schema_name_format,
      message: "is not a usable PostgreSQL schema identifier"
    )
  end

  @doc """
  Changeset for editable tenant metadata.

  `code`, `schema_name`, `institution_type` and `autonomy_status` are absent by
  design. The first two are physical identity. The latter two are invariant
  I-40: changing them silently invalidates every historical metric, because a
  frozen report was assessed on a 100- or 150-mark scale that must not move
  under it. Changing them is a migration, not an edit.
  """
  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :affiliating_university])
    |> validate_required([:name])
    |> update_change(:name, &String.trim/1)
    |> update_change(:affiliating_university, &maybe_trim/1)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_affiliating_university()
    |> check_constraint(:affiliating_university,
      name: :tenants_affiliation_required,
      message: "is required for an affiliated college"
    )
  end

  @doc "Changeset for lifecycle transitions driven by the provisioner."
  def status_changeset(tenant, status) when status in @statuses do
    change(tenant, status: status)
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

  defp put_schema_name(%{valid?: false} = changeset), do: changeset

  defp put_schema_name(changeset) do
    case SchemaName.derive(get_field(changeset, :code)) do
      {:ok, schema_name} ->
        put_change(changeset, :schema_name, schema_name)

      {:error, :underivable} ->
        add_error(
          changeset,
          :code,
          "must contain at least one letter or digit to derive a schema name"
        )
    end
  end
end
