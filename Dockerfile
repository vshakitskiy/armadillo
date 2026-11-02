ARG ERLANG_VERSION=29.1.2.0
ARG GLEAM_VERSION=v1.19.2

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-scratch AS gleam

FROM erlang:${ERLANG_VERSION}-alpine AS build-tools
COPY --from=gleam /bin/gleam /bin/gleam
COPY docker/hex-retry.sh /usr/local/bin/hex-retry
RUN chmod +x /usr/local/bin/hex-retry

FROM build-tools AS client-build
COPY shared/ /app/shared/
COPY client/ /app/client/
WORKDIR /app/client
RUN hex-retry gleam run -m lustre/dev build

FROM build-tools AS server-build
COPY shared/ /app/shared/
COPY server/ /app/server/
COPY --from=client-build /app/client/dist/ /app/server/priv/
WORKDIR /app/server
RUN hex-retry gleam export erlang-shipment

FROM erlang:${ERLANG_VERSION}-alpine
RUN apk add --no-cache libcap \
    && find /usr/local/lib/erlang -name beam.smp -exec setcap cap_net_bind_service=+ep {} \; \
    && mkdir -p /data
COPY --from=server-build /app/server/build/erlang-shipment /app
ENV DNS_PORT=53
ENV DNS_UPSTREAM=8.8.8.8
ENV API_PORT=3000
ENV ZONE_FILE=/data/local.zone
VOLUME /data
WORKDIR /app
EXPOSE 53/udp
EXPOSE 3000/tcp
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
