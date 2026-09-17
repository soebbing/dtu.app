defmodule DtuApp.ApplicationTest do
  @moduledoc """
  Boot-safety checks for `DtuApp.Application`.

  These tests guard against regressions that the regular `mix test`
  suite wouldn't catch because they only show up in a release build:

  * **`Mix is not referenced in DtuApp.Application`**: a previous
    version called `Mix.env/0` from `notifier_children/0` to gate
    the singleton notification producers off in `:test`. `Mix` is a
    compile-time tooling module that isn't loaded in OTP releases
    (the `:mix` application isn't in the release boot script by
    default), so the call crashed the production supervision tree
    before any GenServer came up. By walking the BEAM atoms of the
    compiled module we catch the regression here in `mix test`
    without needing a release build step.
  """
  use ExUnit.Case, async: true

  test "DtuApp.Application does not reference the Mix module at runtime" do
    # Walk the BEAM `:atoms` chunk. Module atoms are added to it
    # exactly when the module references them — the `Mix` (alias for
    # `:Elixir.Mix`) module atom only ends up here if some `Mix.X`
    # call site exists in the bytecode. In a release where `:mix`
    # isn't booted, that call site is what crashes the app.
    #
    # Note: `Mix` (the Elixir alias) and `:Mix` (a bare atom literal)
    # are different atoms — `Mix == :"Elixir.Mix"` is `true`, but
    # `Mix == :Mix` is `false`. The BEAM stores the module's full
    # atom name, so the check has to look for `Mix` (== `:"Elixir.Mix"`).
    {module, binary, _path} = :code.get_object_code(DtuApp.Application)
    {:ok, {^module, chunks}} = :beam_lib.chunks(binary, [:atoms])
    raw_atoms = Keyword.fetch!(chunks, :atoms)

    atoms =
      Enum.map(raw_atoms, fn
        {_ord, a} when is_atom(a) -> a
        a when is_atom(a) -> a
      end)

    refute Mix in atoms,
           "DtuApp.Application's BEAM references the Mix module. " <>
             "`Mix` is loaded by `mix`/`iex -S mix` but is NOT in the OTP " <>
             "release boot script, so any call site crashes production boot. " <>
             "Use `Application.get_env/3` against a config key instead."
  end

  test "WebPushFinch Finch pool configures HTTP/2 for APNs compatibility" do
    # APNs at web.push.apple.com requires HTTP/2 since iOS 16.4 (March 2023).
    # Without `:http2` in the pool's `:protocols`, Finch defaults to `[:http1]`,
    # ALPN negotiation fails against the h2-only APNs endpoint, and the
    # outbound request eventually times out — surfaced in prod as
    # `[web_push] transport failure: %Finch.TransportError{reason: :timeout, …}`
    # (the bug PR #310 unmasked after fixing the prior `Keyword.get/3` crash
    # that was short-circuiting the push before it ever reached the network).
    #
    # Source-level assertion (matching the `Mix`-atom-check pattern above):
    # Finch's public introspection only exposes runtime pool metrics, not the
    # validated `:protocols` config, so reading `:sys.get_state/1` on a pool
    # worker would couple this test to Finch internals. A regex on the source
    # file catches the regression — anyone simplifying the child spec back to
    # the bare `{Finch, name: DtuAppWeb.WebPushFinch}` form (HTTP/1 default)
    # will trip the assertion.
    #
    # The regex uses `/s` (dotall) so `.` matches newlines, since the Finch
    # child spec spans multiple lines once the `:pools` map is added.
    source = File.read!("lib/dtu_app/application.ex")

    assert Regex.match?(
             ~r/name:\s*DtuAppWeb\.WebPushFinch.*:http2/s,
             source
           ),
           "WebPushFinch Finch pool must include `:http2` in `:protocols` so " <>
             "APNs (web.push.apple.com, HTTP/2-only since iOS 16.4) can negotiate " <>
             "the protocol via ALPN. Add `protocols: [:http1, :http2]` (or " <>
             "`[:http2]`) to the `{Finch, name: DtuAppWeb.WebPushFinch, …}` " <>
             "child spec in `lib/dtu_app/application.ex`. The default of " <>
             "`[:http1]` produces `Mint.TransportError{reason: :timeout}` " <>
             "against any HTTP/2-only push service."
  end
end
