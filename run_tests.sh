#!/bin/bash
set -x

function cleanup {
    docker stop $DOCKER_ID
}

trap cleanup EXIT

DOCKER_ID=$(docker run --network host -e POSTGRES_PASSWORD=testpasswd -d postgres)
sleep 5
yoyo apply -f -b --database postgresql://postgres:testpasswd@127.0.0.1 ./migrations/
python3 -m pytest -v -s tests/test_database.py
