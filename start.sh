#!/bin/bash
set -e

echo "[Start Script] Starting Kafka POC..."

# Check required environment variables
if [ -z "$MSK_BOOTSTRAP_SERVERS" ]; then
    echo "Error: MSK_BOOTSTRAP_SERVERS environment variable is required"
    exit 1
fi

if [ -z "$MSK_REGION" ]; then
    echo "Error: MSK_REGION environment variable is required"
    exit 1
fi

# Parse the first broker from the bootstrap servers list
FIRST_BROKER=$(echo $MSK_BOOTSTRAP_SERVERS | cut -d',' -f1)
echo "[Start Script] Using first broker: $FIRST_BROKER"

# Extract host and port
BROKER_HOST=$(echo $FIRST_BROKER | cut -d':' -f1)
BROKER_PORT=$(echo $FIRST_BROKER | cut -d':' -f2)

# Start kafka-proxy in the background
echo "[Start Script] Starting kafka-proxy..."
echo "[Start Script] Forwarding localhost:9092 -> $FIRST_BROKER with AWS_MSK_IAM auth"
echo "[Start Script] AWS_ROLE_ARN: ${AWS_ROLE_ARN:-not set}"
echo "[Start Script] AWS_WEB_IDENTITY_TOKEN_FILE: ${AWS_WEB_IDENTITY_TOKEN_FILE:-not set}"

# Add role ARN if available (for IRSA role assumption)
SASL_ROLE_ARN_ARG=""
if [ -n "$AWS_ROLE_ARN" ]; then
    SASL_ROLE_ARN_ARG="--sasl-aws-role-arn=$AWS_ROLE_ARN"
    echo "[Start Script] Using role ARN: $AWS_ROLE_ARN"
fi

/opt/kafka-proxy server \
    --bootstrap-server-mapping "$FIRST_BROKER,127.0.0.1:9092" \
    --tls-enable \
    --tls-insecure-skip-verify \
    --sasl-enable \
    --sasl-method "AWS_MSK_IAM" \
    --sasl-aws-region "$MSK_REGION" \
    $SASL_ROLE_ARN_ARG \
    --log-level debug &

KAFKA_PROXY_PID=$!
echo "[Start Script] kafka-proxy started with PID $KAFKA_PROXY_PID"

# Wait for kafka-proxy to be ready
echo "[Start Script] Waiting for kafka-proxy to be ready..."
sleep 3

# Check if kafka-proxy is running
if ! kill -0 $KAFKA_PROXY_PID 2>/dev/null; then
    echo "[Start Script] Error: kafka-proxy failed to start"
    exit 1
fi

echo "[Start Script] kafka-proxy is ready!"

# Set the bootstrap servers to point to localhost (kafka-proxy)
export PROXY_BOOTSTRAP_SERVERS="127.0.0.1:9092"
echo "[Start Script] Using proxy bootstrap: $PROXY_BOOTSTRAP_SERVERS"

# Start the Haskell application
echo "[Start Script] Starting Haskell Kafka consumer..."
exec kafka-aws-haskell
