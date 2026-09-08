# Post-mount reconnect — investigation (2026-09-08)

## Symptom (reported 2026-09-05)

After PR #242 (Tier 2 atomic caches, 20 s → 12 s first-request
latency), the dashboard page renders fine — and then a German-localised
`client-error`/`server-error` flash appears at the top right:

> Etwas ist schiefgelaufen, versuche die Verbindung wieder
> herzustellen.

User's hypothesis (quoted): "Vermutlich, weil longpoll-Prozesse abgebrochen
wurden" — longpoll processes aborted.

## What the flash is

Both flashes live in `lib/dtu_app_web/components/layouts.ex:140-177`
inside `flash_group/1`. They are driven entirely by JS hooks:

| flash | shown when | JS source |
|---|---|---|
| `client-error` ("We can't find the internet") | `phx-client-error` class on `<body>` AND `phx-disconnected` fires | `displayError([... PHX_CLIENT_ERROR_CLASS])` (`view.ts:1259`) |
| `server-error` ("Something went wrong!") | `phx-server-error` class on `<body>` AND `phx-disconnected` fires | `displayError([... PHX_SERVER_ERROR_CLASS])` (`view.ts:1254`) |

Both classes are mutually exclusive and both need the **same event** to
make the flash visible: `phx-disconnected`. That event fires 500 ms
after `view.delayedDisconnected()`, scheduled by `view.onError(reason)`
(`view.ts:1278-1282`).

`view.onError(reason)` itself is wired to `channel.onError` in
`view.ts:1090`, which fires when the underlying Phoenix.Socket channel
emits its `error` event. The channel emits `error` from
`socket.onConnClose(event)` (`socket.js:550`, via
`triggerChanError()`).

So the chain that produces the flash is **strictly**:

```
WebSocket onclose
  ↳ socket.triggerChanError()                     (socket.js:576)
  ↳ channel.trigger(CHANNEL_EVENTS.error)       (socket.js:579)
  ↳ view.onError(reason)
     ↳ liveSocket.isConnected() == true still → displayError(
         [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS])
       ↳ body.classList ← "phx-server-error"
       ↳ delayedDisconnected() schedules for +500 ms
  ↳ + 500 ms → phx-disconnected event fires
  ↳ flash_group `phx-disconnected` hook unhides .server-error → flash visible
```

**The flash is therefore a smoking-gun signal: the LiveView's WebSocket
connection has actually closed on the browser.** No close ⇒ no error
classes ⇒ no flash.

## Why longpoll is the wrong suspect

The user's hypothesis is the longpoll fall-back path got torn down.
`Phoenix.Transports.LongPoll.Server` does shut down
`{:shutdown, :inactive}` (`long_poll_server.ex:96-103`) when no client
poll arrives within `window_ms` (default 10 s). But this is **the
longpoll GenServer**, not the LiveView's WebSocket.

Longpoll is reached via `Phoenix.LiveView.Socket`'s `longpoll:`
secondary transport. If WS is the primary and it stays open, the
longpoll side either is never opened in that session or serves a quick
GET that returns 200 with `[]` — neither path can fire
`channel.onError`. The "longpoll aborted" mechanism has no way to reach
`view.onError` ⇒ cannot produce this flash.

(And even when the longpoll back-end does die, the longpoll JS client's
own `onerror` callback only handles its own retry timer; it doesn't fire
LV channel error events.)

## Why the `:ignore` ETS-children pattern is not the cause

Boot-time worry: `start_link/1` returns `:ignore` so the supervisor
treats it as a one-shot, and the calling process terminates — does the
ETS table die with it?

Verified empirically with `mix run .scratch/ignore_ets_test.exs`:

```
immediately after supervisor start:
ets.whereis:  #Reference<…>
after 200 ms:
ets.whereis:  #Reference<…>      # same reference, table is alive
ets.owner:    #PID<0.726.0>      # NOT the temp start_link process
fetching via IgnoredEtsMod.fetch/1:
result: [{IgnoredEtsMod, :alive}]
```

The supervisor calls `Module.start_link/1` inside a wrapping
`proc_lib` process that **does not exit when the function returns
`:ignore`**; `:ignore` semantics only tell the *supervisor* not to
record the child. The ETS table owner is the supervisor itself. Tables
survive until the application stops. The moduledoc's claim is accurate.

## What I couldn't pin down

None of the obvious timeouts fire at the ~12 s mark:

| timeout | default | where |
|---|---|---|
| Phoenix channel heartbeat interval | 30 000 ms | `phoenix_socket.js:170` (`heartbeatIntervalMs`) |
| ThousandIsland read_timeout | 60 000 ms | `thousand_island/server_config.ex:39` |
| ThousandIsland send_timeout | 30 000 ms | `thousand_island/transports/tcp.ex:24` |
| Phoenix longpoll window_ms | 10 000 ms | `phoenix/transports/long_poll.ex:17` |
| `connectWithFallback` deadline | 2 500 ms | `phoenix_socket.js:414` |
| LiveView internal | n/a — no `mount_timeout` exists |

The connectWithFallback 2.5 s window IS the closest fit. It
auto-cancels via a successful topic-"phoenix" heartbeat ping
(`socket.js:441-457`), which Phoenix.Socket answers synchronously at
the transport layer (`phoenix/socket.ex:693-702`) — independent of the
LiveView mount. So a 12 s mount normally still passes the 2.5 s
handshake gate.

A 12 s LV mount can fill the mailbox with PubSub messages the LV
hasn't processed yet — but those messages arrive only after the
channel is joined (post-mount), so this shouldn't matter on the very
first request.

## Most likely causes (in order)

1. **Unhandled exception during the LV WebSocket mount.** The
   `kickoff_weather_fetch/6` inline branch on the first WS mount
   (line 1801-1804) calls `fetch_weather_snapshot/5`
   *synchronously*. That path goes through `OpenMeteo.hourly_cloud_cover/3`
   (`lib/dtu_app/weather/open_meteo.ex:93-102`), which catches
   Req-request-level errors but **does not catch JSON decode failures
   or map-pattern-match misses** in `decode/1`
   (`lib/dtu_app/weather/open_meteo.ex:114-128`). A non-JSON 200 body
   (e.g. captive-portal HTML, a regional Open-Meteo 200-with-empty
   payload) makes `Jason.decode!` raise, the raise walks all the way
   back through `mount/3`, the LV GenServer dies, and the WS closes.
   The `kickoff_weather_fetch/6` moduledoc explicitly claims "errors
   fall through to the helpers' nil/empty defaults" — but that
   contract is only honored by the *Task*-spawning branch; the inline
   branch is unprotected.

2. **Long-tail Slowloris-style WS close from a proxy or load balancer.**
   Some reverse proxies / corporate firewalls terminate an idle
   half-opened WebSocket at a few seconds in. If the production path
   in front of Bandit does that on the *response to the initial
   phx_reply*, the browser sees a close frame at the same moment the
   server thinks it's still connected. The visible latency matches a
   12 s mount exactly: the WS handshake completes fast, the proxy
   doesn't expect 12 s of silence before the first server-to-client
   frame, closes the upstream connection, the browser's WebSocket
   `onclose` fires once the rendered diff finally arrives.

3. **A PubSub / MQTT broker message landing in the LV mailbox
   immediately after `mount/3` returns**, before the channel handler
   can dispatch to it, with a payload pattern that doesn't match any
   `handle_info` clause. The catch-all `handle_info(_msg, socket)`
   (line 807-810) returns `{:noreply, socket}` and doesn't crash, so
   this *should* be benign — but worth confirming with logs.

## Proposed fix (defensive)

Independent of which cause wins: harden the LV WebSocket mount so a
raised exception during the inline weather snapshot, or any other
fresh-allocation step, surfaces to the page as a fully-rendered
dashboard with placeholder weather, rather than as a closed socket.

Two changes:

**(A) Wrap the inline `kickoff_weather_fetch` so a weather-side failure
survives the mount.** Concretely, in
`lib/dtu_app_web/live/dashboard_live.ex:1804`:

```elixir
apply_weather_snapshot(socket, fetch_weather_snapshot(user, local_date, x_min, x_max, tz))
```

becomes

```elixir
snapshot =
  try do
    fetch_weather_snapshot(user, local_date, x_min, x_max, tz)
  catch
    kind, reason ->
      require Logger
      Logger.warning(
        "[dashboard] inline weather snapshot failed (#{kind}: " <>
          "#{Exception.message(reason)}) — continuing with placeholders"
      )
      fetch_weather_snapshot(nil, local_date, x_min, x_max, tz)
  end
apply_weather_snapshot(socket, snapshot)
```

A 2-arg no-op `fetch_weather_snapshot/5` already returns the
placeholder defaults (via `assign_weather_placeholders/1`), so the rest
of the pipeline renders cleanly. The Task branch already had the same
fail-quietly contract; this brings the inline branch in line.

**(B) Soften the cache contention timeout** from the brittle 100 ms
default. The polling path in `Time.Cache`, `UserDtuIdsCache`, and
`SelectableDatesCache` is `@wait_max_attempts 50 × @wait_sleep_ms 2` =
100 ms. On a slow DB the first writer (e.g. the HTTP render's mount)
can exceed that, and the second arrival's `poll_for_value/2` raises
"DtuApp.Time.Cache contention timeout" (String exception). That
exception bubbles up through `Time.utc_now` and either: (i) inside the
LV WebSocket mount, crashes the LV ⇒ WS closes ⇒ flash fires.
Bumping `@wait_max_attempts` to 500 (= 1 s cap) covers a slow
mount without changing the fast-path cache behavior. This is the
single most-likely cause-on-honest-DB-delay; making it 10× looser
is essentially free.

I did not implement either — both are pre-implementation review
items and the user asked for the investigation proposal first.
