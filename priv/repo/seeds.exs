# Development seeds.
#
#     mix run priv/repo/seeds.exs
#
# Provisions two colleges that between them cover the institution matrix
# corners this milestone cares about, and gives each a department so tenant
# isolation is visible immediately.
#
# Idempotent: re-running skips colleges that already exist.

alias Aims.Academics
alias Aims.Platform
alias Aims.Tenancy.Context

require Logger

colleges = [
  %{
    "institution_code" => "C-41207",
    "institution_name" => "ABC Institute of Technology",
    "institution_type" => "ENGINEERING",
    "autonomy_status" => "AUTONOMOUS"
  },
  %{
    "institution_code" => "C-55891",
    "institution_name" => "St Xavier College of Arts and Science",
    "institution_type" => "ARTS_SCIENCE",
    "autonomy_status" => "AFFILIATED",
    "affiliating_university" => "University of Madras"
  }
]

departments = %{
  "C-41207" => [
    %{"code" => "CSE", "name" => "Department of Computer Science and Engineering"},
    %{"code" => "MAT", "name" => "Department of Mathematics"}
  ],
  "C-55891" => [
    %{"code" => "ENG", "name" => "Department of English Literature"},
    %{"code" => "COM", "name" => "Department of Commerce"}
  ]
}

for attrs <- colleges do
  tenant =
    case Platform.fetch_tenant_by_code(attrs["institution_code"]) do
      {:ok, existing} ->
        IO.puts(
          "· #{existing.institution_code} already exists (#{Aims.Platform.Tenant.schema_name(existing)})"
        )

        existing

      {:error, :not_found} ->
        {:ok, created} = Platform.create_tenant(attrs)

        IO.puts(
          "+ provisioned #{created.institution_code} into #{Aims.Platform.Tenant.schema_name(created)}"
        )

        created
    end

  profile = Platform.tenant_profile(tenant)

  Context.with_tenant(profile, fn ->
    for dept <- Map.fetch!(departments, tenant.institution_code) do
      case Academics.fetch_department_by_code(dept["code"]) do
        {:ok, _} ->
          :ok

        {:error, :not_found} ->
          {:ok, created} = Academics.create_department(dept)
          IO.puts("    + #{tenant.institution_code} / #{created.code}")
      end
    end
  end)
end

IO.puts("""

Seeded. Try:

  curl -H "x-tenant: C-41207" http://localhost:4000/api/v1/tenant
  curl -H "x-tenant: C-41207" http://localhost:4000/api/v1/departments
  curl -H "x-tenant: C-55891" http://localhost:4000/api/v1/departments
""")
