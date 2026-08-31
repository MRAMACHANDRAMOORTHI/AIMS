defmodule Aims.Repo.TenantMigrations.CreateDepartments do
  use Ecto.Migration

  @moduledoc """
  `departments` — the first table of the Academic Structure context.

  Runs inside every tenant schema, applied by Triplex. Note what is absent:
  there is no `tenant_id` column. Isolation is the schema boundary itself, which
  is why this migration is prefix-driven and carries no tenancy of its own.

  Column names are bare — `code`, `name` — because the table name already says
  what they describe. The `institution_*` prefixes on `public.tenants` exist
  only because that table is named for the platform concept, not the entity.

  A department owns both programmes and courses (decision D-06). Those arrive
  in Milestone 3.
  """

  def up do
    create table(:departments) do
      add :code, :string, size: 20, null: false
      add :name, :string, size: 255, null: false

      # Head of Department. Points at `public.users.id` and is deliberately not
      # a foreign key: identity lives in the public schema, and foreign keys
      # must never cross a schema boundary. Resolved by the application.
      add :hod_user_id, :integer

      add :is_active, :boolean, null: false, default: true

      timestamps(type: :timestamptz)
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
