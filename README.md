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

Local records are stored in a DNS zone file and loaded into ETS on startup. All 
query resolution at runtime goes through ETS only, the zone file is never read 
during query handling.

## Container image

Available at `ghcr.io/vshakitskiy/armadillo:latest`.

| Variable | Default | Description |
|---|---|---|
| `DNS_PORT` | `53` | Port the DNS server listens on |
| `DNS_UPSTREAM` | `8.8.8.8` | Upstream resolver for unknown domains |
| `DNS_TTL` | `300` | Default TTL for zone records in seconds |
| `DNS_SOA_MINIMUM` | `3600` | SOA minimum TTL for negative caching in seconds |
| `API_PORT` | `3000` | Port for the web UI and REST API |
| `API_SECRET_KEY_BASE` | random key | Secret used to sign session cookies |
| `ZONE_FILE` | `/data/local.zone` | Path to the DNS zone file |

Mount a volume to `/data` to persist the zone file across restarts. The zone
file is created automatically if it does not exist.

## Deploying on Linux with Podman and Caddy

This is a simple starting setup for a home local network. It is not intended as 
a reference for how deployments should be done in general.

1. Allow binding to port 53 without root:
```sh
echo "net.ipv4.ip_unprivileged_port_start=53" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

2. Start the container and generate a systemd service:
```sh
podman run -d --name armadillo \
  -e API_SECRET_KEY_BASE=your_secret \
  -e DNS_UPSTREAM=1.1.1.1 \
  -v armadillo-data:/data \
  -p 53:53/udp \
  -p 127.0.0.1:3000:3000 \
  ghcr.io/vshakitskiy/armadillo:latest

podman generate systemd --new --name armadillo | sudo tee /etc/systemd/system/armadillo.service
sudo systemctl daemon-reload
podman rm -f armadillo
sudo systemctl enable --now armadillo
```

3. Configure Caddy to serve the UI by the server's IP for now:
```
http://192.168.1.x {
    rewrite / /index.html
    reverse_proxy localhost:3000
}
```

4. Point your router at the server's IP as the DNS resolver.

5. Open the UI at `http://192.168.1.x`, add a DNS record pointing your chosen
domain, for example `dns.lan`, to the server IP.

6. Update the Caddyfile to use the domain:
```
http://dns.lan {
    rewrite / /index.html
    reverse_proxy localhost:3000
}
```

From this point the UI is accessible at `http://dns.lan` from any device on the 
network.

## Domain naming

The server accepts any domain string. That said, avoid `.local`. It is reserved 
for mDNS/Bonjour (RFC 6762) and Apple devices will not send `.local` queries to 
a unicast DNS server. `.lan` or `.internal` are common alternatives.

## Contributing

I will be glad to receive any contributions and feedbacks. Issues or pull 
requests are welcomed!

The project has three packages: `server` runs the DNS resolver and HTTP API, 
`client` is the web UI, and `shared` contains modules used by both. Each package 
is developed independently, run `gleam run` in `server/` and 
`gleam run -m lustre/dev` in `client/`.

For managing environment variables locally during development, [direnv](https://direnv.net) 
is recommended.

To bind to port 53 locally without sudo, run setcap on the BEAM binary:
```sh
# Find the binary:
$(which erl) -noshell -eval 'io:format("~s~n",[os:find_executable("beam.smp")]),halt().'
# > /path/to/beam.smp

sudo setcap cap_net_bind_service=+ep /path/to/beam.smp
```

## Resolving with VPN

> Personal notes for if I run into DNS issues with a VPN again.

When running a VPN like vless in proxy or tun mode, it's very important to make 
sure the VPN resolves domains via the correct DNS. Asuming the router's IP 
`192.168.1.1` is where the DNS server is configured:

1. Add the router as a DNS server and route LAN IPs directly for xray:

```jsonc
{
    "dns": {
        "servers": [
            { "address": "192.168.1.1", "port": 53 },
            "1.1.1.1"
        ]
    },
    "routing": {
        "rules": [
            {
                "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
                "outboundTag": "direct"
            }
        ]
    }
}
```

2. Tag the local DNS server and route private IPs through it for sing-box:

```jsonc
{
    "dns": {
        "servers": [
            { "tag": "dns-local", "address": "192.168.1.1", "detour": "direct" },
            { "tag": "dns-remote", "address": "1.1.1.1", "detour": "proxy" }
        ],
        "rules": [{ "ip_is_private": true, "server": "dns-local" }],
        "final": "dns-remote"
    },
    "route": {
        "rules": [{ "ip_is_private": true, "outbound": "direct" }]
    }
}
```