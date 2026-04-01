# Two-stage Dockerfile: Build Haskell app in stage 1, minimal runtime in stage 2

# Stage 1: Build the Haskell application
FROM haskell:9.6 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    librdkafka-dev \
    libssl-dev \
    pkg-config \
    ca-certificates \
    build-essential \
    gcc \
    curl \
    wget \
    tar \
    unzip \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /build

# Copy cabal file and source
COPY kafka-aws-haskell.cabal ./
COPY src/ ./src/

# Build the application
RUN cabal update && cabal build exe:kafka-aws-haskell

# Find the built binary path
RUN cp $(cabal list-bin kafka-aws-haskell) /build/kafka-aws-haskell

# Stage 2: Minimal runtime image
FROM debian:bookworm-slim

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    wget \
    tar \
    unzip \
    bash \
    netcat-traditional \
    dnsutils \
    net-tools \
    iputils-ping \
    librdkafka1 \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Install kafka-proxy for MSK IAM authentication
RUN cd /opt && \
    KAFKA_PROXY_VERSION=$(curl -s https://api.github.com/repos/grepplabs/kafka-proxy/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
    wget https://github.com/grepplabs/kafka-proxy/releases/download/${KAFKA_PROXY_VERSION}/kafka-proxy-${KAFKA_PROXY_VERSION}-linux-amd64.tar.gz && \
    tar -xzf kafka-proxy-${KAFKA_PROXY_VERSION}-linux-amd64.tar.gz && \
    chmod +x kafka-proxy && \
    rm kafka-proxy-*.tar.gz

# Set up PATH
ENV PATH="$PATH:/opt"
ENV APP_HOME=/opt/app

# Create app directory
RUN mkdir -p $APP_HOME
WORKDIR $APP_HOME

# Copy pre-built Haskell binary from builder stage
COPY --from=builder /build/kafka-aws-haskell /usr/local/bin/kafka-aws-haskell

# Copy startup script
COPY start.sh /opt/start.sh
RUN chmod +x /opt/start.sh

# Default command runs the start script
CMD ["/opt/start.sh"]
