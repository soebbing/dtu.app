defmodule DtuAppWeb.DeviceLive.Index do
  @moduledoc false
  use DtuAppWeb, :live_view

  alias DtuApp.Devices
  alias DtuApp.Devices.Dtu

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> stream(:devices, Devices.list_devices(socket.assigns.current_scope.user))
     |> assign(:deleting_device, nil)
     |> assign_form(Devices.change_device(socket.assigns.current_scope.user))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: socket

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Add DTU")
    |> assign_form(Devices.change_device(socket.assigns.current_scope.user))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)

    socket
    |> assign(:page_title, "Edit DTU")
    |> assign(:device, device)
    |> assign_form(Devices.change_device(socket.assigns.current_scope.user, device))
  end

  @impl true
  def handle_event("validate", %{"dtu" => dtu_params}, socket) do
    changeset =
      Devices.change_device(socket.assigns.current_scope.user, dtu_changeset_target(socket), dtu_params)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"dtu" => dtu_params}, socket) do
    save_device(socket, socket.assigns.live_action, dtu_params)
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)
    {:noreply, assign(socket, :deleting_device, device)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :deleting_device, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    device = Devices.get_device!(socket.assigns.current_scope.user, id)
    {:ok, _} = Devices.delete_device(device)

    {:noreply,
     socket
     |> stream_delete(:devices, device)
     |> assign(:deleting_device, nil)
     |> put_flash(:info, "DTU removed")}
  end

  defp save_device(%{assigns: %{live_action: :new}} = socket, _action, dtu_params) do
    case Devices.create_device(socket.assigns.current_scope.user, dtu_params) do
      {:ok, device} ->
        {:noreply,
         socket
         |> stream_insert(:devices, device, at: 0)
         |> put_flash(:info, "DTU added")
         |> push_patch(to: ~p"/devices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_device(%{assigns: %{live_action: :edit, device: device}} = socket, _action, dtu_params) do
    case Devices.update_device(device, dtu_params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> stream_insert(:devices, updated)
         |> put_flash(:info, "DTU updated")
         |> push_patch(to: ~p"/devices")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :dtu))
  end

  # When editing, validate against the existing device so unique constraints
  # (name, username) resolve correctly; otherwise build against a fresh struct.
  defp dtu_changeset_target(%{assigns: %{device: %Dtu{} = device}}), do: device
  defp dtu_changeset_target(_socket), do: %Dtu{}
end
