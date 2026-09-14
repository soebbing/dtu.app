defmodule DtuAppWeb.NotificationsLive.HistoryTest do
  use DtuAppWeb.ConnCase, async: true

  import DtuApp.AccountsFixtures

  alias DtuApp.Accounts.User
  alias DtuApp.Notifications
  alias DtuAppWeb.NotificationsLive.History

  describe "load/3 — page-clamping & total math" do
    setup :register_and_log_in_user

    test "empty history: returns an empty list and a single 'page 1 of 1'" do
      user = fixture_user()

      assert {[], 1, 1, 0} = History.load(user, 1, nil)
    end

    test "empty history: clamps an out-of-range requested page back to 1" do
      user = fixture_user()

      # Page 99 on an empty history must NOT render a phantom page;
      # the parent LiveView relies on this for the "stuck on empty
      # page after delete" case.
      assert {[], 1, 1, 0} = History.load(user, 99, nil)
    end

    test "empty filtered history: same clamp, with a non-nil event filter" do
      user = fixture_user()

      assert {[], 1, 1, 0} = History.load(user, 5, "sun_down")
    end

    test "non-empty history: returns clamped_page in [1, total_pages]" do
      user = fixture_user()
      seed_n_notifications(user, 120, "dtu_connection")

      # Page 1 of 3 (120 / 50 = ceil)
      assert {page1_items, 1, 3, 120} = History.load(user, 1, "dtu_connection")
      assert length(page1_items) == 50

      # Page 2 returns 50 more
      assert {page2_items, 2, 3, 120} = History.load(user, 2, "dtu_connection")
      assert length(page2_items) == 50

      # Page 3 returns the trailing 20
      assert {page3_items, 3, 3, 120} = History.load(user, 3, "dtu_connection")
      assert length(page3_items) == 20

      # Page 4 (out of range) clamps to 3 — never render a phantom page
      assert {_, 3, 3, 120} = History.load(user, 4, "dtu_connection")

      # Page 0 (out of range) clamps to 1
      assert {_, 1, 3, 120} = History.load(user, 0, "dtu_connection")
    end

    test "non-empty history: a different event filter shows the per-filter total, not the global one" do
      user = fixture_user()
      seed_n_notifications(user, 200, "dtu_connection", offset_seconds: 1000)
      seed_n_notifications(user, 3, "sun_down", offset_seconds: 0)

      # The `sun_down` filter returns total=3 (1 page), NOT total=203
      assert {sun_down_items, 1, 1, 3} = History.load(user, 1, "sun_down")
      assert length(sun_down_items) == 3

      # The `dtu_connection` filter returns total=200 (4 pages)
      assert {_, 1, 4, 200} = History.load(user, 1, "dtu_connection")

      # The `nil` filter returns the global total (203 → 5 pages)
      assert {_, 1, 5, 203} = History.load(user, 1, nil)
    end
  end

  describe "page_size/0" do
    test "exposes the page size used by the parent LiveView" do
      assert is_integer(History.page_size())
      assert History.page_size() == 50
    end
  end

  # --- helpers --------------------------------------------------------------

  # A fresh user (separate from the logged-in user created by the
  # `register_and_log_in_user` setup) so the history assertions
  # don't see the other user's notification rows. `async: true`
  # is safe because the user_id is unique per test.
  defp fixture_user do
    user_fixture()
  end

  defp seed_n_notifications(%User{} = user, n, event, opts \\ []) do
    offset_seconds = Keyword.get(opts, :offset_seconds, 0)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for i <- 1..n do
      {:ok, _} =
        %Notifications.Notification{}
        |> Notifications.Notification.changeset(user, %{
          event: event,
          title: "title #{i}",
          body: "body #{i}",
          channel: "push",
          payload: %{},
          delivered_at: DateTime.add(now, -(i + offset_seconds), :second)
        })
        |> DtuApp.Repo.insert()
    end
  end
end
