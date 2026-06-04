# Armadillo

A DNS server for my local network, powered by Gleam.

## The Vision

The plan is to build a recursive resolver with local overrides. It will use SQLite for persistent record storage and ETS for in-memory caching. Management will happen via a simple HTTP API.

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

More of a guide for myself; took some time to figure out. When running a VPN like vless in proxy or tun mode, it's very important to make sure the VPN resolves domains via the correct DNS. Assuming all local DNS servers are specified in the router panel on 192.168.1.1, here is what needs to be added on the VPN client, in this case, Happ.

For xray, include your router/DNS IP as one of the servers, and route LAN IPs with the direct tag:

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