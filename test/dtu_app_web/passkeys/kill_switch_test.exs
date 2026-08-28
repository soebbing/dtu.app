defmodule DtuAppWeb.Passkeys.KillSwitchTest do
  use ExUnit.Case, async: true
  doctest DtuAppWeb.Passkeys.KillSwitch

  alias DtuAppWeb.Passkeys.KillSwitch

  describe "enabled?/2" do
    test "prod defaults to off when env is unset, blank, or unknown" do
      assert KillSwitch.enabled?(nil, :prod) == false
      assert KillSwitch.enabled?("", :prod) == false
      assert KillSwitch.enabled?("foo", :prod) == false
    end

    test "prod honors PASSKEYS_ENABLED=true explicitly" do
      assert KillSwitch.enabled?("true", :prod) == true
    end

    test "prod honors PASSKEYS_ENABLED=false explicitly" do
      assert KillSwitch.enabled?("false", :prod) == false
    end

    test "dev/test defaults to on when env is unset" do
      assert KillSwitch.enabled?(nil, :dev) == true
      assert KillSwitch.enabled?(nil, :test) == true
    end

    test "non-prod honors PASSKEYS_ENABLED=false explicitly" do
      assert KillSwitch.enabled?("false", :dev) == false
      assert KillSwitch.enabled?("false", :test) == false
    end
  end
end
