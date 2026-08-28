defmodule Aims.Repo.Migrations.CreateAcademicPatterns do
  use Ecto.Migration

  @moduledoc """
  `public.academic_patterns` — delivery pattern reference data.

  The source placed this table inside every tenant schema and seeded it per
  tenant. The approved architecture moves it to `public` (contradiction C-11):
  it is platform-invariant reference data, and per-tenant copies let one college
  edit its own row so that SEMESTER means three terms, silently breaking every
  cross-tenant assumption.

  Tenant tables reference it by stable string `code`, never by foreign key,
  because foreign keys must not cross a schema boundary (architecture §7).
  """

  def up do
    create table(:academic_patterns, primary_key: false) do
      add :code, :string, size: 20, primary_key: true
      add :name, :string, size: 50, null: false
      add :terms_per_year, :integer, null: false
    end

    create constraint(:academic_patterns, :academic_patterns_terms_per_year_range,
             check: "terms_per_year BETWEEN 1 AND 4"
           )

    execute """
    INSERT INTO academic_patterns (code, name, terms_per_year) VALUES
      ('SEMESTER',  'Semester System',  2),
      ('TRIMESTER', 'Trimester System', 3),
      ('ANNUAL',    'Annual System',    1)
    """
  end

  def down do
    drop table(:academic_patterns)
  end
end
