#!/bin/bash
set -eu

# Environment variable setup
export SENTRY_SECRET_KEY=${SENTRY_SECRET_KEY:-$(openssl rand -base64 32)}
export SENTRY_DB_PASSWORD=${SENTRY_DB_PASSWORD:-sentry}
export SENTRY_DB_USER=${SENTRY_DB_USER:-sentry}
export SENTRY_DB_NAME=${SENTRY_DB_NAME:-sentry}
export REDIS_PASSWORD=${REDIS_PASSWORD:-please-change-me}
export SENTRY_POSTGRES_HOST=${SENTRY_POSTGRES_HOST:-postgres}
export SENTRY_REDIS_HOST=${SENTRY_REDIS_HOST:-redis}

# Create .env.custom file
cat > .env.custom << EOF
export SENTRY_SECRET_KEY="${SENTRY_SECRET_KEY}"
export SENTRY_DB_PASSWORD="${SENTRY_DB_PASSWORD}"
export SENTRY_DB_USER="${SENTRY_DB_USER}"
export SENTRY_DB_NAME="${SENTRY_DB_NAME}"
export REDIS_PASSWORD="${REDIS_PASSWORD}"
export SENTRY_POSTGRES_HOST="${SENTRY_POSTGRES_HOST}"
export SENTRY_REDIS_HOST="${SENTRY_REDIS_HOST}"
EOF

echo "Environment variables saved to .env.custom"

# Stop and remove existing containers
echo "Stopping existing containers..."
docker-compose down || true

# Create necessary directories
mkdir -p data/{postgres,redis,kafka,zookeeper,zookeeper-log,clickhouse,symbolicator}

# Fix Kafka permissions
echo "Fixing Kafka permissions..."
sudo chown -R 1000:1000 data/kafka || true

# Start Kafka and Zookeeper first
echo "Starting Kafka and Zookeeper..."
docker-compose up -d zookeeper kafka

# Wait for Kafka to be ready
echo "Waiting for Kafka to be ready..."
sleep 30

# Start ClickHouse
echo "Starting ClickHouse..."
docker-compose up -d clickhouse

# Wait for ClickHouse to be ready
echo "Waiting for ClickHouse to be ready..."
sleep 20

# Start Snuba
echo "Starting Snuba..."
docker-compose up -d snuba-api snuba-consumer

# Wait for Snuba to be ready
echo "Waiting for Snuba to be ready..."
sleep 30

# Start Redis and PostgreSQL
echo "Starting Redis and PostgreSQL..."
docker-compose up -d redis postgres

# Wait for database to be ready
echo "Waiting for database to be ready..."
sleep 30

# Run Sentry migrations and setup
echo "Running Sentry migrations..."
docker-compose run --rm sentry-web upgrade

# Create admin user
echo "Creating admin user..."
docker-compose run --rm sentry-web createuser --superuser --email admin@example.com --password admin

# Start all services
echo "Starting all services..."
docker-compose up -d

echo "Sentry setup complete!"
echo "Web interface: http://localhost:9006"
echo "Admin user: admin@example.com / admin"
echo ""
echo "To stop services: docker-compose down"
echo "To restart services: ./up.sh"