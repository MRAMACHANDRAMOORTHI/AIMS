defmodule AimsWeb.Router do
  use AimsWeb, :router

  # Platform-level. Operates on `public`; never resolves a tenant, because
  # provisioning a college cannot require that college to be resolvable.
  pipeline :platform_api do
    plug :accepts, ["json"]
  end

  # Tenant-scoped. Every request through here has a resolved, ACTIVE tenant
  # installed in the process context before it reaches a controller.
  pipeline :tenant_api do
    plug :accepts, ["json"]
    plug AimsWeb.Plugs.ResolveTenant
  end

  scope "/api/v1", AimsWeb do
    pipe_through :platform_api

    get "/health", PlatformController, :health
    get "/academic-patterns", PlatformController, :academic_patterns

    # Tenant management. `/tenants/migrations` is two segments and
    # `/tenants/:id/migrations` is three, so they cannot collide.
    get "/tenants", TenantController, :index
    post "/tenants", TenantController, :create
    post "/tenants/migrations", TenantController, :migrate_all

    get "/tenants/:id", TenantController, :show
    patch "/tenants/:id", TenantController, :update
    put "/tenants/:id", TenantController, :update
    delete "/tenants/:id", TenantController, :delete

    get "/tenants/:id/schema", TenantController, :schema_status
    post "/tenants/:id/migrations", TenantController, :migrate
    post "/tenants/:id/retry", TenantController, :retry
    post "/tenants/:id/suspend", TenantController, :suspend
    post "/tenants/:id/activate", TenantController, :activate
    post "/tenants/:id/archive", TenantController, :archive
  end

  scope "/api/v1", AimsWeb do
    pipe_through :tenant_api

    get "/tenant", TenantContextController, :show

    get "/departments", DepartmentController, :index
    post "/departments", DepartmentController, :create
    get "/departments/:id", DepartmentController, :show
    patch "/departments/:id", DepartmentController, :update
    put "/departments/:id", DepartmentController, :update
    post "/departments/:id/deactivate", DepartmentController, :deactivate
  end
end
