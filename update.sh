#!/bin/bash
# Updates a deployed relay: pulls the repo, rebuilds on a fresh base image, and
# restarts the container only if the image changed. The outbound mode comes from
# COMPOSE_FILE in .env, which `docker compose` reads by itself.
#
#   bash update.sh
set -eu
cd "$(dirname "$0")"

# In braces so bash has read the whole script before git pull replaces this file.
{
    if ! grep -qE '^COMPOSE_FILE=.+' .env 2>/dev/null; then
        echo "update.sh: set COMPOSE_FILE in .env first, e.g. COMPOSE_FILE=docker-compose.graph.yml" >&2
        exit 1
    fi
    echo "Updating from branch: $(git branch --show-current)"
    git pull --ff-only
    docker compose build --pull
    docker compose up -d
    docker compose ps
    exit 0
}
