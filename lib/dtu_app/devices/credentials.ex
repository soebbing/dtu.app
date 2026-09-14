defmodule DtuApp.Devices.Credentials do
  @moduledoc """
  Device CRUD + MQTT credential-cache hooks.

  The "Devices" half of the `Devices` context: list / get / create /
  update / delete / change_device, plus the private hooks that keep
  the embedded MQTT broker's credential cache in sync after a
  device write.

  Write paths (`create_device/2`, `update_device/2`, `delete_device/1`)
  flow through `tap_on_success/2` so we only refresh credentials /
  invalidate caches on the `:ok` branch — a failed insert never
  propagates a bad username to the broker, and a stale cache is
  never invalidated speculatively.

  Re-exported through `DtuApp.Devices` via `defdelegate` so existing
  `Devices.list_devices/1`-style call sites continue to work
  unchanged after the extraction.

  ## Notes

  The `UserDtuIdsCache` and `SelectableDatesCache` invalidate-on-write
  is part of the cache contract documented on those modules — the
  dashboard mount calls `UserDtuIdsCache.get/2` ~22 times, and a
  freshly created / removed DTU must be visible in the next call
  without waiting out the TTL.
  """

  require Logger

  import Ecto.Query

  alias DtuApp.Accounts.User
  alias DtuApp.Devices.Dtu
  alias DtuApp.Devices.UserDtuIdsCache
  alias DtuApp.Devices.SelectableDatesCache
  alias DtuApp.MqttBroker.Credentials, as: BrokerCredentials
  alias DtuApp.Repo

  @doc "List all devices owned by `user`, newest first."
  def list_devices(%User{} = user) do
    Dtu
    |> where([d], d.user_id == ^user.id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc "Fetch a device owned by `user`. Raises if missing or owned by someone else."
  def get_device!(%User{} = user, id) do
    Dtu
    |> where([d], d.user_id == ^user.id and d.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Non-raising variant of `get_device!/2`. Returns `nil` if the device
  doesn't exist or is owned by another user — callers use this when
  they're validating a user-supplied id (e.g. a query-param from a
  deep-link) and want the page to render with no expansion rather
  than 404 when the id is bogus.
  """
  def get_device(%User{} = user, id) do
    Dtu
    |> where([d], d.user_id == ^user.id and d.id == ^id)
    |> Repo.one()
  end

  @doc "Look up a device by its globally-unique MQTT username (broker auth path)."
  def get_device_by_username(username) when is_binary(username) do
    Repo.one(from d in Dtu, where: d.mqtt_username == ^username)
  end

  @doc "Create a device for `user` from `attrs`."
  def create_device(%User{} = user, attrs) do
    Dtu.create_changeset(user, attrs)
    |> Repo.insert()
    |> tap_on_success(fn created ->
      UserDtuIdsCache.invalidate(user.id)
      SelectableDatesCache.invalidate(user.id)
      refresh_credentials(created)
    end)
  end

  @doc "Update a device from `attrs`."
  def update_device(%Dtu{} = dtu, attrs) do
    dtu
    |> Dtu.update_changeset(attrs)
    |> Repo.update()
    |> tap_on_success(&refresh_credentials/1)
  end

  @doc "Delete a device."
  def delete_device(%Dtu{} = dtu) do
    Repo.delete(dtu)
    |> tap_on_success(fn _ ->
      UserDtuIdsCache.invalidate(dtu.user_id)
      SelectableDatesCache.invalidate(dtu.user_id)
      drop_credentials(dtu.mqtt_username)
    end)
  end

  @doc "Build a changeset for rendering a form (create)."
  def change_device(%User{} = user, %Dtu{} = dtu \\ %Dtu{}, attrs \\ %{}) do
    changeset =
      if dtu.id do
        Dtu.update_changeset(dtu, attrs)
      else
        Dtu.create_changeset(user, attrs)
      end

    Map.put(changeset, :action, :validate)
  end

  # --- Credential cache hooks -------------------------------------------------

  defp refresh_credentials(%Dtu{mqtt_username: username}) do
    safe_call(fn -> BrokerCredentials.refresh(username) end)
  end

  defp drop_credentials(username) do
    safe_call(fn -> BrokerCredentials.drop(username) end)
  end

  # The Credentials GenServer runs alongside the broker (gated off in test,
  # where it isn't started). Only call it when it's actually alive.
  defp safe_call(fun) do
    if Process.whereis(BrokerCredentials) do
      fun.()
    end
  rescue
    e -> Logger.warning("[devices] credential cache call failed: #{Exception.message(e)}")
  end

  defp tap_on_success({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_on_success(error, _fun), do: error
end
