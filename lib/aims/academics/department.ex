defmodule Aims.Academics.Department do
  @moduledoc """
  An organisational unit inside one college — "Department of Computer Science
  & Engineering".

  Lives in a **tenant schema**. There is deliberately no `tenant_id` field and
  no `@schema_prefix`: the prefix is supplied per query from
  `Aims.Tenancy.Context`, so the same struct serves every tenant and no query
  can accidentally omit tenant scoping and still succeed.

  A department owns both programmes and courses (decision D-06). Those arrive
  in Milestone 2.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "departments" do
    field :code, :string
    field :name, :string
    field :hod_user_id, :integer
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          code: String.t() | nil,
          name: String.t() | nil,
          hod_user_id: integer() | nil,
          is_active: boolean() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Changeset for creating or updating a department.

  Codes are upcased so that `cse` and `CSE` collide on the unique index rather
  than becoming two departments that look identical in every report.
  """
  def changeset(department, attrs) do
    department
    |> cast(attrs, [:code, :name, :hod_user_id, :is_active])
    |> validate_required([:code, :name])
    |> update_change(:code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:name, &String.trim/1)
    |> validate_length(:code, min: 1, max: 20)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_format(:code, ~r/\A[A-Z0-9][A-Z0-9_\-]*\z/,
      message: "may contain only letters, digits, hyphen and underscore"
    )
    |> unique_constraint(:code, name: :departments_code_index)
    |> check_constraint(:code, name: :departments_code_format, message: "is not a usable code")
  end
end
