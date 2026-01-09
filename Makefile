all: build run logs

build:
	docker compose build --no-cache

run:
	docker compose up -d

logs:
	docker compose logs -f