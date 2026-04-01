# Development Dockerfile with full toolchain for building/testing in Kubernetes
FROM haskell:9.6

# Install system dependencies
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
    bash \
    netcat-traditional \
    dnsutils \
    postgresql-client \
    redis-tools \
    unzip \
    zip \
    vim-tiny \
    net-tools \
    iputils-ping \
    groff \
    less \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Install kafka-proxy for MSK IAM authentication
RUN cd /opt && \
    KAFKA_PROXY_VERSION=$(curl -s https://api.github.com/repos/grepplabs/kafka-proxy/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') && \
    wget https://github.com/grepplabs/kafka-proxy/releases/download/${KAFKA_PROXY_VERSION}/kafka-proxy-${KAFKA_PROXY_VERSION}-linux-amd64.zip && \
    unzip kafka-proxy-${KAFKA_PROXY_VERSION}-linux-amd64.zip && \
    mv kafka-proxy-${KAFKA_PROXY_VERSION}-linux-amd64 kafka-proxy && \
    chmod +x kafka-proxy && \
    rm kafka-proxy-*.zip

# Install Kafka CLI tools
RUN mkdir -p /opt && cd /opt && \
    wget https://downloads.apache.org/kafka/3.9.2/kafka_2.13-3.9.2.tgz && \
    tar -xzf kafka_2.13-3.9.2.tgz && \
    mv kafka_2.13-3.9.2 kafka && \
    rm kafka_2.13-3.9.2.tgz

# Download AWS MSK IAM auth library
RUN cd /opt && \
    wget https://github.com/aws/aws-msk-iam-auth/releases/download/v1.1.9/aws-msk-iam-auth-1.1.9-all.jar

# Install Python and pip
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment and install Python IAM Signer library
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install aws-msk-iam-sasl-signer-python

# Add venv to PATH
ENV PATH="/opt/venv/bin:$PATH"

# Environment variables
ENV KAFKA_HOME=/opt/kafka
ENV CLASSPATH=/opt/aws-msk-iam-auth-1.1.9-all.jar
ENV PATH="$PATH:$KAFKA_HOME/bin:/opt"
ENV APP_HOME=/opt/app

# Create app directory
RUN mkdir -p $APP_HOME
WORKDIR $APP_HOME

# Copy cabal file first for dependency caching
COPY kafka-aws-haskell.cabal ./

# Copy source code
COPY src/ ./src/

# Update cabal and build dependencies (but not the executable yet)
RUN cabal update && cabal build --only-dependencies

# Build the executable
RUN cabal build exe:kafka-aws-haskell

# Create a symlink for easy access
RUN ln -sf $(cabal list-bin kafka-aws-haskell) /usr/local/bin/kafka-aws-haskell

# Copy startup script
COPY start.sh /opt/start.sh
RUN chmod +x /opt/start.sh

# Set up for interactive use
RUN echo 'export PS1="[kafka-hs] \w $ "' >> /root/.bashrc

# Default to bash for interactive debugging
CMD ["/bin/bash"]
