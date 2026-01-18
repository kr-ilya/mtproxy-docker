# MTProxy (Docker) - simple setup

This repository contains a minimal Docker image + Docker Compose setup for running **Telegram MTProxy** with:
- Automatic refresh of **official Telegram proxy secret/config**
- **HTTP stats** endpoint
- **Multi-secret** support
- **Multi-port** support


Official MTProxy project: https://github.com/TelegramMessenger/MTProxy

---

## Environment variables

You can set these in `.env` (recommended) or directly in your shell.

### Runtime variables

| Variable | Default | Description | Example |
|---|---:|---|---|
| `PORT` | `443` | Single public port (used if `PORTS` is empty). | `PORT=443` |
| `PORTS` | *(empty)* | Multiple public ports (**comma-separated**). Overrides `PORT`. | `PORTS=443,8443,9443` |
| `SECRET` | *(empty)* | Single secret (**32 hex chars**). If empty and `/data/secret` does not exist, it will be auto-generated and saved to `/data/secret`. | `SECRET=0123456789abcdef0123456789abcdef` |
| `SECRETS` | *(empty)* | Multiple secrets (**comma or space-separated**). Overrides `SECRET`. | `SECRETS=aaa... bbb...` or `SECRETS=aaa...,bbb...` |
| `TAG` | *(empty)* | Tag from [@MTProxybot](https://t.me/MTProxybot). | `TAG=your_tag_from_bot` |
| `WORKERS` | *(auto)* | Number of worker processes (auto-detected, capped to 16 in entrypoint). | `WORKERS=4` |
| `EXTERNAL_IP` | *(auto-detect)* | External IP used to generate `tg://proxy` links. If not set, auto-detected; fallback to container IP. | `EXTERNAL_IP=203.0.113.10` |
| `STATS_PORT` | `8888` | HTTP stats port. | `STATS_PORT=8888` |
| `CONFIG_UPDATE_INTERVAL` | `604800` | Telegram config update interval in seconds (`getProxySecret` / `getProxyConfig`). Set `0` to disable updates. | `CONFIG_UPDATE_INTERVAL=86400` |

### Build-time args (Docker build)

These are passed as build args (configured in `docker-compose.yml`).

| Argument | Default | Description |
|---|---:|---|
| `MTPROTO_REPO_URL` | `https://github.com/TelegramMessenger/MTProxy` | Upstream repository URL to build MTProxy from. |
| `MTPROTO_COMMIT` | `cafc338` | Commit / tag to checkout before building. |

---
## Prebuilt image

A prebuilt image is available on [Docker Hub](https://hub.docker.com/r/imilya/mtproxy).

---

## Quick start

### 1) Clone the repository

```bash
git clone https://github.com/kr-ilya/mtproxy-docker.git
cd mtproxy-docker
```

### 2) Prepare environment file

```bash
cp .env.example .env
```

Edit `.env` as needed (for example set `PORT`, `SECRET` or `SECRETS`, `TAG`).

### 3) Run

```bash
docker compose up -d
```

### 3) View logs / get connection links

```bash
docker compose logs -f
```

On startup, the container prints connection links like:

```
tg://proxy?server=YOUR_IP&port=443&secret=dd<YOUR_SECRET>
```

--- 

Build locally

If you want to build the MTProxy binary yourself (for example to pin a different commit upstream sources), use:

```bash
docker compose build --no-cache
docker compose up -d
```

If you prefer Makefile helpers:

```bash
make build
make run
make logs
```

---

## Security notes

- **Keep your secrets private**.
- Consider restricting stats access (by default the compose file maps stats to `127.0.0.1` only).
- If you expose stats publicly, protect it with firewall rules or reverse proxy auth.

---

## Potential issues with official MTProxy and PID limits

**Important note:** the official MTProxy binary currently does **not support process IDs (PIDs) larger than 65535**.  

In long-running containers or on systems where many processes are started, PIDs can grow beyond this limit. When that happens, MTProxy may **crash immediately on startup** with an error like:

```
mtproto-proxy: common/pid.c:42: init_common_PID: Assertion `!(p & 0xffff0000)' failed
```


### Optional workaround

You can limit the maximum PID the kernel assigns to new processes, which prevents this crash. This is **not required** for most users and may not be suitable in all environments. Run:

```bash
echo "kernel.pid_max = 65535" | sudo tee /etc/sysctl.d/99-mtproxy.conf
sudo sysctl --system
```

### Effects and limitations:

* For most ordinary users, this change does not cause any noticeable impact on system operation or performance.
* New processes will never get PID above 65535, which prevents MTProxy crashes.
* Systems with many concurrent processes (tens of thousands) may experience faster PID reuse.
* You do not have to run this command if your container restarts often or your system does not generate very large PIDs — MTProxy will usually work fine.


## Alternative approaches to handle PID / config updates

If MTProxy crashes due to large PIDs, you can consider:

1. **Disable automatic config updates**  
   Set `CONFIG_UPDATE_INTERVAL=0` — MTProxy will run continuously without restarting.  

2. **Use container restart to refresh config**  
   Combine the above with periodic container restart (via Docker restart policy or host cron) to reset PID counters and update config.


## License / upstream

This repository packages and runs the official MTProxy binary built from upstream sources.

Upstream: https://github.com/TelegramMessenger/MTProxy