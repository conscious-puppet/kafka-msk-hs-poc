# Runtime Dockerfile - minimal image with kafka-proxy and pre-built Haskell binary
FROM debian:bookworm-slim

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    wget \
    tar \
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

# Copy pre-built Haskell binary (build locally first with: cabal build)
COPY dist-newstyle/build/x86_64-linux/ghc-*/kafka-aws-haskell-*/x/kafka-aws-haskell/build/kafka-aws-haskell/kafka-aws-haskell /usr/local/bin/kafka-aws-haskell

# Copy startup script
COPY start.sh /opt/start.sh
RUN chmod +x /opt/start.sh

# Default command runs the start script
CMD ["/opt/start.sh"]
