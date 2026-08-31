defmodule Aims.Platform.TenantSlug do
  @moduledoc """
  Derivation and validation of the Triplex tenant identifier.

  A slug is the part of a PostgreSQL schema name after Triplex's configured
  prefix: slug `"c_41207"` becomes schema `"tenant_c_41207"`.

  ## Division of labour with Triplex

  Triplex owns the *prefix* — `Triplex.to_prefix/1` — and the schema lifecycle.
  This module owns the *grammar*, and it stays ours on purpose: the slug reaches
  PostgreSQL inside `CREATE SCHEMA`, where no parameter binding exists, so it is
  the one identifier in the system that a validation gap turns into DDL
  injection. That guarantee is too important to inherit from a library's
  defaults.

  Grammar, mirrored by a CHECK constraint on `public.tenants.tenant_slug`:

      [a-z0-9_]{1,55}

  Lowercase letters, digits and underscore only. No quotes, whitespace,
  semicolons, Unicode or uppercase. PostgreSQL caps identifiers at 63 bytes;
  Triplex's `tenant_` prefix plus 55 characters stays inside that.

  Every call site that interpolates a slug or its schema into SQL must route
  through `safe!/1` first.
  """

  @max_length 55
  @pattern ~r/\A[a-z0-9_]{1,#{@max_length}}\z/

  # Names that must never become a tenant, whatever the grammar would allow.
  # Triplex keeps its own reserved list for the prefixed form; this guards the
  # slug before the prefix is applied.
  @reserved ~w(public information_schema pg_catalog pg_toast pg_temp template
               postgres admin api www app root)

  @doc "The regex every tenant slug must satisfy."
  def pattern, do: @pattern

  @doc "Maximum slug length, chosen so the prefixed schema fits in 63 bytes."
  def max_length, do: @max_length

  @doc """
  Derives a slug from an institution code.

  `"C-41207"` becomes `"c_41207"`. Returns `{:error, :underivable}` when nothing
  usable survives normalisation, rather than silently producing a degenerate
  identifier.
  """
  @spec derive(String.t()) :: {:ok, String.t()} | {:error, :underivable}
  def derive(institution_code) when is_binary(institution_code) do
    slug =
      institution_code
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_length)

    cond do
      slug == "" ->
        {:error, :underivable}

      # A leading digit reads poorly as an identifier and can confuse tooling
      # that expects a name; prefix it rather than reject an otherwise fine code.
      String.match?(slug, ~r/\A[0-9]/) ->
        {:ok, String.slice("x" <> slug, 0, @max_length)}

      true ->
        {:ok, slug}
    end
  end

  def derive(_), do: {:error, :underivable}

  @doc "Whether `slug` is syntactically valid, non-reserved, and safe for DDL."
  @spec valid?(term()) :: boolean()
  def valid?(slug) when is_binary(slug) do
    String.match?(slug, @pattern) and slug not in @reserved and
      not Triplex.reserved_tenant?(slug)
  end

  def valid?(_), do: false

  @doc """
  Returns the slug unchanged, or raises.

  Raises rather than returning an error tuple on purpose: reaching this function
  with an invalid identifier means a validated value was bypassed upstream,
  which is a bug, not a user error.
  """
  @spec safe!(term()) :: String.t()
  def safe!(slug) do
    if valid?(slug) do
      slug
    else
      raise ArgumentError,
            "refusing to use #{inspect(slug)} as a tenant slug: it does not match " <>
              "#{inspect(Regex.source(@pattern))}, or is reserved"
    end
  end

  @doc """
  The PostgreSQL schema name for a slug, via Triplex.

      iex> Aims.Platform.TenantSlug.to_schema("c_41207")
      "tenant_c_41207"

  Guarded, because the result is interpolated into DDL.
  """
  @spec to_schema(String.t()) :: String.t()
  def to_schema(slug), do: slug |> safe!() |> Triplex.to_prefix()
end
