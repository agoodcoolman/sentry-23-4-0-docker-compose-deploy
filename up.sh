#!/bin/bash
set -eu

# Source environment variables
if [ -f .env.custom ]; then
    source .env.custom
fi

# Create necessary directories
mkdir -p data/{postgres,redis,kafka,zookeeper,zookeeper-log,clickhouse,symbolicator}

# Start all services
echo "Starting Sentry services..."
docker-compose up -d

echo "Sentry services started!"
echo "Web interface: http://localhost:9006"
echo ""
echo "To stop services: docker-compose down"