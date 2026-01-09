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
| `TAG` | *(empty)* | Tag from `@MTProxybot` (used for statistics / identification). | `TAG=your_tag_from_bot` |
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

## Quick start

### 1) Prepare environment file

```bash
cp .env.example .env
```

Edit `.env` as needed (for example set `PORT`, `SECRET` or `SECRETS`, `TAG`).

### 2) Build and run

Using the provided Makefile:

```bash
make build
make run
```

Or directly with Docker Compose:

```bash
docker compose build --no-cache
docker compose up -d
```

### 3) View logs / get connection links

```bash
make logs
```

On startup, the container prints connection links like:

```
tg://proxy?server=YOUR_IP&port=443&secret=dd<YOUR_SECRET>
```

---

## Security notes

- **Keep your secrets private**.
- Consider restricting stats access (by default the compose file maps stats to `127.0.0.1` only).
- If you expose stats publicly, protect it with firewall rules or reverse proxy auth.

---

## License / upstream

This repository packages and runs the official MTProxy binary built from upstream sources.

Upstream: https://github.com/TelegramMessenger/MTProxy