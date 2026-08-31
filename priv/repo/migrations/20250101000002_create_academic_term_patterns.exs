defmodule Aims.Repo.Migrations.CreateAcademicTermPatterns do
  use Ecto.Migration

  @moduledoc """
  `public.academic_term_patterns` — how many terms a programme runs per year.

  Renamed from `academic_patterns`: "pattern" alone did not say pattern *of
  what*. This table defines the **term** structure — SEMESTER is two terms a
  year, TRIMESTER three, ANNUAL one — and the name now says so.

  Lives in `public`, not in each tenant schema. The source seeded a copy per
  tenant (architecture contradiction C-11), which lets one college redefine
  SEMESTER as three terms and silently breaks every cross-tenant assumption.

  Tenant tables reference it by the stable string `code`, never by foreign key,
  because foreign keys must not cross a schema boundary.
  """

  def up do
    create table(:academic_term_patterns, primary_key: false) do
      add :code, :string, size: 20, primary_key: true
      add :name, :string, size: 50, null: false
      add :terms_per_year, :integer, null: false
    end

    create constraint(:academic_term_patterns, :academic_term_patterns_terms_per_year_range,
             check: "terms_per_year BETWEEN 1 AND 4"
           )

    execute """
    INSERT INTO academic_term_patterns (code, name, terms_per_year) VALUES
      ('SEMESTER',  'Semester System',  2),
      ('TRIMESTER', 'Trimester System', 3),
      ('ANNUAL',    'Annual System',    1)
    """
  end

  def down do
    drop table(:academic_term_patterns)
  end
end
