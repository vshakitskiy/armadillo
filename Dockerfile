ARG ERLANG_VERSION=28.5.0.1
ARG GLEAM_VERSION=v1.17.0

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

FROM erlang:${ERLANG_VERSION}-alpine AS client-build
COPY --from=gleam /bin/gleam /bin/gleam
COPY shared/ /app/shared/
COPY client/ /app/client/
WORKDIR /app/client
RUN gleam run -m lustre/dev build

FROM erlang:${ERLANG_VERSION}-alpine AS server-build
RUN apk add --no-cache build-base
COPY --from=gleam /bin/gleam /bin/gleam
COPY shared/ /app/shared/
COPY server/ /app/server/
COPY --from=client-build /app/client/dist/ /app/server/priv/
WORKDIR /app/server
RUN gleam export erlang-shipment

FROM erlang:${ERLANG_VERSION}-alpine
RUN apk add --no-cache libcap \
    && find /usr/local/lib/erlang -name beam.smp -exec setcap cap_net_bind_service=+ep {} \; \
    && addgroup --system armadillo \
    && adduser --system armadillo -G armadillo
COPY --chown=armadillo:armadillo --from=server-build /app/server/build/erlang-shipment /app
ENV DNS_PORT=53
ENV DNS_UPSTREAM=8.8.8.8
ENV API_SECRET_KEY_BASE=""
ENV API_PORT=3000
VOLUME /data
WORKDIR /app
USER armadillo
EXPOSE 53/udp
EXPOSE 3000/tcp
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
