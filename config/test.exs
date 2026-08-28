import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :aims, Aims.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "aims_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Tenant provisioning runs Ecto.Migrator inside a test that is itself wrapped
  # in a sandbox transaction. The migrator's advisory lock is taken on a
  # separate connection and would deadlock against that transaction, so it is
  # disabled here. It stays enabled in dev and prod, where concurrent rollouts
  # are a real possibility.
  migration_lock: nil

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aims, AimsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yoP0m269cNEo8s9Z9kMbYX6MulAB3SRJZAzcj/nQCwi2LVsV3aqepzaCFBVQY9Uk",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
