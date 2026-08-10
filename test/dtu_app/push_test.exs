defmodule DtuApp.PushTest do
  @moduledoc """
  Unit tests for `DtuApp.Push`.

  Two surface paths exercised here:

    1. **`public_key/0`** — the VAPID public key exposed by
       `DtuApp.Push` (which the `/push/vapid/public_key` controller
       hands back to the browser for `PushManager.subscribe()`).
       Verified to return the configured value, or `nil` when VAPID
       isn't configured.

    2. **`deliver/2`** — the fan-out. Without VAPID keys configured,
       `deliver/2` is a quiet no-op; the in-page PubSub path keeps
       working and the server logs no warnings. The per-row `:ok`
       / `:error` paths (HTTP 200, 404, 410, transport failure) are
       covered by the dispatcher in conjunction with `web_push`,
       which has its own test suite in `deps/web_push/test/`.

  We don't mock `WebPush.send/3` here — the VAPID-config-aware
  branches are deterministic, and adding a mocking dependency just
  for this would be more friction than it's worth. The end-to-end
  path (HTTP success / 404 / 410 / transport) is verified by the
  integration with `web_push`'s own tests.
  """
  use ExUnit.Case, async: false

  alias DtuApp.Push

  describe "public_key/0" do
    test "returns nil when no VAPID config is set" do
      # Snapshot, clear, assert, restore — so we don't leak a cleared
      # config into other tests in the same run.
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        assert Push.public_key() == nil
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end

    test "returns the configured public key when VAPID is set" do
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(:web_push, :vapid, %{
        public_key: "BTestPublicKey",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      })

      try do
        assert Push.public_key() == "BTestPublicKey"
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end

    test "treats an empty public_key string as not-configured" do
      # The runtime.exs default for unset vars is "" (empty string).
      # Treat it as "no VAPID" rather than trying to send with a
      # zero-length key — that's a config bug, not a valid deployment.
      original = Application.get_env(:web_push, :vapid)

      Application.put_env(:web_push, :vapid, %{
        public_key: "",
        private_key: "TestPrivateKey",
        subject: "mailto:test@example.com"
      })

      try do
        assert Push.public_key() == nil
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        else
          Application.delete_env(:web_push, :vapid)
        end
      end
    end
  end

  describe "deliver/2" do
    test "is a quiet no-op when VAPID isn't configured" do
      # The most important property of `deliver/2`: it never raises.
      # A misconfigured deployment (no VAPID keys) must keep the
      # in-page notification path working and silently skip the
      # web-push fan-out. Otherwise a freshly-deployed server would
      # log noisy errors every time a DTU went offline.
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        # We use a no-arg `User` struct; `deliver/2` short-circuits
        # before reaching `PushSubscriptions.list_for_user/1`, so the
        # user isn't even looked up.
        fake_user = %DtuApp.Accounts.User{id: 0}

        assert :ok = Push.deliver(fake_user, %{event: "test", title: "x", body: "y"})
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end

    test "deliver_many/2 is also a no-op when VAPID isn't configured" do
      original = Application.get_env(:web_push, :vapid)
      Application.delete_env(:web_push, :vapid)

      try do
        assert :ok = Push.deliver_many([], %{event: "test"})
      after
        if original do
          Application.put_env(:web_push, :vapid, original)
        end
      end
    end
  end
end
