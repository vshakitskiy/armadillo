# ![armadillo icon](https://github.com/user-attachments/assets/8dc753a7-fde8-43d7-9e6e-30bc1f26080d) Armadillo

A self-hosted DNS server for homelab use, written in Gleam.

[![armadillo showcase](https://github.com/user-attachments/assets/7361e6b2-c761-4eea-82d8-22f95c104324)](https://github.com/user-attachments/assets/7361e6b2-c761-4eea-82d8-22f95c104324)

Configure it once on your router as the DNS resolver and every device on the 
network resolves your local domains automatically.

## How it works

When a DNS query arrives, the server checks its local record store first. If a 
matching record exists, it responds immediately with the configured IP. If no 
record matches, the query is forwarded to a configurable upstream resolver, the 
response is cached by TTL, and returned to the client.

Local records are stored in SQLite and loaded into ETS on startup. All query 
resolution at runtime goes through ETS only.

## Running with Docker

```sh
docker run \
  -e DNS_UPSTREAM=1.1.1.1 \
  -e API_SECRET_KEY_BASE=your_secret \
  -v armadillo-data:/data \
  -p 53:53/udp \
  -p 3000:3000 \
  ghcr.io/vshakitskiy/armadillo:latest
```

| Variable | Default | Description |
|---|---|---|
| `DNS_PORT` | `53` | Port the DNS server listens on |
| `DNS_UPSTREAM` | `8.8.8.8` | Upstream resolver for unknown domains |
| `API_PORT` | `3000` | Port for the web UI and REST API |
| `API_SECRET_KEY_BASE` | - | Secret for request signing, random per start if unset |

Records persist in a SQLite database mounted at `/data`. The web UI for managing 
records is served at the `API_PORT`.

## Domain naming

The server accepts any domain string. That said, avoid `.local`. It is reserved 
for mDNS/Bonjour (RFC 6762) and Apple devices will not send `.local` queries to 
a unicast DNS server. `.lan` or `.internal` are common alternatives.

## Binding to default DNS port without sudo

To bind to port 53 without sudo, I run setcap on the beam binary.
```sh
# To find the beam binary:
$(which erl) -noshell -eval 'io:format("~s~n",[os:find_executable("beam.smp")]),halt().'
# > /path/to/beam.smp

# And then:
sudo setcap cap_net_bind_service=+ep /path/to/beam.smp
```

## Resolving issue with VPN

More of a guide for myself; took some time to figure out. When running a VPN 
like vless in proxy or tun mode, it's very important to make sure the VPN 
resolves domains via the correct DNS. Assuming all local DNS servers are 
specified in the router panel on 192.168.1.1, here is what needs to be added on
the VPN client, in this case, Happ.

For xray, include your router/DNS IP as one of the servers, and route LAN IPs 
with the direct tag:

```json
{
    // ...
    "dns": {
        // ...
        "servers": [
            // ...
            {
                "address": "192.168.1.1",
                "port": 53
            },
            "1.1.1.1",
            "8.8.8.8",
            // ...
        ],
        // ...
    },
    // ...
    "routing": {
        // ...
        "rules": [
            {
                "ip": [
                    "10.0.0.0/8",
                    "172.16.0.0/12",
                    "192.168.0.0/16"
                ],
                "outboundTag": "direct"
            },
            // ...
        ],
        // ...
    },
    // ...
}
```

For sing-box, provide rules for LAN IPs to go through the local tag:

```json
{
    // ...
    "dns": {
        // ...
        "servers": [
            // ...
            {
                "tag": "dns-local",
                "address": "192.168.1.1",
                "detour": "direct"
            },
            {
                "tag": "dns-remote",
                "address": "1.1.1.1",
                "detour": "proxy"
            },
            {
                "tag": "dns-fallback",
                "address": "8.8.8.8",
                "detour": "direct"
            },
            // ...
        ],
        "rules": [
            // ...
            {
                "ip_is_private": true,
                "server": "dns-local"
            },
            // ...
        ],
        "final": "dns-remote",
        // ...
    },
    // ...
    "route": {
        // ...
        "rules": {
            // ...
            {
                "ip_is_private": true,
                "outbound": "direct"
            },
            // ...
        },
        // ...
    },
    // ...
}
```
