defmodule DtuApp.Devices.Reading do
  use Ecto.Schema
  import Ecto.Changeset

  # `readings` is a TimescaleDB hypertable with a composite primary key
  # (dtu_id, inverter_serial, mppt_index, inserted_at) — no serial `id`.
  # `mppt_index` distinguishes the rows a single uplink produces:
  #   0  = AC-side aggregate (only AhoyDTU ch0 / OpenDTU total emits this)
  #   1+ = individual MPPT channel (1 or 2 for a typical micro-inverter)
  # `inverter_name` carries the human-friendly label from the device
  # edit page or the AhoyDTU topic (OpenDTU realtime doesn't ship a
  # name, so OpenDTU rows keep it null until the user edits the device).
  #
  # `power_type` distinguishes what a row means. `:production` is the
  # original OpenDTU/AhoyDTU semantic — `ac_power` is the inverter's AC
  # *output* in watts. `:consumption` is the Shelly Plus 3EM semantic —
  # `consumption_power` is the household's drawn power in watts
  # (negative on net export). The two never share a column, so the
  # dashboard branches on `power_type` to keep totals separate.
  @primary_key false
  schema "readings" do
    field :inverter_serial, :string, primary_key: true
    field :mppt_index, :integer, primary_key: true, default: 0
    field :inverter_name, :string
    field :power_type, :string, default: "production"

    field :ac_power, :float
    field :dc_power, :float
    field :yield_day, :float
    field :yield_total, :float
    field :frequency, :float
    field :temperature, :float
    field :producing, :boolean
    field :reachable, :boolean

    # Shelly Plus 3EM (Gen3+) fields. Only populated when
    # `power_type = :consumption`; production rows leave them nil.
    field :consumption_power, :float
    field :consumption_energy_day, :float
    field :consumption_energy_total, :float

    field :inserted_at, :utc_datetime_usec, primary_key: true

    belongs_to :dtu, DtuApp.Devices.Dtu, define_field: false
    field :dtu_id, :id, primary_key: true
  end

  @power_types [:production, :consumption]

  @doc false
  def changeset(reading, attrs) do
    reading
    |> cast(attrs, [
      :inverter_serial,
      :mppt_index,
      :inverter_name,
      :power_type,
      :ac_power,
      :dc_power,
      :yield_day,
      :yield_total,
      :frequency,
      :temperature,
      :producing,
      :reachable,
      :consumption_power,
      :consumption_energy_day,
      :consumption_energy_total,
      :dtu_id,
      :inserted_at
    ])
    |> validate_required([:inverter_serial, :dtu_id])
    |> validate_inclusion(:power_type, @power_types)
    # `readings` has no auto-managed timestamps; default the hypertable time
    # column to "now" when the caller didn't supply one.
    |> maybe_default_inserted_at()
  end

  defp maybe_default_inserted_at(changeset) do
    case get_field(changeset, :inserted_at) do
      nil ->
        # Use the database clock for the hypertable time column. Reading
        # `now()` from the DB (rather than `DateTime.utc_now()` on the app)
        # keeps the value that gets bucketed by `time_bucket(...)` and the
        # value the dashboard compares against in lock-step. See
        # `DtuApp.Time` for the rationale.
        changeset
        |> put_change(:inserted_at, DtuApp.Time.utc_now_usec())
        |> bump_on_pk_collision()

      _ ->
        changeset
    end
  end

  # The composite PK `(dtu_id, inverter_serial, mppt_index, inserted_at)`
  # collides if two uplinks for the same `(dtu_id, inverter_serial,
  # mppt_index)` land on the same microsecond — which is now possible
  # because `DtuApp.Time.utc_now_usec/0` round-trips through the DB
  # rather than the app clock (the app clock used to drift a few µs
  # between calls by accident, masking this). Bump `inserted_at` by 1 µs
  # whenever a row already exists at that exact instant, up to 1000
  # attempts (1 ms of micro-bumps). In practice one or two bumps suffice;
  # the bound exists only so we can't spin forever on a degenerate clock.
  defp bump_on_pk_collision(changeset) do
    dtu_id = get_field(changeset, :dtu_id)
    inverter_serial = get_field(changeset, :inverter_serial)
    mppt_index = get_field(changeset, :mppt_index) || 0
    inserted_at = get_field(changeset, :inserted_at)

    cond do
      is_nil(dtu_id) or is_nil(inverter_serial) or is_nil(inserted_at) ->
        changeset

      true ->
        new_ts =
          1..1_000
          |> Enum.reduce_while(inserted_at, fn _attempt, ts ->
            if pk_exists?(dtu_id, inverter_serial, mppt_index, ts) do
              {:cont, DateTime.add(ts, 1, :microsecond)}
            else
              {:halt, ts}
            end
          end)

        if DateTime.compare(new_ts, inserted_at) == :gt do
          put_change(changeset, :inserted_at, new_ts)
        else
          changeset
        end
    end
  end

  defp pk_exists?(dtu_id, inverter_serial, mppt_index, inserted_at) do
    import Ecto.Query

    DtuApp.Repo.exists?(
      from r in __MODULE__,
        where:
          r.dtu_id == ^dtu_id and
            r.inverter_serial == ^inverter_serial and
            r.mppt_index == ^mppt_index and
            r.inserted_at == ^inserted_at
    )
  end
end
