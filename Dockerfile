# Multi-stage Dockerfile for kafka-aws-haskell
# Stage 1: Build with Cabal
FROM haskell:9.6 AS builder

# Install system dependencies for librdkafka
RUN apt-get update && apt-get install -y \
    librdkafka-dev \
    libssl-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy cabal files first for better caching
COPY kafka-aws-haskell.cabal ./

# Update cabal and build dependencies
RUN cabal update && cabal build --only-dependencies

# Copy source code
COPY src/ ./src/

# Build the executable
RUN cabal build exe:kafka-aws-haskell

# Find and copy the built binary to a known location
RUN mkdir -p /opt/app && \
    cp $(cabal list-bin kafka-aws-haskell) /opt/app/kafka-aws-haskell

# Stage 2: Runtime image (Alpine-based with all required packages)
FROM alpine:latest

# Create non-root user
RUN addgroup --system jpapp && adduser --system --ingroup jpapp jpapp

# Install all required packages from reference Dockerfile
RUN apk add --no-cache \
    ca-certificates \
    build-base \
    gcc \
    libc6-compat \
    binutils \
    busybox-extras \
    net-tools \
    bind-tools \
    netcat-openbsd \
    sed \
    gzip \
    postgresql16-client \
    redis \
    coreutils \
    bash \
    sshpass \
    zip \
    unzip \
    librdkafka-dev \
    aws-cli \
    neovim \
    kafkacat \
    python3 \
    py3-pip \
    cyrus-sasl-dev \
    curl \
    wget \
    tar \
    openjdk17-jre-headless

# Add edge repositories for newer packages
RUN echo 'http://dl-cdn.alpinelinux.org/alpine/edge/main' >> /etc/apk/repositories && \
    echo 'http://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache "curl=~8.19"

# Download Kafka
RUN mkdir -p /opt && cd /opt && \
    wget https://downloads.apache.org/kafka/3.9.0/kafka_2.13-3.9.0.tgz && \
    tar -xzf kafka_2.13-3.9.0.tgz && \
    mv kafka_2.13-3.9.0 kafka && \
    rm kafka_2.13-3.9.0.tgz

# Download AWS MSK IAM auth library
RUN cd /opt && \
    wget https://github.com/aws/aws-msk-iam-auth/releases/download/v1.1.9/aws-msk-iam-auth-1.1.9-all.jar

# Install Python IAM Signer library
RUN pip install --no-cache-dir aws-msk-iam-sasl-signer-python --break-system-packages

# Environment variables
ENV KAFKA_HOME=/opt/kafka
ENV CLASSPATH=/opt/aws-msk-iam-auth-1.1.9-all.jar
ENV PATH="$PATH:$KAFKA_HOME/bin"
ENV PYTHONPATH="/usr/lib/python3.12/site-packages"

# Set working directory
WORKDIR /opt

# Copy the binary from builder
COPY --from=builder /opt/app/kafka-aws-haskell /opt/app/kafka-aws-haskell

# Ensure binary is executable
RUN chmod +x /opt/app/kafka-aws-haskell

# Set ownership
RUN chown -R jpapp:jpapp /opt/app/

# Switch to non-root user
USER jpapp

# Default command
ENTRYPOINT ["/opt/app/kafka-aws-haskell"]
