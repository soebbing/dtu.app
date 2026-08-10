defmodule DtuAppWeb.Router do
  use DtuAppWeb, :router

  import DtuAppWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DtuAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug DtuAppWeb.Plugs.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DtuAppWeb do
    pipe_through :browser

    get "/", PageController, :home

    # Legal / informational pages — no auth required, multilingual.
    get "/imprint", PageController, :imprint
    get "/privacy", PageController, :privacy
  end

  # Other scopes may use custom stacks.
  # scope "/api", DtuAppWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dtu_app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DtuAppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", DtuAppWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", DtuAppWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email

    # Web Push (VAPID) subscription endpoints. The browser-side
    # `PushSubscribe` JS hook hits these to register the service
    # worker's push subscription with the server. Auth-gated so
    # only the owner of the session can subscribe / unsubscribe
    # their own devices. CSRF is enforced via the standard
    # `X-CSRF-Token` header (the `:protect_from_forgery` plug from
    # the `:browser` pipeline); the JS hook reads the token from
    # the `<meta name="csrf-token">` element in the root layout.
    get "/push/vapid/public_key", PushController, :vapid_public_key
    post "/push/subscribe", PushController, :subscribe
    post "/push/unsubscribe", PushController, :unsubscribe

    live_session :current_scope,
      on_mount: [{DtuAppWeb.UserAuth, :mount_current_scope}, DtuAppWeb.Plugs.Locale] do
      live "/dashboard", DashboardLive, :index
      live "/devices", DeviceLive.Index, :index
      live "/devices/new", DeviceLive.Index, :new
      live "/devices/:id/edit", DeviceLive.Index, :edit
      # Notification preferences: opt in/out of browser notifications
      # for DTU connection state changes and the daily sun-down summary.
      # The page itself hosts the JS hook that requests permission and
      # fires the actual `new Notification(...)`.
      live "/notifications", NotificationsLive, :index
    end
  end

  scope "/", DtuAppWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
