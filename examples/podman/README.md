# Deploy with Podman

Runs Armadillo as a systemd service via Podman Quadlet with Caddy as a reverse 
proxy. This guide is tested on Ubuntu 26.04 LTS and steps may vary on other 
distributions.

## Prerequisites

- A Linux server on your local network, referred to as `<server-ip>` below
- Podman 4.4+; Older versions require the deprecated `podman generate systemd` 
instead of Quadlet
- Caddy

If you plan to use the standard DNS port 53, make sure it is not already in use:

```sh
sudo ss -ulnp | grep :53
```

If `systemd-resolved` is bound to port 53, you can disable its stub listener:

```sh
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
```

## Setup

### 1. Create the data directory

```sh
mkdir -p ~/armadillo/data
```

### 2. Download the default zone file

```sh
curl -o ~/armadillo/data/local.zone \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/podman/data/local.zone
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/podman/data/local.zone).

### 3. Add a DNS record for the web UI

```sh
echo "dns.lan 300 IN A <server-ip>" >> ~/armadillo/data/local.zone
```

Replace `<server-ip>` with the server's local IP address.

### 4. Download the Quadlet container file

```sh
curl -o ~/armadillo/armadillo.container \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/podman/armadillo.container
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/podman/armadillo.container).

### 5. Configure the container file

Open `~/armadillo/armadillo.container` and replace:

- `<user>` with your username
- `<uid>` with your user ID (`id -u`)
- `<secret>` with a strong secret — to generate one:

```sh
openssl rand -hex 32
```

Adjust any other environment variables as needed.

### 6. Install the container file

```sh
sudo cp ~/armadillo/armadillo.container /etc/containers/systemd/armadillo.container
```

### 7. Start the service

```sh
sudo systemctl daemon-reload
sudo systemctl start armadillo
```

Verify it is running:

```sh
sudo systemctl status armadillo
```

### 8. Configure Caddy

Add the following to your Caddyfile, or create one at `/etc/caddy/Caddyfile`:

```
http://dns.lan {
    rewrite / /index.html
    reverse_proxy localhost:3000
}
```

Then reload Caddy:

```sh
sudo systemctl reload caddy
```

### 9. Point your router at the server

Set `<server-ip>` as the primary DNS resolver in your router's DHCP settings.

---

All devices on the network will now resolve `dns.lan` to the server and the web
UI will be accessible at `http://dns.lan`.

## Environment variables

See the [container image](../../README.md#container-image) for all available variables.
