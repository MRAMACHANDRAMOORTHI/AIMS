defmodule Aims.Time do
  @moduledoc """
  One rule for time, applied everywhere:

      PostgreSQL stores UTC.        Every timestamp column is `timestamptz`.
      Elixir holds UTC.             Every `DateTime` in the domain is UTC.
      The API renders local time.   ISO 8601 **with an explicit offset**.

  ## Why the offset matters more than the zone

  Returning `"2026-08-28T19:15:38.123456"` and telling clients "it's IST" is
  exactly the confusion this module exists to prevent — a client that assumes
  UTC is wrong by five and a half hours and nothing in the payload says so.

  Returning `"2026-08-28T19:15:38.123456+05:30"` cannot be misread. The offset
  travels with the value, every ISO 8601 parser in every language handles it,
  and `Date.parse()` in JavaScript produces the correct instant without the
  client knowing anything about India.

  ## Which zone is used

  Tenant-scoped responses render in **that college's** `time_zone` (default
  `Asia/Kolkata`). Platform-level responses — the tenant registry, health —
  belong to no college and use `config :aims, :default_time_zone`.

  Storing the zone per tenant rather than hardcoding IST costs nothing now and
  means a college in a different zone is a row change, not a code change.

  ## Never do the conversion by hand

  IST is a fixed +05:30 with no daylight saving, so `DateTime.add(dt, 19800)`
  looks tempting and would work today. It is still wrong to write: it silently
  produces a `DateTime` whose `time_zone` says "Etc/UTC" while its fields say
  something else, and it stops being correct the moment a non-IST tenant exists.
  Go through `shift/2`.
  """

  @default_zone "Asia/Kolkata"

  @doc "The platform's fallback zone, for responses that belong to no tenant."
  @spec default_zone() :: String.t()
  def default_zone, do: Application.get_env(:aims, :default_time_zone, @default_zone)

  @doc "Now, in UTC. The only way the application should read the clock."
  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.utc_now()

  @doc """
  Shifts a UTC `DateTime` into `zone`.

  Falls back to the original UTC value if the zone is unknown, rather than
  raising mid-render: a bad zone string in one tenant row should degrade that
  tenant's display, not fail the request. The fallback is still unambiguous
  because the rendered offset will read `+00:00`.
  """
  @spec shift(DateTime.t() | nil, String.t()) :: DateTime.t() | nil
  def shift(nil, _zone), do: nil

  def shift(%DateTime{} = datetime, zone) when is_binary(zone) do
    case DateTime.shift_zone(datetime, zone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  end

  @doc """
  Renders a UTC `DateTime` as ISO 8601 in `zone`, offset included.

      iex> Aims.Time.render(~U[2026-08-28 13:45:38.123456Z], "Asia/Kolkata")
      "2026-08-28T19:15:38.123456+05:30"

  `nil` renders as `nil` so optional timestamps serialise cleanly.
  """
  @spec render(DateTime.t() | nil, String.t()) :: String.t() | nil
  def render(nil, _zone), do: nil

  def render(%DateTime{} = datetime, zone) do
    datetime |> shift(zone) |> DateTime.to_iso8601()
  end

  @doc "Renders in the platform default zone. For responses with no tenant."
  @spec render(DateTime.t() | nil) :: String.t() | nil
  def render(datetime), do: render(datetime, default_zone())

  @doc """
  Whether `zone` is one the loaded time zone database recognises.

  Used to validate `tenants.time_zone` at write time, so an unusable zone is
  rejected on input rather than silently degrading every later response.
  """
  @spec valid_zone?(term()) :: boolean()
  def valid_zone?(zone) when is_binary(zone) do
    match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), zone))
  end

  def valid_zone?(_), do: false
end
