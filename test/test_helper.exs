# Ecto.Migrator loads migration files afresh on every run, and provisioning
# tests run the tenant migration set many times in one suite. Without this,
# each run emits a "redefining module" warning that drowns the real output.
Code.compiler_options(ignore_module_conflict: true)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Aims.Repo, :manual)
