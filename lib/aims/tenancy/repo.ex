defmodule Aims.Tenancy.Repo do
  @moduledoc """
  Repo operations bound to the current tenant's PostgreSQL schema.

  Every function here forwards to `Aims.Repo` with `prefix:` set from
  `Aims.Tenancy.Context`. Tenant-domain contexts call these instead of `Repo`
  directly, so no domain function ever takes a tenant argument.

  ## Why `prefix:` and not `SET LOCAL search_path`

  The architecture (§7) describes isolation as `SET LOCAL search_path` on the
  request transaction. This implementation uses Ecto's query prefix instead.
  It achieves the same isolation with a strictly stronger guarantee, and the
  difference is worth stating because it is a deliberate deviation:

    * **No ambient connection state.** `search_path` is a property of a pooled
      connection. Its safety depends on `SET LOCAL` and on every tenant query
      running inside a transaction. Miss either — a query outside a transaction,
      a `SET` where `SET LOCAL` was meant — and the next request on that
      connection silently reads another college's data. A prefix travels with
      the query, so there is no window in which a connection is mis-set.

    * **Explicit in the emitted SQL.** Queries compile to
      `SELECT ... FROM "tenant_abc"."departments"`, which is inspectable in
      logs and in `EXPLAIN`.

    * **Fails loudly.** With no tenant established, `fetch!/0` raises before SQL
      is built. Even if it did not, an unprefixed query would look for
      `public.departments`, which does not exist. The failure mode is an error,
      never a cross-tenant read.

    * **Native migrator support.** `Ecto.Migrator` takes the same `:prefix`,
      so provisioning and rollout use one mechanism rather than two.

  `search_path` is deliberately never set anywhere in this application. Mixing
  the two would reintroduce exactly the ambient state this avoids.
  """

  alias Aims.Repo
  alias Aims.Tenancy.Context

  @doc "The prefix option for the current tenant, for hand-written queries."
  @spec prefix() :: [prefix: String.t()]
  def prefix, do: [prefix: Context.schema!()]

  def all(queryable, opts \\ []), do: Repo.all(queryable, with_prefix(opts))

  def one(queryable, opts \\ []), do: Repo.one(queryable, with_prefix(opts))

  def get(queryable, id, opts \\ []), do: Repo.get(queryable, id, with_prefix(opts))

  def get!(queryable, id, opts \\ []), do: Repo.get!(queryable, id, with_prefix(opts))

  def get_by(queryable, clauses, opts \\ []),
    do: Repo.get_by(queryable, clauses, with_prefix(opts))

  def aggregate(queryable, aggregate, opts \\ []),
    do: Repo.aggregate(queryable, aggregate, with_prefix(opts))

  def exists?(queryable, opts \\ []), do: Repo.exists?(queryable, with_prefix(opts))

  def insert(struct_or_changeset, opts \\ []),
    do: Repo.insert(put_struct_prefix(struct_or_changeset), opts)

  def update(changeset, opts \\ []), do: Repo.update(put_struct_prefix(changeset), opts)

  def delete(struct_or_changeset, opts \\ []),
    do: Repo.delete(put_struct_prefix(struct_or_changeset), opts)

  def insert_all(schema, entries, opts \\ []),
    do: Repo.insert_all(schema, entries, with_prefix(opts))

  def delete_all(queryable, opts \\ []), do: Repo.delete_all(queryable, with_prefix(opts))

  def update_all(queryable, updates, opts \\ []),
    do: Repo.update_all(queryable, updates, with_prefix(opts))

  def transaction(fun_or_multi, opts \\ []), do: Repo.transaction(fun_or_multi, opts)

  # Queries take the prefix as an option; a caller-supplied one wins so that
  # deliberate cross-schema work (the provisioner, the migrator) stays possible.
  defp with_prefix(opts) do
    Keyword.put_new_lazy(opts, :prefix, &Context.schema!/0)
  end

  # Structs and changesets carry their prefix in metadata rather than in opts.
  defp put_struct_prefix(%Ecto.Changeset{} = changeset) do
    if Ecto.get_meta(changeset.data, :prefix) do
      changeset
    else
      %{changeset | data: Ecto.put_meta(changeset.data, prefix: Context.schema!())}
    end
  end

  defp put_struct_prefix(%{__meta__: %Ecto.Schema.Metadata{}} = struct) do
    if Ecto.get_meta(struct, :prefix) do
      struct
    else
      Ecto.put_meta(struct, prefix: Context.schema!())
    end
  end
end
