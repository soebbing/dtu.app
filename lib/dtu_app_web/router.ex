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

  # Public (anonymous) browser pipeline. Identical to `:browser`
  # except:
  #
  #   * Uses the `root_public.html.heex` root layout — no navbar,
  #     no burger menu, no user dropdown (none of which apply to a
  #     share-link visitor anyway, and the `fetch_current_scope_for_user`
  #     in the standard browser pipeline would still try to read
  #     the session cookie even though the visit is anonymous).
  #   * Omits `fetch_current_scope_for_user` — the visitor has no
  #     account session, and `current_scope` is meaningless to the
  #     public LiveView.
  #
  # CSRF (`protect_from_forgery`) is kept so the LiveView's WS
  # upgrade still needs a valid token; Phoenix's standard
  # `phx-click` events go through the same CSRF check.
  pipeline :public_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DtuAppWeb.Layouts, :root_public}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug DtuAppWeb.Plugs.Locale
  end

  # Web Push (VAPID) HTTP endpoints. The browser-side `PushSubscribe`
  # JS hook issues `fetch(/, /push/...)` calls that send `Accept:
  # application/json`. The default `:browser` pipeline has
  # `plug :accepts, ["html"]`, which makes Phoenix content-negotiate
  # against the browser pipeline and reject JSON-accepting requests
  # with **406 Not Acceptable**. We reuse the browser session
  # (`:fetch_session`, `:fetch_current_scope_for_user`) and CSRF
  # (`:protect_from_forgery`) but accept JSON, so the same-origin
  # `fetch` from the JS hook gets a 200 response and never has to
  # deal with 406s.
  pipeline :push_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # WebAuthn / passkey ceremony endpoints. Same shape as `:push_api`
  # (JSON-accepting, CSRF-protected, session-fetching) but WITHOUT
  # `fetch_current_scope_for_user`: registration requires auth,
  # authentication requires anonymity, and reading the cookie ourselves
  # per action is clearer than a one-size-fits-all assign.
  #
  # The rate-limit plug sits between `:fetch_live_flash` and
  # `:protect_from_forgery` (spec §9). Placement matters:
  #   * AFTER `:fetch_session` is unnecessary — rate limit keys on
  #     `remote_ip`, not the user. Putting it earlier means CSRF-blocked
  #     requests still consume a quota slot, which is fine (an attacker
  #     sending cross-origin requests should still be throttled).
  #   * BEFORE `:protect_from_forgery` means the plug runs even when
  #     the request fails CSRF, so a flood of CSRF-bad requests still
  #     returns 429 (not 403) past the limit — spec §9 "rate limit
  #     per-action granularity" requires this.
  #   * BEFORE `:put_secure_browser_headers` means the plug can still
  #     set its own `put_status(:too_many_requests)` without the secure
  #     headers plug re-touching the response.
  #
  # The `:passkey_action` private key is set per-route (Task 5/6) so
  # the plug can apply a separate 10/min/IP counter per ceremony
  # endpoint instead of a single 10/min/IP bucket for all four. Falls
  # back to `"default"` when no route key is set, which is harmless.
  pipeline :passkey_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug DtuAppWeb.Plugs.PasskeyRateLimit
    plug :protect_from_forgery
    plug :put_secure_browser_headers
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

    live_session :current_scope,
      on_mount: [{DtuAppWeb.UserAuth, :mount_current_scope}, DtuAppWeb.Plugs.Locale] do
      live "/dashboard", DashboardLive, :index
      live "/devices", DeviceLive.Index, :index
      live "/devices/new", DeviceLive.Index, :new
      live "/devices/:id/edit", DeviceLive.Index, :edit
      # Live, in-browser view of every MQTT topic the device is
      # currently publishing on — see `DeviceLive.Details` for the
      # rationale on using a separate LV (vs. a new `:details`
      # action on `DeviceLive.Index`). Stays in the same
      # `live_session` so the existing `current_scope` + `Locale`
      # `on_mount` hooks continue to wire the user's session.
      live "/devices/:id/details", DeviceLive.Details, :index
      # Notification preferences: opt in/out of browser notifications
      # for DTU connection state changes and the daily sun-down summary.
      # The page itself hosts the JS hook that requests permission and
      # fires the actual `new Notification(...)`.
      live "/notifications", NotificationsLive, :index
    end
  end

  # Web Push (VAPID) subscription endpoints. The browser-side
  # `PushSubscribe` JS hook hits these to register the service
  # worker's push subscription with the server. Auth-gated so
  # only the owner of the session can subscribe / unsubscribe
  # their own devices. The `:push` pipeline accepts JSON (the
  # `:browser` pipeline's `accepts: ["html"]` rejects with **406
  # Not Acceptable**) and still enforces CSRF via the standard
  # `X-CSRF-Token` header — the JS hook reads the token from the
  # `<meta name="csrf-token">` element in the root layout.
  scope "/", DtuAppWeb do
    pipe_through [:push_api, :require_authenticated_user]

    get "/push/vapid/public_key", PushController, :vapid_public_key
    post "/push/subscribe", PushController, :subscribe
    post "/push/unsubscribe", PushController, :unsubscribe
  end

  # Passkey ceremony endpoints. The kill switch (`PASSKEYS_ENABLED`)
  # hides them; when disabled, every action returns 404 via the
  # controller-level `guard/2`.
  #
  # Each controller action sets `conn.private[:passkey_action]`
  # itself (via `Plug.Conn.put_private/3` as the first line of the
  # action body) so `DtuAppWeb.Plugs.PasskeyRateLimit` (running in
  # the `:passkey_api` pipeline) keys its 10/min/IP sliding window
  # on the specific ceremony. Per-route `plug :passkey_action, "<name>"`
  # would have been more declarative but `plug` only works inside a
  # pipeline in Phoenix, not at the route level — so the per-action
  # put_private is the working alternative. Without these keys the
  # plug falls back to `"default"`, which collapses all four
  # endpoints into a single bucket.
  scope "/", DtuAppWeb do
    pipe_through :passkey_api

    post "/auth/passkey/registration/begin", PasskeyController, :registration_options
    post "/auth/passkey/registration/finish", PasskeyController, :verify_registration
    post "/auth/passkey/authentication/begin", PasskeyController, :authentication_options
    post "/auth/passkey/authentication/finish", PasskeyController, :verify_authentication
  end

  # Passkey management endpoints (settings page). Standard browser
  # pipeline: form posts get the CSRF token from the layout and the
  # session cookie drives auth.
  scope "/", DtuAppWeb do
    pipe_through [:browser, :require_authenticated_user]

    post "/users/settings/passkeys/:id/delete", UserSettingsController, :delete_passkey
  end

  # CSV export of historical readings for a single DTU. Auth-gated so
  # only the device owner can pull raw data; ownership is re-checked
  # inside `DtuApp.Devices.stream_readings_for_export/4` so a probe
  # for someone else's dtu_id returns a header-only CSV rather than
  # leaking data (or a 404 with a side-channel observable). The
  # `:browser` pipeline (vs. `:push_api`'s JSON-accepting one) keeps
  # the controller on the same content-negotiation path as the rest
  # of the device pages; the browser sends `Accept: text/html, ...`
  # which `Plug.Conn.send_chunked/2` happily serves the
  # `text/csv` content-type through.
  scope "/", DtuAppWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/devices/:id/export.csv", DeviceExportController, :csv
  end

  scope "/", DtuAppWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Public share link. Resolved by `SharedDashboardLive.mount/3`
  # via `Accounts.get_user_by_share_token/1`, which hashes the URL
  # token and looks it up in `shared_links.token_hash`. No
  # `live_session` wraps this route on purpose — we don't want
  # `mount_current_scope` to run (it'd assign a nil scope and
  # render nothing); the public LiveView manages its own assigns.
  scope "/", DtuAppWeb do
    pipe_through :public_browser

    live "/s/:token", SharedDashboardLive, :index
  end
end
