# Find eligible builder image.
#
# Pinned to Elixir 1.18+ because `web_push ~> 0.1` calls the bare
# `JSON.encode!/1` / `JSON.encode!/0` modules — that's Elixir 1.18's
# built-in JSON stdlib module, NOT OTP's `:json` (Erlang 27+) and NOT
# the third-party `Jason`. Elixir < 1.18 has no top-level `JSON`
# module, so any `WebPush.send/3` call raises
# `function JSON.encode!/1 is undefined (module JSON is not available)`,
# which our `DtuApp.Notifications.Dispatcher` rescue turns into the
# `[dispatcher] push failed ... reason=function JSON.encode!/1 is
# undefined (module JSON is not available)` warning.
# https://hexdocs.pm/elixir/1.18.0/JSON.html
FROM hexpm/elixir:1.18.5-erlang-27.3.4.17-alpine-3.21.7 AS builder

# install build dependencies
RUN apk add --no-cache build-base git curl ca-certificates

# prepare build directory
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# copy compile-time config files before compiling dependencies
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

# Bake the release version into the image so the in-app footer can show
# it at runtime. The release workflow passes the exact git tag (e.g.
# v2026-07-26-1); CI builds / local docker builds default to the short SHA.
ARG RELEASE_VERSION="dev"
ENV RELEASE_VERSION=${RELEASE_VERSION}

RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
#
# Must track the builder's Alpine minor (3.21.x) so the libstdc++
# / openssl / ncurses-libs runtime libs we copy in below are the
# same abi as what the builder linked against. Mixing a newer
# builder with an older runtime base gives missing-symbol surprises
# at `bin/dtu_app` startup, not at build time.
FROM alpine:3.21

# `wget` is here for the docker-compose healthcheck
# (`wget --spider http://localhost:4000/healthz`). It's the
# smallest HTTP client that:
#   * doesn't write the response body to disk (so we don't pollute
#     `/app` with probe artifacts when nobody owns the dir);
#   * returns 0 on 2xx, non-zero otherwise — exactly what Docker's
#     healthcheck `test:` expects;
#   * ships on alpine base (vs. `curl` which would pull extra deps).
# The DB and Mailpit containers run their own `pg_isready` / `nc -z`
# healthchecks against services inside the same container; for `app`
# the HTTP probe must hit localhost, so the tool needs to be IN the
# container.
#
# `rsvg-convert` is the SVG → PNG CLI used by the sun-down email
# notifier (`DtuApp.Emails.SunDownEmail.chart_attachment/1`). Gmail
# strips inline `<svg>` from email HTML bodies, so the chart is
# rendered to PNG and attached via `cid:` instead. The runtime image
# MUST carry the binary (not just the librsvg library), because the
# email module shells out via `System.cmd/3`. On Alpine 3.21 the
# `rsvg-convert` binary still lives in its own community package —
# `librsvg` ships only the shared library — so this explicit package
# list stays unchanged across the 3.20 → 3.21 bump.
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates wget rsvg-convert

WORKDIR "/app"
RUN chown nobody /app

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/dtu_app ./

# Entrypoint runs migrations then starts the release (see rel/docker-entrypoint.sh).
COPY --chmod=0755 rel/docker-entrypoint.sh /app/docker-entrypoint.sh

USER nobody

ENV HOME=/app

# Carry the release version into the running container so the runtime
# config can read it. Configured at build time (see ARG above).
ARG RELEASE_VERSION
ENV RELEASE_VERSION=${RELEASE_VERSION}

ENTRYPOINT ["/app/docker-entrypoint.sh"]
