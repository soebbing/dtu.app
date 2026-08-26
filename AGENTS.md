This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - In both cases, a `@current_scope` is assigned to the Plug connection
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug as described below**

### Routes that require authentication

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->

# Project orientation: dtu.app

This section is the **project-specific orientation document** for
`dtu.app` (maintained by `@soebbing`). The Phoenix/Elixir/LiveView coding
rules above describe *how to write code in this framework*; this section
describes *what this app is*, *why it exists*, *how it's wired*, and *how
to ship a change*. Read this end-to-end before planning a non-trivial
change.

If anything here contradicts `docs/APP_STATE.md`, the *codebase* is the
source of truth — APP_STATE.md is a periodic snapshot, this doc reflects
the working tree, and the git log is the audit trail.

---

## 1. Purpose

`dtu.app` is a **self-hosted, multi-tenant solar telemetry service**
for owners of **OpenDTU** and **AhoyDTU** inverters (open-source
firmware for Hoymiles micro-inverters and similar), plus optional
**Shelly Plus 3EM (Gen3+)** energy meters.

The pitch in one sentence: it is the single BEAM release that replaces
the "glue Mosquitto + InfluxDB + Grafana + auth layer" stack that an
OpenDTU user would otherwise assemble by hand.

- **Bring your own hardware**: any device running OpenDTU / AhoyDTU
  firmware, or a Shelly Plus 3EM meter.
- **No separate broker**: an embedded MQTT broker (started in the same
  release) accepts uplinks directly — `dtu.app` *is* the broker.
- **Multi-tenant**: every user has isolated devices and readings; one
  release serves many households.
- **Time-series scale**: TimescaleDB hypertables + continuous aggregates
  keep years of readings cheap to store and fast to query.
- **Self-hosted-first** deployment story via Docker Compose, with TLS
  termination expected from an upstream reverse proxy (Traefik / Caddy
  / nginx / cloud LB).

The README is unapologetic that this is "early / hobby project under
active development". It's meant to be run by individuals or trusted
peers, not by anonymous strangers — multi-tenancy is by convention, not
row-level security (see §11).

---

## 2. Feature surface (what this app does)

### 2.1 Embedded MQTT broker

- An MQTT broker runs inside the same BEAM release so DTUs publish
  directly to `dtu.app`. There is no separate Mosquitto in front.
- Powered by the [`mqttx`](https://hex.pm/packages/mqttx) Hex package on
  top of [`thousand_island`](https://hex.pm/packages/thousand_island).
- **Module is `MqttX` (capital X).** Spelling it `Mqttx` won't compile.
- `MqttX.Server`'s `handle_connect/3` is arity-3 (`client_id`,
  `username`, `password`); calling the arity-2 form will fail at
  runtime. See `DtuApp.MqttBroker.Broker` for the wired impl.
- Default listen port `:1883` (plain TCP). TLS termination is expected
  upstream; the prod compose file references wrapping on `:8883` via
  Traefik.
- Only enabled in `:dev` and `:prod` — explicitly disabled in `:test`
  so the test suite never binds the broker port.
- Per-client `receive_maximum: 100`, `max_packet_size: 256_000` bytes,
  `server_keep_alive: 30` (overrides the client's keepalive so DTUs
  behind NAT/proxies stay alive).

### 2.2 Per-device MQTT credentials

- Every `Dtu` row carries one pair: `mqtt_username` (globally unique)
  and `mqtt_password_hash` (Argon2). Connections resolve to a single
  device by **username alone** — no `client_id` trust, no cross-tenant
  collision.
- `DtuApp.MqttBroker.Credentials` (a GenServer fronting ETS) caches
  `username => password_hash` and `username => %{id, user_id, kind,
  base_topic, name}` for `CONNECT`-time auth. Populated on broker
  boot; refreshed in place via `refresh/1` after every `Dtu`
  create/edit and `drop/1` after delete.
- `Argon2.no_user_verify/0` runs on a missed username match so the
  wall-clock cost of a missing user equals the cost of a matching one
  — constant-time auth path.
- Supported `kind` values: `:opendtu`, `:ahoydtu`, `:shelly3em`,
  `:mqtt_ro_sink`. Each carries its own default `base_topic`. The
  create dialog generates username + password automatically and shows
  the broker host/port/base-topic/credentials in a **post-create setup
  modal** the user copies into their DTU's MQTT settings.

### 2.3 Dual-format telemetry ingestion

A single in-process parser, `DtuApp.MqttBroker.Telemetry` (a GenServer
subscribed to `Phoenix.PubSub` topic `dtu:uplink`), routes by `kind`:

- **OpenDTU** — consolidated JSON on `{base}/{serial}/realtime/data`
  plus per-MPPT per-field topics (`[serial]/[1-9]/power`, …).
- **AhoyDTU** — scattered single-metric topics
  (`{base}/{name}/ch{0..6}/{Metric}`) plus a fleet-total on `{base}/total`.
- **Shelly Plus 3EM** — JSON on `{base}/status/em:0` (per-phase energy
  under `a_energy.total`, `b_energy.total`, `c_energy.total`).
- **mqtt_ro_sink** — raw-passthrough consumers of the broker we don't
  parse (used for diagnostics / dev rigs).

Recognised field schemas and the `(dtu_id, inverter_serial, mppt_index)`
keying are documented exhaustively in `docs/APP_STATE.md` §2.3. The
parsers share `DtuApp.Devices.create_reading_and_touch_power_at/1`,
which inserts the `Reading` **and** touches `dtus.last_power_at` so the
online indicators sync with current-power display (see §11).

### 2.4 Unified `Reading` schema and TimescaleDB storage

- Single `DtuApp.Devices.Reading` schema for all kinds.
- Composite PK `(dtu_id, inverter_serial, mppt_index, inserted_at)` —
  no serial `id`. The PK exists only because TimescaleDB requires the
  partitioning column in every unique index.
- `:utc_datetime_usec` everywhere. Writes use the DB clock via
  `DtuApp.Time.utc_now_usec/0` so the value that gets bucketed matches
  the value the dashboard compares against. PK collisions bump
  `inserted_at` by 1 µs (up to 1 ms of attempts).
- `readings` is a **TimescaleDB hypertable** keyed on `inserted_at`:
  - 7-day chunk interval, 7-day compression policy (segment by
    `dtu_id`), 365-day retention.
  - Three **continuous aggregates**: `readings_5m`, `readings_hourly`,
    `readings_daily`, each `WITH NO DATA` at create and refreshed by
    policies that union recent raw rows.
  - The dashboard prefers aggregates when feasible; some stat-card
    queries still hit `readings` directly (`MAX(yield_day)` over a day
    is cheap, and routing it through a cagg is more code than savings).
- Companion migration sets `DEFAULT now()` on every timestamp column
  so any direct `INSERT` that omits a value still gets the DB clock.

### 2.5 Dashboard (`Phoenix.LiveView`)

`DtuAppWeb.DashboardLive` mounts at `/dashboard` and carries the
home-screen experience. Subscribes (when connected) to:

- `dtu:reading` — every parsed reading pushes an immediate re-render.
- `dtu:status` — `:dtu_seen` re-streams the device list.
- `dtu:presence` — CONNECT / DISCONNECT events.
- `dtu:timezone` — colocated JS hook pushes the user's UTC offset so
  day boundaries render in their local timezone.
- `user:notification:<id>` — receives `:notification` events fanned
  from `DtuApp.Notifications.broadcast/2` and forwards them to the
  page's `phx-hook="Notifications"` sink.

**View modes** — Today (live, auto-refreshing) and a **Historical
stepper** (granularity day/week/month/year driven by `time_range` /
`selected_period`). Each granularity has its own stat-card layout.
A **DTU switcher** narrows the aggregate to one device; `nil` means
"all devices", the literal `"total"` from the UI is mapped to `nil`.

**Charts are server-rendered SVG** (no Chart.js, no D3). Bucketing is
pure Elixir in `DtuApp.Devices.list_day_chart_data/4`. Y-axis labels go
through `format_number/2` so a German user gets `1.234,5` and a
French user gets `1 234,5`.

TZ-aware stat reads: every day-window query is built from the user's
offset using `DtuApp.Devices.local_day_utc_range/2`.

### 2.6 Devices management (`/devices`)

`DtuAppWeb.DeviceLive.Index` — Live, in-browser CRUD over a stream.
Per-row controls: edit name/kind, details link, delete with confirm.
The **post-create setup dialog** opens the first time a device is
added.

The **expansion panel** under any device row surfaces the per-device
error history (last 48 hours, distinct message count with last-seen
timestamp and occurrence count). Bookmarkable via `?expand=<dtu_id>`;
bad ids silently collapse to "no panel" rather than 404.

### 2.7 Device details (`/devices/:id/details`)

Live view of every MQTT topic + payload the device is publishing,
including topics the parser doesn't interpret — built from
`DtuApp.MqttBroker.TopicRegistry.get_topics_for/1`.

- ETS-backed `:public` table keyed on `dtu_id`, value is
  `%{topic => {payload, received_at}}`.
- Per-DTU FIFO eviction at 200 topics (so a misbehaving firmware
  doesn't OOM the BEAM); per-payload truncation at 4 KB with a trailing
  `…`.
- Prune tick every 60 s drops entries older than 300 s (matches the
  online-offline threshold).
- Subscribes to `dtu:uplink` independently from the parser — a slow
  parser never back-pressures the live-topic capture.
- A second column reuses `DtuApp.Devices.list_dtu_error_groups/1`,
  filtered to the same device.

### 2.8 Notifications

The `/notifications` LiveView exposes three toggles:

- `notify_dtu_connection` — push when an inverter's online state
  changes (with `dtu_connection` deduplication; see §11).
- `notify_sun_down` — end-of-day summary comparing today's yield + peak
  vs. yesterday.
- `notify_sun_up` — playful first-power ping at sunrise when nightly
  zero-state ends.
- "Send test notification" button (only enabled when permission state
  is `granted`).

**Two delivery paths**:

- **In-page** — `DtuAppWeb.UserNotifications.broadcast/2` publishes to
  `user:notification:<id>`; the dashboard's colocated `Notifications`
  JS hook receives it and calls `new Notification(...)` after
  deduplicating by `tag` in `localStorage`.
- **Native** — `DtuApp.Push.deliver/2` looks up every
  `push_subscriptions` row for the user, signs (VAPID, RFC 8292),
  encrypts (AES-128-GCM, RFC 8291), and POSTs via Finch to the user's
  push service (FCM, Mozilla autopush, Apple). HTTP 404/410
  (`{:error, :gone}`) deletes the row; other errors log and continue.

VAPID keypair is generated idempotently by `bin/gen-vapid` (writes to
`.env`; `--force` is required to overwrite because rotation
**invalidates every browser subscription** for the origin and silently
breaks notifications).

**Producer requirements** (every `DtuApp.Notifications.*` GenServer
that emits a `Notifications.broadcast/2` call MUST satisfy all three):

1. **Producer-level preference gate.** Before any
   `Notifications.broadcast/2`, the producer MUST check
   `User.notify_<event> == true` against the resolved `%User{}`
   struct (not just `user_id`). A `false` toggle suppresses the
   entire flow: no in-page PubSub event, no native push, no
   `notifications` history row, no dedup-table insert. The
   receiver-side `Notifications.broadcast/2` already gates
   *native push* via `native_push_enabled?/2`, but always
   publishes the in-page event and records the history row —
   that's the wrong contract for these notifications, which
   the user explicitly wants "off = silent everywhere".

   The preference flag is on `User` (`accounts/user.ex` lines
   13-19); all default to `false` so existing users don't
   silently start receiving notifications on deploy.

2. **Persistent, DB-backed dedup.** "Once per local day"
   producers MUST persist the per-user fired-on-date marker
   in a dedicated table keyed by `(user_id, fired_on)` (e.g.
   `sun_up_fires`, `sun_down_fires`). Insert *before*
   broadcasting; a second insert on the same day raises
   `Ecto.ConstraintError`, which the producer MUST swallow
   to mean "already fired today — no-op." Use
   `on_conflict: :raise` + `catch :error,
   %Ecto.ConstraintError{}`, NOT `on_conflict: :nothing`,
   because the schemas use `@primary_key false` (no serial
   id), so Ecto omits `RETURNING` and `:nothing` returns
   `{:ok, %Schema{}}` for both success and conflict — it
   can't distinguish the two.

   This replaces the previous in-memory `state.users[…]`
   dedup cache, which was wiped on every GenServer restart
   (deploy, crash, application restart) and produced
   duplicate banners the next time the producer ran.

   For "once per session" producers (e.g. `DtuConnection`,
   which fires on each CONNECT↔DISCONNECT transition), the
   analogous persistence surface is a per-device marker
   table (e.g. `dtu_connection_states` keyed on `device_id`).
   Same motivation: without persistence, a restart wipes the
   in-memory marker and lets the very next `:dtu_connected`
   for a device that was already on the broker at boot fire
   `:back_online` — a duplicate "your inverter is
   publishing telemetry again" push.

3. **Structured `[push]` log lines.** `DtuApp.Push.send_to/2`
   MUST emit a `[push] gone event=… user_id=… endpoint_host=…`
   or `[push] failed …` line on every per-subscription error,
   so the operator has a signal in `journalctl` / `grep`-able
   logs when a push delivery silently drops. The log lines
   are the operator's only signal — per-subscription errors
   don't bubble up to the caller of `deliver/2`. VAPID
   short-circuit and user-preference no-ops MUST NOT emit
   these lines (covered by `PushTest`).

Producers in scope today: `Notifications.SunUp`,
`Notifications.SunDown`, `Notifications.DtuConnection`. Any
new producer (e.g. a future "PV voltage warning") MUST satisfy
the same three requirements before merging.

### 2.9 Service worker / PWA

`priv/static/service-worker.js` is fingerprinted by `mix phx.digest` and
**intentionally not bundled by esbuild** — kept dependency-free and
portable across browsers. Three concerns:

1. **Tier-2 static cache** for offline reads.
2. **Push event handling** — receives VAPID-signed push payloads from
   the server and shows the OS banner.
3. **notificationclick** — routes the user back to the dashboard via
   `data.url` on the payload.

Root layout registers a `manifest.webmanifest`, `apple-touch-icon`,
and theme-color metadata.

### 2.10 i18n

Gettext PO files under `priv/gettext/{en,de,fr,default.pot,errors.pot}`.
`DtuAppWeb.Plugs.Locale` lives in the `:browser` pipeline and the
`live_session :current_scope`, reading the locale from the Gettext
backend. Users' preferred locale is persisted on `users.locale`
(migration `20260824120000_add_locale_to_users.exs`) and applied at
sign-in. Number formatting (`format_number/3`) is locale-aware:
`en → 1,234.5`, `de → 1.234,5`, `fr → 1 234,5` (NBSP per AFNOR/DIN).

---

## 3. Architecture

### 3.1 Tech stack

| Layer        | Choice                                                          |
| ------------ | --------------------------------------------------------------- |
| Language     | Elixir 1.16.2 / OTP 26.2.2                                      |
| Web          | Phoenix 1.8 + LiveView 1.2, served by Bandit                    |
| Realtime     | Embedded MQTT broker (`mqttx`) over `thousand_island`           |
| Database     | PostgreSQL 16 + TimescaleDB (hypertables + caggs)               |
| ORM / schema | Ecto 3.13 + Ecto SQL                                            |
| Auth         | `phx.gen.auth` (magic link + Argon2 password)                   |
| Mail         | Swoosh → Resend / SMTP (Mailpit) / Local                        |
| Web Push     | `web_push` (VAPID/AES-128-GCM) + `finch`                        |
| Realtime UI  | LiveView streams; colocated JS hooks (`Phoenix.LiveView.ColocatedHook`) |
| Assets       | Tailwind CSS v4 (no `tailwind.config.js`), esbuild 0.25.4, Heroicons v2 |
| Tests        | ExUnit (server) + `@playwright/test` (E2E)                      |
| Schedules    | Manual — no Quantum / Oban in this codebase today              |

### 3.2 Supervision tree

`DtuApp.Application` is a `:one_for_one` supervisor. Children, in
start order:

1. `DtuAppWeb.Telemetry` — BEAM telemetry supervisor + poller.
2. `DtuApp.Repo` — Ecto connection pool.
3. `DNSCluster` — only when `dns_cluster_query` is configured.
4. `Phoenix.PubSub` named `DtuApp.PubSub` — single PubSub for **every**
   cross-process message: uplinks, readings, status, presence,
   per-user notifications, timezones, topic snapshots.
5. `Finch, name: DtuAppWeb.WebPushFinch` — dedicated HTTP pool for
   web-push traffic (so a slow push service can't back up unrelated
   HTTP work).
6. `DtuApp.MqttBroker.Credentials` GenServer (when broker enabled).
7. `MqttX.Server` named `DtuApp.MqttBroker.Broker`.
8. `DtuApp.MqttBroker.Telemetry` — parser; must start *after* PubSub
   so it can subscribe on init.
9. `DtuApp.MqttBroker.TopicRegistry` — independent parser companion
   that subscribes to `dtu:uplink` for the device-details page.
10. `DtuAppWeb.Endpoint` — Bandit / Phoenix endpoint, last.

### 3.3 Data flow for one live reading

1. DTU opens MQTT connection to `:1883` with its Argon2-hashed
   credentials.
2. `MqttBroker.Broker.handle_connect/3` resolves the username to a
   `Dtu` via the ETS cache, subscribes its own process to
   `dtu:downlink:<client_id>`, broadcasts `:dtu_connected`.
3. On each `PUBLISH`, the broker's `handle_publish/4` re-broadcasts on
   `dtu:uplink` with the parsed `client_id` and authenticated device
   info.
4. `Telemetry` consumes the uplink, routes to the per-`kind` parser,
   converts to a `Reading` (or `buffer → flush` round), inserts via
   `Devices.create_reading_and_touch_power_at/1`, then broadcasts
   `:reading` on `dtu:reading`.
5. `DashboardLive` (subscribed) re-renders the affected stat / chart
   point within a few hundred ms.
6. `TopicRegistry` (also subscribed) records the payload and
   broadcasts `:topic_seen` so the device-details LiveView (if open)
   refreshes.
7. Telemetry touches `dtus.last_seen_at` and `dtus.last_power_at`,
   broadcasts `:dtu_seen` so subscribed device lists re-render
   online indicators.
8. Native Push (when configured): parallel to all of the above,
   `Notifications.broadcast/2` fans events onto per-user PubSub topics
   and `Push.deliver/2` POSTs VAPID-signed, AES-encrypted payloads.

### 3.4 Module layout

```
lib/dtu_app/
  application.ex              OTP supervisor, conditional MQTT broker
  mailer.ex                   Swoosh adapter glue
  repo.ex                     Ecto.Repo
  release.ex                  DtuApp.Release.migrate/rollback
  time.ex                     DB-clock helpers (utc_now/utc_now_usec)
  accounts.ex                 Generated auth context
  accounts/{user,user_token,user_notifier,scope}.ex
  devices.ex                  DTU/Reading contexts (all user-scoped)
  devices/{dtu,reading,dtu_error}.ex
  mqtt_broker/
    broker.ex                 MqttX.Server impl, uplink broadcast
    credentials.ex            ETS-backed Argon2 cache
    telemetry.ex              Parser GenServer (OpenDTU/AhoyDTU/Shelly)
    topic_registry.ex         Live topic snapshot (ETS + 60 s prune)
  notifications.ex            Per-user PubSub + Web Push fan-out
  push.ex                     Web Push dispatcher (VAPID, AES-128-GCM)
  push_subscriptions.ex       PushSubscription CRUD
  push_subscriptions/push_subscription.ex

lib/dtu_app_web/
  endpoint.ex                 Bandit / Phoenix endpoint
  router.ex                   Browser + push_api + magic-link pipes
  telemetry.ex                BEAM telemetry supervisor + metrics
  user_auth.ex                fetch_current_scope / require_auth / redirect
  gettext.ex
  components/{core_components,layouts,layouts/root,network_status_indicator,offline_banner}.ex
  plugs/locale.ex             Gettext locale negotiation
  controllers/{page,user_registration,user_session,user_settings,push}_controller.ex
  live/{dashboard_live,device_live/index,device_live/details,notifications_live}.ex

assets/
  css/app.css                 Tailwind v4 entry
  js/{app,notifications,push_subscribe,notification_permission,offline_banner}.js
  vendor/{heroicons,topbar}.js
  service-worker.js           PWA + push listener (not bundled)

priv/repo/
  migrations/                 (22 migrations; see §10)
  seeds.exs                   Demo user + 3 DTUs + sine-arc readings

priv/gettext/{en,de,fr}/LC_MESSAGES/default.po + default.pot + errors.pot
rel/docker-entrypoint.sh      Run migrations, then exec the release
bin/gen-vapid                 Generate VAPID keypair, write to .env
```

---

## 4. Local development

### 4.1 Prerequisites

- **Erlang/OTP 26.2.2** and **Elixir 1.16.2**. CI uses
  `erlef/setup-beam@v1` to pin; locally, asdf or kiex works fine.
- **Node.js 20** (CI uses `actions/setup-node@v4`).
- **PostgreSQL 16 with TimescaleDB**, either the
  `timescale/timescaledb:latest-pg16` compose sidecar (recommended for
  parity with prod) or a system Postgres with the TimescaleDB extension
  loaded — required because two migrations call `create_hypertable/2`.

### 4.2 Bring-up

```sh
mix setup          # deps.get + ecto.setup + assets.setup + assets.build
mix phx.server     # http://localhost:4000   ; broker also binds :1883 in :dev
```

`mix setup` runs `mix deps.get`, `mix ecto.setup` (create + migrate +
seed), `mix assets.setup` (tailwind + esbuild install if missing),
`mix assets.build`. `mix ecto.reset` is the hard reset (drop + setup).

### 4.3 Asset pipeline

- **esbuild** (0.25.4) bundles `assets/js/app.js` and collaborators
  (`notifications.js`, `push_subscribe.js`, `offline_banner.js`,
  `notification_permission.js`) into `priv/static/assets/js`.
- **Tailwind v4** (4.3.0) compiles `assets/css/app.css`. No
  `tailwind.config.js` — the `@import "tailwindcss" source(none);
  @source …;` form is the convention.
- **Heroicons v2.2.0** — vendored as `assets/vendor/heroicons.js`,
  rendered via `<.icon name="hero-…" />` from `core_components.ex`.

### 4.4 Capturing email locally

The Docker Compose stack ships a Mailpit sidecar; the in-memory
mailer is the default otherwise:

```sh
docker compose up -d mailpit
MAIL_DELIVERY=mailpit SMTP_RELAY=localhost SMTP_PORT=1025 mix phx.server
# Open http://localhost:8025
```

### 4.5 What won't work in NixOS

Playwright's bundled Chromium needs libs that aren't on the standard
NixOS profile. Set `PLAYWRIGHT_CHROME=$(which google-chrome)` before
running the E2E specs. The bundled Chromium will start but immediately
fail to render anything.

---

## 5. Testing strategy

### 5.1 ExUnit (server-side)

`mix test` runs in the `Ecto.Adapters.SQL.Sandbox` Pool, with
`argon2_elixir` cost dropped (`t_cost: 1, m_cost: 8`) so password
hashing tests don't take seconds each. `:test` disables the MQTT
broker (`config :dtu_app, :mqtt_broker, enabled: false`) so nothing
binds `:1883`. Mailer is `Swoosh.Adapters.Test` in `:test`.

**Use `start_supervised!/1` for processes under test;
`Process.monitor/1` + `assert_receive {:DOWN, …, :normal}` for awaiting
termination — never `Process.sleep/1`.**

ExUnit files live alongside the modules they cover:
`test/dtu_app/{accounts,devices,mqtt_broker,push,push_subscriptions,time}_test.exs`
and `test/dtu_app_web/{controllers,live,plugs,components}/...`.

### 5.2 Playwright (E2E)

Driven by `@playwright/test` (`playwright.config.js`). Targets
**Chromium** by default; honours `PLAYWRIGHT_CHROME` for NixOS. Fully
parallel, retries = 2 in CI.

A `globalSetup` (`test/e2e/_setup/global-setup.js`) re-seeds via
`mix run priv/repo/seeds.exs` once before any spec runs. Set
`E2E_SKIP_SEED=1` to skip when iterating against an already-seeded
DB. Specs assume the app is reachable at `http://localhost:4000` with
seeded credentials (`test@example.com` / `password123456`), three
DTUs, today's sine arc + historical readings from ~1 year back.

Spec coverage includes: login + dashboard landing, post-create setup
dialog, the Today / Day / Week / Month / Year stepper, multi-device,
multi-MPPT, the savings card / energy rate, settings, the
notifications page and permission UI, and the magic-link flow.

**Always run with the Phoenix server already up — the global setup
only re-seeds, it doesn't boot the app.**

### 5.3 Pre-commit

```sh
mix precommit      # compile --warnings-as-errors + deps.unlock --unused + format + test
```

This is the CI's local-equivalent sanity check.

---

## 6. Delivery: CI, release, deploy

### 6.1 CI (`.github/workflows/ci.yml`)

Triggers on **push and PR to `main`** — both run the same workflow.
Two jobs: `test` (a.k.a. `Build & Test`) and `build-docker`.

The merge gate for a PR is **the `Build & Test` job** on the PR's own
run, **not** the run on `main` after merge and **not** the CodeQL
check runs that show up alongside it. CodeQL is informational — it
runs in parallel and will pass independently of `Build & Test`. A PR
that breaks `Build & Test` will not merge; a PR that breaks CodeQL
alone is at the maintainer's discretion.

If you find yourself looking at a CI summary that shows
`Analyze (actions)` / `Analyze (javascript-typescript)` / `CodeQL` all
green but the PR still says "waiting for checks", `Build & Test` is
the one to look at.

`Build & Test` spins up `timescale/timescaledb:latest-pg16` on `:5432`
and `axllent/mailpit:latest` on `:1025`+`:8025`. Steps:

1. Checkout + `erlef/setup-beam@v1`.
2. Cache `deps`/`_build` keyed on `mix.lock`.
3. `mix deps.get`, `mix format --check-formatted`,
   `mix compile --warnings-as-errors` (`MIX_ENV=test`).
4. `mix test` — ExUnit, with the sandbox pool, dropped Argon2 cost,
   broker disabled.
5. Node 20 setup + cache `~/.cache/ms-playwright`.
6. `npm ci`, `npx playwright install --with-deps chromium`.
7. `mix assets.deploy`.
8. `mix ecto.create` + `mix ecto.migrate` + `mix run priv/repo/seeds.exs`
   (production DB schema/seed for the E2E run).
9. Boot the prod-mode Phoenix server (`PORT=4000 mix phx.server`)
   into `phx.log`, wait up to 60 s for `http://localhost:4000`.
10. **`npm run test:e2e` — Playwright Chromium against the prod-mode
    server. This is the merge gate; it does not run on a separate
    workflow.** On failure: dump `phx.log` and upload
    `playwright-report/` (30-day retention).

`build-docker` runs only when `Build & Test` succeeded; builds the
multi-stage Dockerfile and uploads a `.tar` for 7 days.

### 6.2 Release pipeline

`.github/workflows/release.yml` triggers on `tags: *`. Builds the
Dockerfile, pushes to `ghcr.io/<owner>/dtu-app` with both
`${{ github.ref_name }}` and `latest` tags, creates a GitHub Release
with auto-generated notes.

`.github/workflows/release-dispatch.yml` is a `workflow_dispatch`
maintainer workflow that:

1. Validates the calver `YYYY-MM-DD-N` tag (optionally `v`-prefixed).
2. Refuses to proceed if the tag already exists.
3. Authenticates with a `RELEASE_TOKEN` PAT (not `GITHUB_TOKEN`,
   because GitHub suppresses events triggered by the workflow's own
   token) and pushes the tag, causing `release.yml` to run.

**Calver format:** `v2026-07-26-1` (leading `v` is optional). In a
single day the `-N` counter increments (`2026-08-26-1`, `…-2`, …).

`RELEASE_VERSION` is baked into the image at build time (ARG) and
surfaces as the in-app footer version string.

### 6.3 Docker — local (`docker-compose.yml`)

Three services with named volumes:

```yaml
db:        timescale/timescaledb:latest-pg16  (:5432)
mailpit:   axllent/mailpit:latest              (:1025 SMTP, :8025 UI)
app:       built from ./Dockerfile             (:4000 HTTP, :1883 MQTT)
```

The `app` service depends on both via `condition: service_healthy`.
The release image runs migrations on every start (`rel/docker-entrypoint.sh`
retries `DtuApp.Release.migrate` 10× over 30 s before giving up).

### 6.4 Docker — production (`docker-compose.production.yml`)

Pulls the image from GHCR (default tag `:latest`, overridable via
`IMAGE_TAG=v2026-07-26-1`). No host port mapping — the reverse proxy
reaches the app on the `internal` bridge network. Comment-in
`1883:1883` for setups where DTUs reach the broker directly.

Behind TLS (Traefik / Caddy / nginx / cloud LB). `PHX_SCHEME=https` +
`PHX_PORT=443` are conventional when fronted by a TLS terminator.

### 6.5 Dockerfile (multi-stage release)

- **Builder stage** on `hexpm/elixir:1.16.2-erlang-26.2.1-alpine-3.19.1`:
  installs `build-base git curl ca-certificates`,
  `mix deps.get --only $MIX_ENV` with `MIX_ENV=prod`, copies
  `config/config.exs` + `config/prod.exs` for dep compilation, runs
  `mix deps.compile`, then `priv`+`lib`, `mix compile
  --warnings-as-errors`, `assets`, `mix assets.deploy`,
  `config/runtime.exs`, `ARG RELEASE_VERSION="dev"` →
  `ENV RELEASE_VERSION=…`, then `mix release` produces
  `_build/prod/rel/dtu_app`.
- **Runtime stage** on `alpine:3.19.1`: `libstdc++ openssl
  ncurses-libs ca-certificates`, copies only the final release,
  copies `rel/docker-entrypoint.sh`, `USER nobody`, `ENV HOME=/app`,
  `ENTRYPOINT ["/app/docker-entrypoint.sh"]`.

The entrypoint reconciles schema on every container start without
needing a separate command override.

---

## 7. Required environment variables (prod)

These are the ones the runtime refuses to start without in `:prod`,
plus the rest that are conventional:

| Var                       | Required in prod? | Purpose                                                        |
| ------------------------- | ----------------- | -------------------------------------------------------------- |
| `SECRET_KEY_BASE`         | yes               | Cookies / LiveView sockets. `mix phx.gen.secret`.               |
| `PHX_HOST`                | yes               | Public hostname — drives URL generation.                       |
| `PHX_SCHEME`              | no (default `https`) | `http` (local) / `https` (prod). Drives URL generation.     |
| `PHX_PORT`                | no (default `443`) | Public port; only included in URLs when non-standard.         |
| `DATABASE_URL`            | yes               | `ecto://USER:PASS@HOST/DB`.                                    |
| `POOL_SIZE`               | no (default `15`) | DB pool size.                                                  |
| `MQTT_BROKER_ENABLED`     | no (default `true`) | Toggle the embedded broker. `:test` overrides to false.     |
| `MQTT_BROKER_PORT`        | no (default `1883`) | Broker listen port.                                          |
| `MQTT_HOST`               | no                | DNS alias shown as broker host in device setup modal.          |
| `RESEND_API_KEY`          | optional          | Resend transactional email when set.                           |
| `MAIL_DELIVERY=mailpit`   | optional          | Route via Mailpit (dev/staging).                              |
| `SMTP_RELAY/PORT/DOMAIN`  | dev               | Mailpit connection settings.                                   |
| `MAIL_FROM`               | yes (prod)        | Must be on a Resend-verified domain in prod.                   |
| `VAPID_PUBLIC_KEY`        | yes (prod)        | Web Push public key. `bin/gen-vapid`.                          |
| `VAPID_PRIVATE_KEY`       | yes (prod)        | Web Push private key.                                           |
| `VAPID_SUBJECT`           | yes (prod)        | `mailto:` or `https:` URL — RFC 8292 §2 requires it.           |
| `RELEASE_VERSION`         | build-time        | Git tag baked into the image; footer renders this.              |
| `DNS_CLUSTER_QUERY`       | optional          | DNS-based Node clustering (`<env>.internal` libcluster query).  |
| `ECTO_IPV6`               | optional          | Use IPv6 for the DB pool.                                      |

Mailer adapter is picked in order in `config/runtime.exs`:

1. `RESEND_API_KEY` non-empty → `Swoosh.Adapters.Resend`.
2. `MAIL_DELIVERY=mailpit` → `Swoosh.Adapters.SMTP` (via SMTP_RELAY).
3. Neither → `Swoosh.Adapters.Local` (emails swallowed; magic-link
   URL appears in server logs / IEx).

---

## 8. Database schema (relational, non-TimescaleDB)

Beyond the TimescaleDB-managed `readings` hypertable:

- **`users`** — magic-link auth (`phx.gen.auth` shape). Notable fields:
  `cents_per_kwh` (integer-cent rate), `notify_dtu_connection`,
  `notify_sun_down`, `notify_sun_up`, `locale`, `confirmed_at`,
  `authenticated_at`.
- **`dtus`** — physical DTU records. Notable columns:
  `mqtt_username` (unique), `mqtt_password_hash` (Argon2), `kind`
  (Ecto.Enum: `:opendtu | :ahoydtu | :shelly3em | :mqtt_ro_sink`),
  `base_topic`, `last_seen_at` (`:utc_datetime_usec`),
  `last_power_at` (`:utc_datetime_usec` — see §11), `last_error`,
  `last_error_at`. One row → many readings.
- **`users_tokens`** — `phx.gen.auth` token table; contexts
  `session`, `login`, `change:email`.
- **`dtu_errors`** — append-only per-message error history, capped at
  200 rows per device via in-transaction FIFO prune.
- **`notifications`** — `notify_dtu_connection` history rows (used for
  cross-device deduplication).
- **`push_subscriptions`** — Web Push subscription rows; the browser's
  `PushSubscription#toJSON()` payload is persisted verbatim minus
  `expirationTime`. Globally unique `endpoint` is the natural primary
  key for upsert.

The 22 migrations are catalogued in `docs/APP_STATE.md` §8 (chronological
intent); read the directory directly for current state.

---

## 9. Multi-tenant isolation

- Every `DtuApp.Devices` function takes a `%User{}` and adds an
  ownership predicate. `mqtt_broker.Credentials.verify/2` resolves a
  connection to a device by username alone and the broker carries the
  device's `user_id` through to the parser.
- There is no cross-tenant data path — every read and write
  originates from `current_scope.user`.
- **Multi-tenancy is by convention, not row-level security.** A future
  hardening step might add Postgres RLS policies; today's guarantee
  is "every context function guards on `user_id`."
- This app is meant to be run by individuals or trusted peers, not by
  anonymous strangers — see §1.

---

## 10. Known constraints and operational gotchas

These are the things the next maintainer should know before they
"fix" something:

1. **Online / offline indicators are gated on `last_power_at`, not
   `last_seen_at`.** A DTU whose MQTT session is alive but whose
   inverter isn't reporting AC power is shown **offline everywhere**
   (dashboard pill, device-list dot, device-details pill, error badges).
   `Dtu.online?/2` (last_seen_at-based, 5-min threshold) and
   `Dtu.producing_power?/2` (last_power_at-based, 2-min threshold)
   both exist; the live UI uses `producing_power?/2`. The 2-minute
   threshold is `Dtu.power_threshold_seconds/0` (was `@power_threshold_seconds`
   pre-extraction).
2. **The `last_power_at` write site is `Devices.create_reading_and_touch_power_at/1`**,
   called from all three parser flush sites in `mqtt_broker/telemetry.ex`.
   Any new reading-write path must call this wrapper or the indicator
   will silently drift offline.
3. **Notifications "silently don't arrive" is rarely a preference
   problem.** In order of likelihood:
   - **iOS PWA not installed to Home Screen** — iOS doesn't deliver
     push to a saved-tab PWA until the user adds it to Home Screen
     and reopens it from there. The notification *preference* is
     already on; the runtime just can't reach the device.
   - **Stale push endpoint** (`{:error, :gone}`) — auto-pruned by
     `Push.deliver/2`. Look for `:gone` in logs; the user must grant
     permission again.
   - **VAPID key rotation** invalidates every subscription —
     `bin/gen-vapid` requires `--force` to overwrite for this reason.
   - **Cross-device dtu_connection dedup TTL is 5 minutes**
     (`NOTIFICATION_DEDUP_SECONDS`) so a DTU that flaps doesn't
     spam. Bumping this is a config change, not a code change.
4. **VAPID keys live in `.env`.** Rotating them breaks every browser
   subscription for the origin until users re-grant permission. Do
   not rotate casually.
5. **`mix precommit` refuses things that aren't actually wrong.**
   `compile --warnings-as-errors` will fail on a deprecation warning
   you can't fix in this codebase. Read the warning, decide whether
   it's coming from a dep or your code.
6. **`mqttx` and `thousand_island` print `optional dependency` warnings
   for `:ranch` and `:protox` on boot. This is expected.** The broker
   uses Thousand Island directly and ignores the unused deps. Don't
   add them to silence the warnings — the package author chose that
   surface intentionally.
7. **The `MqttX` module is capital-X.** Spelling it `Mqttx` or `MQTTX`
   won't compile.
8. **The MQTT broker uses `MqttX`** (a relatively niche Hex package).
   Rebuilding this app against a different embedded broker (EMQX-in-
   Elixir, VerneMQ-in-Erlang, or a Mosquitto sidecar) requires
   touching `DtuApp.MqttBroker.{Broker,Credentials,Telemetry,TopicRegistry}`.
9. **Playwright on NixOS** — set
   `PLAYWRIGHT_CHROME=$(which google-chrome)`. The bundled chromium
   won't run (missing libs); tests will silently skip if you don't.
10. **TimescaleDB is non-negotiable.** Two migrations call
    `create_hypertable/2`. Plain Postgres won't get past
    `ecto.migrate`.
11. **Service worker is intentionally not bundled by esbuild.** It's a
    dependency-free portable file fingerprinted by `mix phx.digest`.
    Don't move it into `assets/`.
12. **Argon2 in tests** uses dropped costs (`t_cost: 1, m_cost: 8`) —
    `mix test` stays under 20 s. Any new auth-touching test should
    accept this and not try to re-tweak the cost.
13. **CI runs `:prod`-mode Phoenix for E2E** (`PORT=4000 mix phx.server`).
    The prod runtime, including the Swoosh adapter selection, PubSub
    topology, and asset-digest pipeline, is exercised on every push.

---

## 11. Architectural gotchas (the non-obvious bits)

- **`producing_power?/2` has the same shape as `online?/2`** (mirrors
  the last-touched-timestamp check) so it can be swapped in at every
  call site without touching call-site code. The migration to
  `last_power_at` (`20260826120000_add_last_power_at_to_dtus.exs`)
  was the foundation; switching the surface was the rest of the work
  in PRs #162 and #163.

- **`Dtu.online?/2` and `Dtu.producing_power?/2` both still exist.**
  Don't delete the first one unless you're sure no consumer remains
  — and grep exhaustively. They have different threshold semantics
  for legitimate reasons (5 min for "we've heard from this DTU at
  all" vs 2 min for "it's currently generating").

- **Power-side freshness window is shorter than online-side freshness
  window on purpose.** A DTU whose inverter is in standby at night
  should *still* be reachable (its LWT is alive), but not "producing".
  Two thresholds, two answers, no contradiction.

- **All three `*_online?/2`-style predicates use the DB clock** via
  `DtuApp.Time.utc_now/0`. Don't write a "now" argument from
  `DateTime.utc_now/0` in a test — drift will silently flip the answer.

- **The `Reading` schema has no serial PK.** It's a TimescaleDB
  requirement (partitioning column must be in every unique index)
  and the app never round-trips a reading by id. Don't add `id` back
  "for cleanliness" — it would break every continuous aggregate.

- **`daisYUI` is not used.** Tailwind utilities are written by hand in
  every template. An agent suggesting "let's use a `card` component
  from daisyUI" is applying a default template assumption; ignore it.

- **The Onboarding/Setup modal is a LiveView modal, not a JS modal.**
  Deleting the device returns the user to the index; the modal state
  lives in an assign.

- **The `phx.gen.auth` generator's `current_scope` assign is the only
  way to access the current user.** `@current_user` does not exist.
  If you hit a `current_scope` error, you either routed into the
  wrong scope or forgot to pass `current_scope` to `<Layouts.app>` —
  fix it at the route, not in the template.

- **The `date_time_parser` package is the standard dependency for
  date/time parsing.** Don't introduce `timex` / `calendar` /
  moment.js analogues.

---

## 12. Deployment runbook (quick reference)

### 12.1 First deploy on a fresh host

```sh
git clone https://github.com/soebbing/dtu.app.git
cd dtu.app
cp .env.example .env
./bin/gen-vapid                    # writes VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT
$EDITOR .env                      # fill SECRET_KEY_BASE, MAIL_FROM, RESEND_API_KEY
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d
docker compose -f docker-compose.production.yml logs -f app
# Wait for the "Running DtuAppWeb.Endpoint at…" line.
```

### 12.2 Updating to a new release

```sh
# Option A — pin to a specific calver (recommended for a few days after release):
echo "IMAGE_TAG=v2026-08-26-4" >> .env
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d

# Option B — track :latest (rolls forward on every release):
docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d
```

The entrypoint runs migrations on every start, so a release is just a
new image tag.

### 12.3 Rolling a new release

1. Open a PR, get CI green, merge to `main`.
2. Tag and push:

   ```sh
   git tag 2026-08-26-5
   git push origin 2026-08-26-5
   ```

   Or use the **Actions → Create release → Run workflow** button on
   the maintainer workflow (`.github/workflows/release-dispatch.yml`).
3. The tag push triggers `.github/workflows/release.yml`, which builds
   the Dockerfile, pushes to GHCR with both `2026-08-26-5` and
   `latest` tags, and creates a GitHub Release with auto-generated
   notes.

### 12.4 Backing up state

`docker compose … volumes` shows `dtu_app_pgdata` as the only
persisted volume. Snapshot it; everything else (Mailpit, the app
container) is stateless.

---

## 13. Where to find more

- `docs/APP_STATE.md` — periodic "snapshot" doc, ~1064 lines, the
  closest thing this repo has to an architecture decision record.
  Read it once per quarter; trust the codebase over it.
- `priv/repo/migrations/` — 22 migrations; the chronological record.
- `docs/superpowers/` — project-private planning notes (the
  `superpowers` skill tooling).
- `test/e2e/README.md` — Playwright setup specifics.
- GitHub Actions:
  - `.github/workflows/ci.yml` — CI.
  - `.github/workflows/release.yml` — tag-triggered release.
  - `.github/workflows/release-dispatch.yml` — maintainer button.
- Project memory:
  `/home/hendrik/.claude/projects/-home-hendrik-Code-dtu-app/memory/`
  has 6 cross-session memories covering purpose, the locked
  architecture, real storage state, broker-module spelling, expected
  broker warnings, NixOS Playwright, and notification silent-drop
  causes.
