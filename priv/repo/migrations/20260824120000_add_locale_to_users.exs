defmodule DtuApp.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  # `locale` — the user's preferred UI language (ISO 639-1 short
  # code; one of "en", "de", "fr"). Mirrored by the same-named
  # field on `DtuApp.Accounts.User` and the `Plugs.Locale` plug
  # (which reads it on every request and falls back to
  # Accept-Language then "en" for signed-out visitors).
  #
  # Default "en" so existing users don't see a sudden locale
  # change on deploy. The .po catalog files cover all three codes
  # already (`priv/gettext/{en,de,fr}/LC_MESSAGES/default.po`) —
  # no catalog expansion needed.
  #
  # Validated application-side via `validate_inclusion` in
  # `User.settings_changeset/2` so a malicious user can't store
  # an unsupported code (which would break `Gettext.put_locale/2`
  # and fall back to the default).
  def change do
    alter table(:users) do
      add :locale, :string, default: "en", null: false
    end
  end
end
