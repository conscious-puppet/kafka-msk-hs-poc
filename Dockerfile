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

# Copy cabal files (cabal.project references GitHub fork of hw-kafka-client)
COPY cabal.project ./
COPY kafka-aws-haskell.cabal ./
COPY src/ ./src/

# Build the application (includes local hw-kafka-client)
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

# Install AWS CLI v2 (for debugging)
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Set up PATH
ENV PATH="$PATH:/opt"
ENV APP_HOME=/opt/app

# Create app directory
RUN mkdir -p $APP_HOME
WORKDIR $APP_HOME

# Copy pre-built Haskell binary from builder stage
COPY --from=builder /build/kafka-aws-haskell /usr/local/bin/kafka-aws-haskell

# Default command runs the application directly
CMD ["/usr/local/bin/kafka-aws-haskell"]
