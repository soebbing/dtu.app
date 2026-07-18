defmodule DtuApp do
  @moduledoc """
  dtu.app — self-hosted solar telemetry for OpenDTU / AhoyDTU inverters.

  This module is the OTP application root. The contexts under
  `DtuApp.Accounts` and `DtuApp.Devices` define the domain and business logic,
  and manage the data (from the database, the MQTT broker, or external APIs).
  """
end
