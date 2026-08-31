defmodule DtuApp.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    # Notification preferences. All default to false so existing
    # users don't silently start receiving notifications on deploy.
    field :notify_dtu_connection, :boolean, default: false
    field :notify_sun_down, :boolean, default: false
    # Fires once per local day when the user's fleet first transitions
    # from 0 W to > 0 W (the array waking up for the day). Producer:
    # `DtuApp.Notifications.SunUp`.
    field :notify_sun_up, :boolean, default: false

    # User's local UTC offset in seconds (positive east of UTC;
    # e.g. 7200 for CEST). Persisted from the dashboard JS's
    # `set_timezone` push so the server-side `SunUp` producer can
    # compute "today" in the user's local TZ even when no
    # LiveView is attached. Updated on every dashboard mount.
    # Default 0 (UTC) for users who've never loaded the dashboard
    # with TZ detection enabled.
    field :tz_offset_seconds, :integer, default: 0

    # Energy rate (in cents per kWh) for the dashboard's
    # "Saved this month" card. Nullable — when nil, the card is
    # hidden so we don't show a savings claim with no rate to back
    # it. Stored as integer cents (NOT a Decimal) so the savings
    # multiplication is exact: €/kWh in the form is converted to
    # whole cents (e.g. "0.32" → 32), and the dashboard computes
    # `month_kwh * cents_per_kwh` for the euro-cent amount (which
    # `Devices.format_savings/1` then formats as €X.XX). See
    # `DtuApp.Devices.compute_savings/2`.
    field :cents_per_kwh, :integer

    # The user's preferred UI language (ISO 639-1 short code;
    # one of "en", "de", "fr"). Mirrored by `Plugs.Locale` (which
    # reads it on every request and falls back to Accept-Language
    # then "en" for signed-out visitors) and the per-event
    # notification producers (which wrap their `gettext/1` calls in
    # `Gettext.with_locale/2` against this value, so the broadcast
    # payload and the service-worker push both end up in the
    # user's language). Default "en" so existing users don't see
    # a sudden locale change on deploy.
    field :locale, :string, default: "en"

    # User's chosen notification channel. One of:
    #   "push"  — only native Web Push (existing behaviour)
    #   "email" — only transactional email (new fallback)
    #   "both"  — fan out to both
    # Defaults to "push" for new and existing users so this migration
    # doesn't change anyone's behaviour silently.
    field :notification_channel, :string, default: "push"

    # User's geographic position (decimal degrees, WGS84). Captured
    # once by the dashboard's colocated JS hook from
    # `navigator.geolocation` and persisted via
    # `DtuApp.Accounts.update_user_location/2`. Used server-side by
    # `DtuApp.SunCalc` to compute astronomical sunrise/sunset on the
    # chart's X axis. Nullable: existing users and users who decline
    # the browser's geolocation prompt keep both columns nil and the
    # chart simply shows no sun markers (rather than an "unknown"
    # placeholder, which would be visual noise for the majority case).
    # Decimal precision 9 / scale 6 (≈ 11 cm at the equator, well
    # below what browser geolocation APIs resolve to anyway; float
    # drift would corrupt the sunrise/sunset calc near solstice) is
    # set on the migration side — Ecto's `field/3` doesn't accept
    # precision/scale options, only the migration does.
    field :latitude, :decimal
    field :longitude, :decimal

    has_one :shared_link, DtuApp.Accounts.SharedLink

    timestamps(type: :utc_datetime)
  end

  @supported_locales ~w(en de fr)
  @valid_channels ~w(push email both)

  # Latitude / longitude validation bounds (decimal degrees, WGS84).
  # Anything outside this range is impossible on Earth and almost
  # certainly a corrupted payload (e.g. a JS bug that swaps the two
  # axes or applies the wrong sign) — reject it at the changeset
  # boundary so the SunCalc never sees garbage. Module attributes
  # can't hold float ranges, so we define them as `{min, max}` tuples
  # and unpack in the validator.
  @lat_bounds {-90.0, 90.0}
  @lon_bounds {-180.0, 180.0}

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, DtuApp.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Argon2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    # Use the database clock so `confirmed_at` lines up with whatever the
    # DB later compares it against (e.g. downstream "X minutes since
    # confirmation" logic). See `DtuApp.Time`.
    now = DtuApp.Time.utc_now()
    change(user, confirmed_at: now)
  end

  @doc """
  A changeset for the notification preferences on the `/notifications`
  page. Both flags are cast; the page is the only writer so we don't
  need extra validation.
  """
  def notification_settings_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :notify_dtu_connection,
      :notify_sun_down,
      :notify_sun_up,
      :notification_channel
    ])
    |> validate_inclusion(:notification_channel, @valid_channels,
      message: "must be one of: push, email, both"
    )
  end

  @doc """
  A changeset for the user's geographic position. Used by
  `DtuApp.Accounts.update_user_location/2`, which is fed by the
  dashboard's colocated JS hook after
  `navigator.geolocation.getCurrentPosition(...)` resolves.

  Both fields are cast as floats (the underlying column type is
  `:decimal` for exact storage, but Ecto handles the
  float→Decimal conversion on write so callers can pass plain JS
  numbers — Phoenix's params parser emits floats for JSON numbers).
  Either field may be `nil` so a partial payload (e.g. latitude
  arrives but longitude is missing because of a partial
  position.coords) drops both to nil atomically rather than
  recording a half-sensible position.

  Range validation matches real-world bounds (decimal degrees,
  WGS84) so a corrupted payload — wrong sign, swapped axes — is
  caught at the changeset boundary instead of corrupting the
  sunrise/sunset calc downstream. The error messages are
  plain-string (the User module doesn't `use Gettext`); the
  controller / LiveView layer is expected to translate them
  through `Ecto.Changeset.traverse_errors/2` if needed.
  """
  def location_changeset(user, attrs) do
    user
    |> cast(attrs, [:latitude, :longitude])
    |> validate_change(:latitude, fn _, value ->
      case value do
        nil ->
          []

        %Decimal{} = lat ->
          # `:decimal` field — cast converts floats to `%Decimal{}`
          # before validate_change runs, so the `is_number/1` guard
          # alone silently rejects every legitimate write from
          # `Accounts.update_user_location/2` (which always takes a
          # float). Compare as float to keep the bounds check
          # readable; `Decimal.to_float/1` is safe for already-valid
          # ranges so a corrupt payload still fails the bounds test.
          lat_f = Decimal.to_float(lat)

          if lat_f >= elem(@lat_bounds, 0) and lat_f <= elem(@lat_bounds, 1),
            do: [],
            else: [latitude: "must be between -90 and 90"]

        lat when is_number(lat) and lat >= elem(@lat_bounds, 0) and lat <= elem(@lat_bounds, 1) ->
          []

        _ ->
          [latitude: "must be between -90 and 90"]
      end
    end)
    |> validate_change(:longitude, fn _, value ->
      case value do
        nil ->
          []

        %Decimal{} = lon ->
          lon_f = Decimal.to_float(lon)

          if lon_f >= elem(@lon_bounds, 0) and lon_f <= elem(@lon_bounds, 1),
            do: [],
            else: [longitude: "must be between -180 and 180"]

        lon when is_number(lon) and lon >= elem(@lon_bounds, 0) and lon <= elem(@lon_bounds, 1) ->
          []

        _ ->
          [longitude: "must be between -180 and 180"]
      end
    end)
  end

  @doc """
  A changeset for the user's account-wide settings on the
  `/users/settings` page — currently just the `cents_per_kwh` energy
  rate. The form takes a decimal €/kWh value in `euros_per_kwh`; the
  changeset converts it to whole cents and casts into
  `cents_per_kwh`. An empty form (or "0") clears the field back to
  `nil` so the savings card disappears rather than showing
  €0.00.

  Allowed range: 0 < cents_per_kwh ≤ 10000 (i.e. €0.01 to €100/kWh).
  The upper bound is generous — German residential rates go up to
  ~€0.40/kWh, industrial rates can be higher; €100/kWh covers every
  plausible electricity market. Anything higher is almost certainly
  a typo and would also produce a misleading savings number.
  """
  def settings_changeset(user, attrs) do
    euros =
      attrs
      |> Map.get("euros_per_kwh", "")
      |> to_string()
      |> String.trim()

    # `Float.parse/1` returns `:error` for an empty / whitespace-only
    # string and `{+0.0, _}` for "0" / "0.00". Both must be treated as
    # "no rate set" → cast `cents_per_kwh` to `nil` so the dashboard
    # hides the savings card instead of showing red "is invalid"
    # errors. Out-of-range values are reported as the friendly
    # "must be between" message by the validate_change clause below.
    cents =
      case Float.parse(euros) do
        {f, _} when f > 0 and f <= 100.0 -> round(f * 100)
        _ -> nil
      end

    locale = Map.get(attrs, "locale") || Map.get(attrs, :locale) || user.locale

    user
    |> cast(%{"cents_per_kwh" => cents, "locale" => locale}, [:cents_per_kwh, :locale])
    |> validate_change(:cents_per_kwh, fn _, value ->
      case value do
        nil -> []
        c when is_integer(c) and c > 0 and c <= 10_000 -> []
        # Plain-string error message — the User module doesn't have
        # `use Gettext`, so i18n is handled upstream by the controller /
        # template's `Ecto.Changeset.traverse_errors/2` when present,
        # or by the form-rendering helpers. The English literal is
        # the source of truth here.
        _ -> [cents_per_kwh: "must be between €0.01 and €100"]
      end
    end)
    |> validate_inclusion(:locale, @supported_locales,
      message: "must be one of: #{Enum.join(@supported_locales, ", ")}"
    )
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Argon2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%DtuApp.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Argon2.no_user_verify()
    false
  end
end
