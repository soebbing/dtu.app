defmodule DtuApp.Repo.Migrations.AddCentsPerKwhToUsers do
  use Ecto.Migration

  # Energy rate for the "Saved this month" dashboard card. Stored as
  # INTEGER cents (NOT a Decimal / float) to make the savings
  # multiplication exact: a 1-decimal €/kWh value in the form is
  # rounded to whole cents (e.g. "0.32 €/kWh" → 32 cents/kWh) and the
  # dashboard multiplies kWh × cents ÷ 100 for the euro amount.
  #
  # Nullable so existing users — and the seed user — don't get a
  # made-up rate; the dashboard hides the savings card when this is
  # NULL (no rate set yet → no "saved" claim to make).
  def change do
    alter table(:users) do
      add :cents_per_kwh, :integer
    end
  end
end
