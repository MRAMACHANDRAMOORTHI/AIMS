defmodule Aims.Platform.AcademicTermPattern do
  @moduledoc """
  A term pattern: SEMESTER (2 terms/year), TRIMESTER (3) or ANNUAL (1).

  Lives in `public` rather than in each tenant schema. The source seeded these
  per tenant (p.26, p.41); the approved architecture moves them out
  (contradiction C-11) because they are platform-invariant, and a per-tenant
  copy lets one college redefine SEMESTER as three terms.

  Tenant tables reference this by `code`, never by foreign key — foreign keys
  must not cross a schema boundary (architecture §7).
  """

  use Ecto.Schema

  @primary_key {:code, :string, autogenerate: false}
  @derive {Jason.Encoder, only: [:code, :name, :terms_per_year]}

  schema "academic_term_patterns" do
    field :name, :string
    field :terms_per_year, :integer
  end

  @type t :: %__MODULE__{
          code: String.t() | nil,
          name: String.t() | nil,
          terms_per_year: pos_integer() | nil
        }

  @doc "How many terms a programme on this pattern runs per academic year."
  @spec terms_per_year(t()) :: pos_integer()
  def terms_per_year(%__MODULE__{terms_per_year: n}), do: n

  @doc """
  Total terms across a whole programme.

  The rule stated at source p.27: a 4-year semester programme has 8 terms.
  """
  @spec total_terms(t(), pos_integer()) :: pos_integer()
  def total_terms(%__MODULE__{terms_per_year: n}, duration_years)
      when is_integer(duration_years) and duration_years > 0 do
    n * duration_years
  end
end
