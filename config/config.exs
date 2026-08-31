# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :aims,
  ecto_repos: [Aims.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :aims, AimsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: AimsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Aims.PubSub,
  live_view: [signing_salt: "kJd9nhtH"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Triplex drives PostgreSQL schema-per-tenant: schema creation, drop, and the
# tenant migration line in priv/repo/tenant_migrations.
config :triplex,
  repo: Aims.Repo,
  tenant_prefix: "tenant_"

# Time handling has one rule: PostgreSQL stores UTC (every timestamp column is
# timestamptz), and the API renders in the tenant's zone as ISO 8601 *with an
# explicit offset* — "2026-08-28T19:15:38.123456+05:30". The offset in the
# string is what removes any ambiguity for a client.
#
# `tz` supplies the IANA database. It is used in preference to `tzdata` because
# tzdata pulls in hackney for auto-updates, and hackney currently carries four
# open CVEs including a HIGH.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :aims,
  # Fallback zone for platform-level responses, which belong to no tenant.
  default_time_zone: "Asia/Kolkata"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
