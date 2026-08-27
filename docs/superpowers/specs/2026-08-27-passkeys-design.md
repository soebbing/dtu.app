# Passkey / WebAuthn authentication

**Status:** Approved design
**Branch:** TBD — split into four PRs (`#1` schema, `#2` controller, `#3` UI, `#4` e2e)
**Date:** 2026-08-27
**Calver tag:** TBD on merge

## 1. Problem

Today the app offers two credentials per user: an Argon2 password and a magic
link. Passwords are vulnerable to phishing and reuse; magic links require an
inbox and a click. WebAuthn / FIDO2 passkeys (Touch ID, Face ID, Windows
Hello, hardware security keys) are phishing-resistant by construction, faster
than typing a password, and work offline once enrolled.

We want passkeys as an **additive** credential. Existing passwords and magic
links stay — they are the fallback if a user loses every enrolled passkey.
The login page should also support **conditional mediation** so a returning
user with a passkey sees a one-click autofill instead of the email + password
form.

## 2. Goals & non-goals

**Goals**

- Passkey enrolment from `/users/settings`, requiring an authenticated session.
- Passkey authentication from `/users/log-in`, with conditional-mediation autofill
  on page load.
- Each user may enrol multiple passkeys (one per device / authenticator), each
  with a friendly name.
- Existing auth paths (Argon2 password, magic link) remain unchanged and are
  the recovery story for a user who loses every enrolled passkey.
- Origin verification, sign-counter monotonicity, challenge one-shot semantics,
  per-IP rate limiting on the ceremony endpoints.
- The feature ships behind a `PASSKEYS_ENABLED` kill switch, held for 24 h
  in production before being flipped on.

**Non-goals**

- Removing passwords or magic links.
- Cross-device "hybrid" transport flows (Bluetooth phone → laptop) — we get
  them transparently via the browser but do not test them in CI.
- Server-side attestation verification strict mode — the `webauthn` library
  handles that and we trust its tests.
- Per-event or per-page passkey enforcement. Passkey login is opt-in by the
  browser; we cannot force a user to use it.
- Recovery codes. Magic link is the recovery path.

## 3. UX

### Login page — `lib/dtu_app_web/controllers/user_session_html/`

A new section appears above the existing email + password form:

```
┌──────────────────────────────────────────────────────────┐
│  Sign in                                                │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ 🔑  Use a passkey                            [→]  │ │   ← conditional-mediation autofill target
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ──────── or use email + password ────────              │
│                                                          │
│  Email      [____________________________]               │
│  Password   [____________________________]               │
│  [ ] Remember me                                          │
│                                       [Log in]          │
│                                                          │
│  ──────── or email me a sign-in link ────────            │
│  Email      [____________________________]               │
│                                       [Email me]        │
└──────────────────────────────────────────────────────────┘
```

Behaviour:

- `PasskeyFlow` JS hook fires `navigator.credentials.get({publicKey, mediation: "conditional"})`
  on page load, immediately after the `authentication_options` response arrives.
  If the user has a passkey for this RP, the browser shows an autofill chip.
  One click → passkey login.
- "Use a passkey" button is the explicit fallback for browsers that don't
  surface conditional UI. Same endpoint, no `mediation` flag.
- Button is disabled ("Loading…") until the `authentication_options` request
  resolves.
- Any 4xx from `finish` shows an inline error and re-enables the button.
  **No** flash error, **no** email-enumeration hint.
- The new section is hidden when `Application.get_env(:dtu_app, :passkeys_enabled, true)`
  is `false` (kill switch).

### Settings page — `lib/dtu_app_web/controllers/user_settings_html/`

A "Passkeys" card appears above the existing settings form:

```
┌──────────────────────────────────────────────────────────┐
│  Passkeys                                                │
│                                                          │
│  Sign in faster on this device and others.               │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ MacBook Touch ID          Last used 2 hours ago   │ │
│  │                                     [Remove]      │ │
│  ├────────────────────────────────────────────────────┤ │
│  │ iPhone 15                 Last used yesterday     │ │
│  │                                     [Remove]      │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  Friendly name: [____________________________]          │
│                                       [Add a passkey]   │
│                                                          │
│  No passkeys yet? Add one to skip the password next time.│
└──────────────────────────────────────────────────────────┘
```

Behaviour:

- Empty-state copy ("No passkeys yet…") shown only when the user has zero
  enrolled passkeys.
- Add flow: type friendly name (placeholder "This device"), click "Add a
  passkey" → `registration/begin` → browser's OS prompt → `registration/finish`
  → reload to show the new row. Errors stay inline; friendly name preserved.
- Remove flow: a non-JS `<details>` confirmation that posts to
  `/users/settings/passkeys/:id/delete` with the standard CSRF token.
  Success flash: "Passkey removed".
- Last-used display uses relative time for < 24 h, absolute date otherwise.

### The JS hook — `assets/js/hooks/passkey_flow.js`

Single colocated hook, registered with `phx-hook=".PasskeyFlow"`. Two
instances on the settings page (one for "add", one for "remove"; "remove"
is non-JS so just the add hook runs). One instance on the login page.

The hook handles:

- `mounted()` — read `data-kind` attribute (`"registration"` or
  `"authentication"`), pick up the CSRF token from the root layout's
  `<meta name="csrf-token">`, bind buttons, fire conditional mediation
  for the authentication kind.
- `start()` — POST to `begin`, decode base64url → ArrayBuffer, call
  `navigator.credentials.create/get`, POST to `finish`, on success either
  follow the server's `redirect` (auth) or `location.reload()` (registration).
- `fireConditionalMediation()` — non-awaited
  `navigator.credentials.get({mediation: "conditional"})` so the browser can
  autofill the email field. If the user picks an autofilled passkey,
  `completeConditional(cred)` reuses the same `request_id` from the original
  `begin` response and posts to `finish`.
- User-cancelled authenticator dialogs → caught, mapped to `"user_cancelled"`,
  no error toast shown.

## 4. Architecture & components

Three new pieces plus changes to two existing ones.

### New pieces

1. **`DtuApp.Accounts.Passkey`** (`lib/dtu_app/accounts/passkey.ex`)
   Ecto schema for the `passkeys` table. Owns the credential public key,
   sign counter, friendly name, transports, and timestamps. Has two changesets:
   `registration_changeset/2` (write path) and `usage_changeset/2` (sign_count
   + last_used_at bumps with strict-greater-than enforcement).

2. **`DtuApp.Accounts.PasskeyChallengeCache`** (`lib/dtu_app/accounts/passkey_challenge_cache.ex`)
   GenServer-backed ETS table keyed by 32-hex-char `request_id`. Stores
   `{challenge_bytes, user_id, kind, friendly_name, inserted_at}`. Public API:
   `put/2`, `fetch_and_delete/1`. Sweeps on every `put` to TTL-prune entries
   older than 5 minutes. Supervised under `DtuApp.Application`.

3. **`DtuAppWeb.PasskeyController`** (`lib/dtu_app_web/controllers/passkey_controller.ex`)
   Phoenix controller with four actions: `registration_options`,
   `verify_registration`, `authentication_options`, `verify_authentication`.
   All JSON in/out. Mounts in a new `:passkey_api` pipeline (see §6).

### Changed pieces

4. **`DtuAppWeb.UserAuth`** (`lib/dtu_app_web/user_auth.ex`)
   New helper `log_in_user_from_passkey/2`. Thin wrapper around the existing
   session-mint path; identical semantics to the password / magic-link paths.

5. **`DtuAppWeb.UserSessionController`** (`lib/dtu_app_web/controllers/user_session_controller.ex`)
   `create/2` learns a fifth pattern clause for
   `%{"user" => %{"passkey_assertion" => %{...}}}` (the JSON body from
   `PasskeyFlow`).

6. **`DtuAppWeb.UserSettingsController`** (`lib/dtu_app_web/controllers/user_settings_controller.ex`)
   New action `:add_passkey` (renders the settings page with the
   `PasskeyFlow` hook mounted) and `:delete_passkey` (form post → 302).

### What does NOT change

- `users` table — no migration.
- `user_tokens` table — passkey logins mint the same session tokens.
- `SharedLink` / `SharedDashboardLive` — passkeys never appear on the public
  share dashboard.

## 5. Data model

### Migration: `priv/repo/migrations/<timestamp>_create_passkeys.exs`

```elixir
defmodule DtuApp.Repo.Migrations.CreatePasskeys do
  use Ecto.Migration

  def change do
    create table(:passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      # Opaque browser-chosen identifier; base64url-encoded at the wire
      # boundary so the browser can match it in `allowCredentials`.
      add :credential_id, :binary, null: false

      # COSE-encoded public key returned by the authenticator.
      add :public_key, :binary, null: false

      # Monotonic counter the authenticator increments on each
      # assertion. Verified strict-greater-than on every login.
      add :sign_count, :integer, null: false, default: 0

      # COSE algorithm identifier (-7 ES256, -257 RS256, …).
      add :alg, :integer, null: false

      # JSON-encoded array of transport hints (e.g. ["usb", "internal"]).
      add :transports, :text, default: "[]"

      add :friendly_name, :string, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:passkeys, [:credential_id])
    create index(:passkeys, [:user_id])
  end
end
```

`binary_id` matches the rest of the app (`users.id` is `:binary_id`).
`transports` is text because it's small, read-only after enrolment, and never
queried inside. No forensic columns (`last_used_ip`, etc.).

### Schema: `lib/dtu_app/accounts/passkey.ex`

```elixir
defmodule DtuApp.Accounts.Passkey do
  use Ecto.Schema
  import Ecto.Changeset

  alias DtuApp.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "passkeys" do
    belongs_to :user, User, type: :binary_id

    field :credential_id, :binary
    field :public_key,    :binary
    field :sign_count,    :integer, default: 0
    field :alg,           :integer
    field :transports,    {:array, :string}, default: []
    field :friendly_name, :string
    field :last_used_at,  :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @max_name_length 60

  def registration_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :alg, :transports, :friendly_name])
    |> validate_required([:user_id, :credential_id, :public_key, :alg, :friendly_name])
    |> validate_length(:friendly_name, min: 1, max: @max_name_length)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:credential_id)
  end

  def usage_changeset(passkey, attrs) do
    passkey
    |> cast(attrs, [:sign_count, :last_used_at])
    |> validate_required([:sign_count, :last_used_at])
    |> validate_number(:sign_count, greater_than: passkey.sign_count)
  end
end
```

## 6. HTTP endpoints & ceremony flow

### Pipeline: `:passkey_api`

```elixir
pipeline :passkey_api do
  plug :accepts, ["json"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end
```

Same shape as the existing `:push_api`, minus `fetch_current_scope_for_user`
— registration requires auth, authentication requires anonymity, so the
controller reads the session manually per action.

### Routes

```elixir
scope "/", DtuAppWeb do
  pipe_through :passkey_api

  # Registration — both actions require an authenticated session.
  post "/auth/passkey/registration/begin",   PasskeyController, :registration_options
  post "/auth/passkey/registration/finish",  PasskeyController, :verify_registration

  # Authentication — both actions require an anonymous session.
  post "/auth/passkey/authentication/begin",  PasskeyController, :authentication_options
  post "/auth/passkey/authentication/finish", PasskeyController, :verify_authentication
end

# Passkey management endpoints (settings page). These go through the
# standard browser pipeline so the form posts get the CSRF token from
# the layout and the session cookie drives auth.
scope "/", DtuAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  post "/users/settings/passkeys/:id/delete", UserSettingsController, :delete_passkey
end
```

### Per-action contracts

#### `POST /auth/passkey/registration/begin` *(requires auth)*

Request body:

```json
{ "friendly_name": "MacBook Touch ID" }
```

Server:

1. Read user from `Accounts.get_user_by_session_token/1`. 401 if missing.
2. List the user's existing passkeys via `Accounts.list_passkeys/1`; build
   `excludeCredentials` from their base64url-encoded `credential_id`s.
3. Call `WebAuthn.API.start_challenge(%{...})`. Returns the WebAuthn
   `publicKey` JSON options.
4. Generate `request_id` (16 random bytes, hex).
5. `PasskeyChallengeCache.put(request_id, {challenge, user.id, :registration, friendly_name})`.
6. Set a signed cookie `passkey_request_id` (HttpOnly, SameSite=Lax, 5-min
   Max-Age) carrying the same `request_id`.
7. Return 200 with `{ request_id, publicKey }`.

#### `POST /auth/passkey/registration/finish` *(requires auth)*

Request body:

```json
{
  "request_id": "ab12cd34…",
  "attestation_response": { /* full PublicKeyCredential */ }
}
```

Server:

1. Read user, read `passkey_request_id` cookie, validate they match the body's
   `request_id`. 400 if not (CSRF replay protection).
2. `PasskeyChallengeCache.fetch_and_delete(request_id)` →
   `{:registration, challenge, user_id, friendly_name}`. 400
   `challenge_expired` on miss.
3. Call `WebAuthn.API.complete_challenge(%{...})`. On library error →
   `verification_failed` → 400.
4. `Accounts.create_passkey(%{...})`. The unique index on `credential_id`
   maps a duplicate authenticator to 409 `credential_already_enrolled`.
5. Return 201 `{ passkey_id, friendly_name }`.

#### `POST /auth/passkey/authentication/begin` *(requires anonymity)*

Request body: `{}`.

Server:

1. Reject 409 if a session cookie is present.
2. `WebAuthn.API.start_authentication(%{...})`. `allowCredentials: []`
   (conditional-mediation probe — the browser picks which enrolled passkey
   to use).
3. Same `request_id` / cookie / response shape as the registration begin.

#### `POST /auth/passkey/authentication/finish` *(requires anonymity)*

Request body:

```json
{
  "request_id": "ab12cd34…",
  "assertion_response": { /* full PublicKeyCredential */ }
}
```

Server:

1. Reject 409 if session cookie present.
2. `fetch_and_delete` → `{:authentication, challenge, nil, _}`. 400 on miss.
3. Decode `response.id` (base64url → bytes) and look up the matching passkey
   via `Accounts.find_passkey_by_credential_id/1`. 401 `credential_not_found`
   on miss.
4. `WebAuthn.API.complete_authentication(%{...})`. Returns new `sign_count`.
5. `Accounts.touch_passkey(passkey, %{sign_count: new, last_used_at: now})`.
   The `usage_changeset` validates `new > passkey.sign_count` so a replay
   attempt fails the changeset and we 401.
6. `UserAuth.log_in_user_from_passkey(conn, passkey.user)`.
7. Return 200 `{ redirect: "/" }`.

## 7. Challenge cache

`DtuApp.Accounts.PasskeyChallengeCache` — GenServer with `:protected` ETS
table, single app-wide instance, supervised under `DtuApp.Application`.

| Failure mode | What happens | What we do |
|--------------|--------------|------------|
| Same `request_id` reused | Replay attempt | `fetch_and_delete/1` already removed it → `{:error, :not_found}` → 400 |
| Expired `request_id` | User walked away 6+ min | TTL sweep deleted it → 400 `challenge_expired` |
| Two parallel browsers | User opens two tabs | Each `begin` sets its own `request_id` cookie; older tab's `finish` fails cookie-mismatch (400) |
| App restart mid-ceremony | Deploy during in-flight ceremony | ETS empty → 400 `challenge_expired` |
| Bot spam | Millions of `request_id`s | TTL + per-`put` sweep bounds memory; per-IP rate limit (see §9) caps new entries |
| GenServer crash | Restart, ETS empty | All in-flight challenges lost → 400 `challenge_expired` on next click |

## 8. Origin verification

Every `finish` action calls `request_origin(conn)` which reads
`conn.assigns[:origin]` (set by `protect_from_forgery`) and reconstructs the
origin URL. The `webauthn` library compares this against the `rp_id` from
configuration. A mismatch → `verification_failed` → 400.

```elixir
defp request_origin(conn) do
  case conn.assigns[:origin] do
    %{scheme: scheme, host: host, port: port} ->
      "#{scheme}://#{host}#{if port, do: ":#{port}", else: ""}"
    _ -> raise "no origin on request — pipeline misconfigured"
  end
end
```

## 9. Rate limiting

`DtuAppWeb.Plugs.PasskeyRateLimit` — sliding-window 10/min/IP/action using
ETS. Runs as the first plug after `:passkey_api` is established. Returns
429 with `{ error: "too_many_attempts" }` on overflow.

## 10. Error → HTTP mapping

```elixir
defp handle_passkey_error(conn, reason) do
  case reason do
    :challenge_expired    -> json(conn, 400, %{error: "challenge_expired"})
    :origin_mismatch      -> json(conn, 400, %{error: "origin_mismatch"})
    :verification_failed  -> json(conn, 400, %{error: "verification_failed"})
    :credential_not_found -> json(conn, 401, %{error: "credential_not_found"})
    :credential_enrolled  -> json(conn, 409, %{error: "credential_already_enrolled"})
    :rate_limited         -> json(conn, 429, %{error: "too_many_attempts"})
  end
end
```

The `webauthn` library errors get translated through `wrap_webauthn_result/1`
so no library-specific strings leak to the browser.

## 11. Configuration

```elixir
# config/runtime.exs
config :dtu_app, :webauthn_rp_id,
  case System.get_env("WEBAUTHN_RP_ID") do
    nil -> "localhost"
    ""   -> "localhost"
    val -> val
  end

config :dtu_app, :webauthn_rp_name,
  System.get_env("WEBAUTHN_RP_NAME") || "dtu.app"

config :dtu_app, :passkeys_enabled,
  System.get_env("PASSKEYS_ENABLED") != "false"
```

Per-environment:

| Env | `WEBAUTHN_RP_ID` | `WEBAUTHN_RP_NAME` | `PASSKEYS_ENABLED` |
|-----|------------------|---------------------|---------------------|
| dev | `localhost` | `dtu.app` | `true` |
| test | `localhost` | `dtu.app` | `true` |
| prod | `dtu.app` | `dtu.app` | `false` for 24 h, then `true` |

The kill switch hides:

1. The `PasskeyController` actions (404 when disabled).
2. The login page's passkey section (`<%= if Application.get_env(:dtu_app, :passkeys_enabled, true) do %>`).
3. The settings page's passkey card (same conditional).

The cache, schema, and routes are always present.

## 12. Testing strategy

### Layer 1 — schema unit tests

`test/dtu_app/accounts/passkey_test.exs` (~50 lines): required fields,
friendly-name length bounds, unique `credential_id`, strict-greater-than
`sign_count` enforcement.

### Layer 2 — cache unit tests

`test/dtu_app/accounts/passkey_challenge_cache_test.exs`: round-trip,
one-shot `fetch_and_delete`, TTL pruning via env override.

### Layer 3 — controller tests

`test/dtu_app_web/controllers/passkey_controller_test.exs` using a
`PasskeyTest.Authenticator` helper that wraps `webauthn`'s test signing
utilities to produce valid attestation / assertion responses without a real
authenticator. Coverage per action:

- `registration/begin` — 401 unauth, 200 with options, `excludeCredentials`
  lists existing passkeys, cookie set, 429 on rate limit.
- `registration/finish` — 201 + row created on success, 400
  `challenge_expired`, 400 `origin_mismatch`, 409 on duplicate
  `credential_id`, 401 unauth.
- `authentication/begin` — 409 when authenticated, 200 with options,
  `allowCredentials: []`.
- `authentication/finish` — 200 + login, 401 `credential_not_found`, 401
  when `sign_count` doesn't increase, 400 `challenge_expired`, 409 when
  authenticated.

### Layer 4 — Playwright e2e

`test/e2e/passkey_login.spec.js` uses Chromium's CDP `WebAuthn.enable` +
`WebAuthn.addVirtualAuthenticator` to register a software authenticator at
test start. Three tests:

1. Enroll a passkey, log out, log back in with it (via the explicit button —
   conditional mediation is unreliable in headless).
2. Failed passkey authentication falls back to email + password.
3. Removing a passkey makes it unusable for the next login.

A `_helpers.js` utility wraps the virtual-authenticator setup / teardown so
the tests don't duplicate CDP boilerplate.

### What we deliberately don't test

- Cross-device hybrid transport (needs two virtual authenticators).
- Attestation strict-mode verification (handled by the `webauthn` lib).
- CSRF rejection (already exercised on every other controller in this app).

## 13. Rollout

4-PR split, each landing on `main` independently:

1. **PR1:** Migration + `Passkey` schema + `PasskeyChallengeCache`. CI green,
   no UI changes.
2. **PR2:** `PasskeyController` + `:passkey_api` pipeline + routes. Controller
   returns 404 unless `PASSKEYS_ENABLED=true`.
3. **PR3:** `PasskeyFlow` JS hook + login page section + settings page section.
4. **PR4:** Playwright virtual-authenticator e2e tests.

Deploy sequence with `PASSKEYS_ENABLED=false`:

1. `mix ecto.migrate` — adds the `passkeys` table.
2. Release & push to GHCR.
3. Recreate container on `handcoding.de`.

Smoke test (24 hours with kill switch off):

- `curl -i https://dtu.app/users/log-in` → 200, no passkey section.
- `curl -i -X POST https://dtu.app/auth/passkey/registration/begin` → 404.

After 24 hours of clean logs, flip `PASSKEYS_ENABLED=true` in
`docker-infrastructure/services/dtu.app/.env` and recreate. Post-flip smoke:

- Passkey button visible on `/users/log-in`.
- Passkey card visible on `/users/settings`.

Watch for 7 days. The kill switch can be flipped back at any time with no
data loss.

## 14. Open / deferred decisions

- **Cross-device hybrid transport testing.** Real device-pair flows rely on
  OS-level Bluetooth prompts we can't simulate in CI. We rely on the
  `webauthn` lib's coverage of the spec.
- **Recovery codes.** Out of scope. Magic link is the recovery path.
- **Passkey-only registration (no password).** Out of scope for this design.
  Could be added later as a setting on `User`.
- **Authenticator attestation metadata.** Not stored. The `webauthn` lib's
  default trust model is acceptable for our threat model.