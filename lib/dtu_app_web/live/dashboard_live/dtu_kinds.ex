defmodule DtuAppWeb.DashboardLive.DtuKinds do
  @moduledoc """
  DTU-kind predicates used by the dashboard's device-list rendering
  and the per-DTU presence badges (`has_inverter?`, `has_shelly?`,
  `has_ro_sink?`).

  Pure predicates over `DtuApp.Devices.Dtu.kind` — no LiveView
  state, no DB calls, no assigns. Kept as their own module so the
  kind taxonomy (inverter vs consumption meter vs read-only sink)
  has a single source of truth: when a new device kind ships, the
  change goes here, and both `mount_seed/2`'s summary assigns and
  the LiveView render read it through the same predicates.
  """

  alias DtuApp.Devices

  # Inverter kinds: DTUs that report `ac_power` / `yield_day` and
  # contribute to the production stats and chart. Currently
  # OpenDTU and AhoyDTU.
  def inverter_kind?(%Devices.Dtu{kind: kind}), do: kind in [:opendtu, :ahoydtu]
  def inverter_kind?(_), do: false

  # Shelly kinds: DTUs that publish `consumption_power` from a
  # paired energy meter. Currently only the Plus 3EM Gen3+.
  def shelly_kind?(%Devices.Dtu{kind: :shelly3em}), do: true
  def shelly_kind?(_), do: false

  # Read-only MQTT sink: a passive subscriber that wants a real-time
  # feed of every other DTU's telemetry on the same account, but is
  # **never** allowed to PUBLISH. Sinks are not inverters and not
  # consumption meters — they show as a presence-only device card
  # with a "sink" badge so the user understands why this entry doesn't
  # contribute to the production/consumption/net rows above. The
  # broker enforces the publish-suppression contract
  # (`DtuApp.MqttBroker.Broker.handle_publish/4`); this predicate is
  # purely about the dashboard's presentation.
  def ro_sink_kind?(%Devices.Dtu{kind: :mqtt_ro_sink}), do: true
  def ro_sink_kind?(_), do: false
end
