defmodule Aims.Repo.TenantMigrations.CreateDepartments do
  use Ecto.Migration

  @moduledoc """
  `departments` — the first table of the Academic Structure context.

  Runs inside every tenant schema. Note what is absent: there is no `tenant_id`
  column. Isolation is the schema boundary itself (architecture NFR-04), which
  is why this migration is prefix-driven and carries no tenancy of its own.

  A department owns both programmes and courses (decision D-06). `head_user_id`
  is an unconstrained integer on purpose: identity lives in `public.users`, and
  foreign keys must never cross a schema boundary (architecture §7). It is
  resolved by the application, not by the database.
  """

  def up do
    create table(:departments) do
      add :code, :string, size: 20, null: false
      add :name, :string, size: 255, null: false
      add :head_user_id, :integer
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:departments, [:code])
    create index(:departments, [:is_active])

    create constraint(:departments, :departments_code_format,
             check: "code = btrim(code) AND length(code) > 0"
           )
  end

  def down do
    drop table(:departments)
  end
end
