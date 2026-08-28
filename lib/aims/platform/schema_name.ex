defmodule Aims.Platform.SchemaName do
  @moduledoc """
  Generation and validation of PostgreSQL schema identifiers for tenants.

  This module is a **security boundary**. Tenant schema names reach PostgreSQL
  as raw identifiers inside `CREATE SCHEMA` / `DROP SCHEMA` statements and as
  Ecto query prefixes. They can never be parameterised by the driver, so the
  only defence is that a name is impossible to construct unless it matches a
  deliberately narrow grammar.

  Grammar (mirrored by a CHECK constraint on `public.tenants.schema_name`):

      tenant_[a-z0-9_]{1,55}

  That admits lowercase letters, digits and underscore only. No quotes, no
  whitespace, no semicolons, no Unicode, no uppercase. PostgreSQL identifiers
  are capped at 63 bytes; the `tenant_` prefix plus 55 characters stays inside
  that limit with room to spare.

  Every call site that interpolates a schema name into SQL MUST route through
  `safe!/1` first.
  """

  @prefix "tenant_"
  @max_suffix 55
  @pattern ~r/\A#{@prefix}[a-z0-9_]{1,#{@max_suffix}}\z/

  # Schemas that must never be handed to a tenant, regardless of what the
  # grammar would otherwise permit.
  @reserved ~w(
    tenant_public tenant_information_schema tenant_pg_catalog
    tenant_pg_toast tenant_pg_temp tenant_template
  )

  @doc "The mandatory prefix for every tenant schema."
  def prefix, do: @prefix

  @doc "The regex every tenant schema name must satisfy."
  def pattern, do: @pattern

  @doc """
  Derives a schema name from a tenant code.

  Codes such as `"C-41207"` become `"tenant_c_41207"`. Returns
  `{:error, :underivable}` when nothing usable survives normalisation, rather
  than silently producing a degenerate name.
  """
  @spec derive(String.t()) :: {:ok, String.t()} | {:error, :underivable}
  def derive(code) when is_binary(code) do
    suffix =
      code
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @max_suffix)

    cond do
      suffix == "" -> {:error, :underivable}
      # A schema may not begin with a digit once the prefix is stripped in logs,
      # and a leading digit reads poorly; prefix it rather than reject it.
      String.match?(suffix, ~r/\A[0-9]/) -> {:ok, @prefix <> "x" <> suffix}
      true -> {:ok, @prefix <> suffix}
    end
  end

  def derive(_), do: {:error, :underivable}

  @doc "Returns true when `name` is a syntactically valid, non-reserved tenant schema."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) do
    String.match?(name, @pattern) and name not in @reserved
  end

  def valid?(_), do: false

  @doc """
  Returns the schema name unchanged, or raises.

  This is the guard that must wrap every interpolation of a schema name into
  SQL. It raises rather than returning an error tuple on purpose: reaching this
  function with an invalid identifier means a validated value was bypassed
  somewhere upstream, which is a bug and not a user error.
  """
  @spec safe!(term()) :: String.t()
  def safe!(name) do
    if valid?(name) do
      name
    else
      raise ArgumentError,
            "refusing to use #{inspect(name)} as a PostgreSQL schema identifier: " <>
              "it does not match #{inspect(Regex.source(@pattern))} or is reserved"
    end
  end
end
