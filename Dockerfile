# Find eligible builder image
FROM hexpm/elixir:1.16.2-erlang-26.2.1-alpine-3.19.1 AS builder

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
FROM alpine:3.19.1

RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates

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
