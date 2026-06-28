# Deploy with Docker Compose

Runs Armadillo and Caddy as containers via Docker Compose. This guide is tested 
on Ubuntu 26.04 LTS and steps may vary on other distributions.

## Prerequisites

- A Linux server on your local network, referred to as `<server-ip>` below
- Docker with the Compose plugin (`docker compose version`)

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

### 1. Create the project directory

```sh
mkdir -p ~/armadillo/data ~/armadillo/config
```

### 2. Download the default zone file

```sh
curl -o ~/armadillo/data/local.zone \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/data/local.zone
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/data/local.zone).

### 3. Add a DNS record for the web UI

```sh
echo "dns.lan 300 IN A <server-ip>" >> ~/armadillo/data/local.zone
```

Replace `<server-ip>` with the server's local IP address.

### 4. Download the Compose file

```sh
curl -o ~/armadillo/docker-compose.yml \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/docker-compose.yml
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/docker-compose.yml).

### 5. Download the Caddyfile

```sh
curl -o ~/armadillo/config/Caddyfile \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/config/Caddyfile
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/config/Caddyfile).

### 6. Create the environment file

```sh
curl -o ~/armadillo/.env \
  https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/example.env
```

Or [see raw file](https://raw.githubusercontent.com/vshakitskiy/armadillo/mistress/examples/docker-compose/example.env).

Open `~/armadillo/.env` and replace `your_secret_here` with a strong secret. To 
generate one:

```sh
openssl rand -hex 32
```

Docker Compose automatically loads `.env` from the project directory. Secrets 
stay out of the Compose file.

### 7. Start the services

```sh
cd ~/armadillo && docker compose up -d
```

Verify both containers are running:

```sh
docker ps
```

### 8. Point your router at the server

Set `<server-ip>` as the primary DNS resolver in your router's DHCP settings.

---

All devices on the network will now resolve `dns.lan` to the server and the web
UI will be accessible at `http://dns.lan`.

## Environment variables

See the [container image](../../README.md#container-image) for all available 
variables.
