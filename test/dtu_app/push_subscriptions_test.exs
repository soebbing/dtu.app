defmodule DtuApp.PushSubscriptionsTest do
  @moduledoc """
  Unit tests for `DtuApp.PushSubscriptions`.

  Covers the four lifecycle operations the controller and the
  dispatcher use:

    * `list_for_user/1` — only returns rows owned by the user, in
      newest-first order.
    * `upsert/2` — inserts a new row, updates an existing same-user
      row, and migrates ownership when the same `endpoint` posts
      from a different user (e.g. two accounts sharing a browser).
    * `delete/2` — only deletes the calling user's row; mismatched
      users get `:noop` rather than 404.
    * `delete_by_endpoint/1` — owner-agnostic delete used by the
      dispatcher after a `:gone` from the push service.

  No HTTP / Finch mocking here: the context layer is pure Ecto and
  doesn't touch the network. The dispatcher's HTTP path is covered
  in `DtuApp.PushTest`.
  """
  use DtuApp.DataCase, async: true

  import Ecto.Query

  alias DtuApp.PushSubscriptions
  alias DtuApp.PushSubscriptions.PushSubscription

  describe "list_for_user/1" do
    test "returns the user's subscriptions newest-first" do
      user = user_fixture()
      # The `inserted_at` column is `:utc_datetime` (second precision)
      # so two inserts in the same test tick land on identical
      # timestamps and Postgres falls back to heap order — not
      # insertion order. Force distinct timestamps via direct UPDATE
      # so the `ORDER BY inserted_at DESC` assertion in
      # `list_for_user/1` is deterministic.
      older =
        insert_sub(user, endpoint: "https://push.example/older")
        |> touch_at(DateTime.add(DateTime.utc_now(:second), -60, :second))

      _newer =
        insert_sub(user, endpoint: "https://push.example/newer")
        |> touch_at(DateTime.utc_now(:second))

      listed = PushSubscriptions.list_for_user(user)

      assert Enum.map(listed, & &1.endpoint) == [
               "https://push.example/newer",
               "https://push.example/older"
             ]

      _ = older
    end

    test "excludes another user's subscriptions" do
      user_a = user_fixture()
      user_b = user_fixture()
      insert_sub(user_a, endpoint: "https://push.example/a")
      insert_sub(user_b, endpoint: "https://push.example/b")

      listed_a = PushSubscriptions.list_for_user(user_a)
      listed_b = PushSubscriptions.list_for_user(user_b)

      assert length(listed_a) == 1
      assert hd(listed_a).user_id == user_a.id

      assert length(listed_b) == 1
      assert hd(listed_b).user_id == user_b.id
    end
  end

  describe "upsert/2" do
    test "inserts a brand-new subscription" do
      user = user_fixture()
      attrs = sub_attrs(endpoint: "https://push.example/new")

      assert {:ok, %PushSubscription{id: id}} = PushSubscriptions.upsert(user, attrs)
      assert is_integer(id)
      assert id > 0
    end

    test "updates an existing same-user subscription" do
      user = user_fixture()
      attrs = sub_attrs(endpoint: "https://push.example/update")

      {:ok, first} = PushSubscriptions.upsert(user, attrs)
      {:ok, second} = PushSubscriptions.upsert(user, Map.put(attrs, "user_agent", "Mozilla/5.0"))

      assert first.id == second.id
      assert second.user_agent == "Mozilla/5.0"
    end

    test "migrates ownership when the endpoint posts from a different user" do
      user_a = user_fixture()
      user_b = user_fixture()
      attrs = sub_attrs(endpoint: "https://push.example/shared")

      {:ok, owned_by_a} = PushSubscriptions.upsert(user_a, attrs)
      assert owned_by_a.user_id == user_a.id

      {:ok, owned_by_b} = PushSubscriptions.upsert(user_b, attrs)
      assert owned_by_b.id == owned_by_a.id
      assert owned_by_b.user_id == user_b.id

      assert PushSubscriptions.list_for_user(user_a) == []

      assert [%PushSubscription{user_id: user_id}] =
               PushSubscriptions.list_for_user(user_b)

      assert user_id == user_b.id
      refute user_id == user_a.id
    end

    test "rejects an endpoint that is not an https URL" do
      user = user_fixture()
      attrs = sub_attrs(endpoint: "http://insecure.example/foo")

      assert {:error, changeset} = PushSubscriptions.upsert(user, attrs)

      assert %{endpoint: ["must be an absolute https URL"]} =
               errors_on(changeset)
    end

    test "rejects missing required keys" do
      user = user_fixture()

      assert {:error, changeset} =
               PushSubscriptions.upsert(user, %{"endpoint" => "https://push.example/x"})

      assert %{p256dh: ["can't be blank"], auth: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "delete/2" do
    test "deletes a row owned by the user" do
      user = user_fixture()
      insert_sub(user, endpoint: "https://push.example/del")

      assert {:ok, %PushSubscription{}} =
               PushSubscriptions.delete(user, "https://push.example/del")

      assert PushSubscriptions.list_for_user(user) == []
    end

    test "returns :noop when the row is owned by someone else" do
      user_a = user_fixture()
      user_b = user_fixture()
      insert_sub(user_a, endpoint: "https://push.example/mine")

      assert :noop = PushSubscriptions.delete(user_b, "https://push.example/mine")

      # user_a's row is still there
      listed = PushSubscriptions.list_for_user(user_a)
      assert length(listed) == 1
      assert hd(listed).user_id == user_a.id
    end

    test "returns :noop for a non-existent endpoint" do
      user = user_fixture()
      assert :noop = PushSubscriptions.delete(user, "https://push.example/missing")
    end
  end

  describe "delete_by_endpoint/1" do
    test "removes the row regardless of owner" do
      user = user_fixture()
      insert_sub(user, endpoint: "https://push.example/gone")

      assert :ok = PushSubscriptions.delete_by_endpoint("https://push.example/gone")
      assert PushSubscriptions.list_for_user(user) == []
    end

    test "is a no-op for an unknown endpoint" do
      assert :ok = PushSubscriptions.delete_by_endpoint("https://push.example/never-existed")
    end
  end

  ## Fixtures / helpers

  defp user_fixture, do: DtuApp.AccountsFixtures.user_fixture()

  defp sub_attrs(overrides) do
    Map.merge(
      %{
        "endpoint" => "https://push.example/default",
        "p256dh" => "BPubKey",
        "auth" => "AAuthSecret",
        "user_agent" => "test-agent"
      },
      Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
    )
  end

  defp insert_sub(user, attrs) do
    {:ok, sub} = PushSubscriptions.upsert(user, sub_attrs(attrs))
    sub
  end

  # Force `inserted_at` to an explicit timestamp. `Ecto`'s default
  # uses `NaiveDateTime.utc_now()` at second precision, so two
  # inserts in the same test tick land on the same value and the
  # `ORDER BY inserted_at DESC` order is heap-order rather than
  # insertion-order.
  defp touch_at(%PushSubscription{id: id} = _sub, %DateTime{} = dt) do
    {1, _} =
      DtuApp.Repo.update_all(
        from(s in PushSubscription, where: s.id == ^id),
        set: [inserted_at: dt]
      )

    DtuApp.Repo.get!(PushSubscription, id)
  end
end
