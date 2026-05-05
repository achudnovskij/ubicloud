FROM ubuntu:24.04

ARG NODE_VERSION=24.12.0
ARG DEBIAN_FRONTEND=noninteractive
ARG WORKSPACE_FOLDER_NAME=ubicloud

# Install system dependencies
RUN apt-get update --fix-missing && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    libffi-dev \
    libgmp-dev \
    libpq-dev \
    libreadline-dev \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    libyaml-dev \
    libz-dev \
    openssh-client \
    postgresql-client \
    psmisc \
    sudo \
    tzdata \
    wget \
    nano \
    unzip \
    vim \
    gh \
    jq \
    neovim \
    logrotate \
    cron \
    python3 \
    python3-pip \
    iproute2 \
    iputils-ping \
    net-tools \
    dnsutils \
    traceroute \
    nmap \
    tcpdump \
    netcat-openbsd \
    lsof \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI (arch-aware)
RUN ARCH=$(uname -m) && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip

# Install otelcol-contrib (arch-aware) for spec/overrides/prog/postgres/postgres_server_nexus_spec.rb
ARG OTEL_VERSION=0.146.0
RUN ARCH=$(uname -m) && case "$ARCH" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; esac \
    && curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_${ARCH}.tar.gz" \
        | tar xz -C /usr/local/bin otelcol-contrib

# Create non-root vscode user
RUN useradd -m -s /bin/bash vscode \
    && echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER vscode
WORKDIR /home/vscode

# Install mise and Node.js (Node changes less frequently than Ruby)
RUN curl https://mise.run | sh \
    && echo 'eval "$(/home/vscode/.local/bin/mise activate bash)"' >> /home/vscode/.bashrc \
    && /home/vscode/.local/bin/mise install node@${NODE_VERSION} \
    && /home/vscode/.local/bin/mise use --global node@${NODE_VERSION}

# Use mise shims for version-independent PATH
ENV PATH="/home/vscode/.local/share/mise/shims:/home/vscode/.local/bin:${PATH}" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

WORKDIR /workspaces/${WORKSPACE_FOLDER_NAME}

# Install Node dependencies (cached unless package.json changes)
COPY --chown=vscode:vscode package.json package-lock.json ./
RUN npm install

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# --- Ruby version boundary ---
# Ruby version is read from .tool-versions (single source of truth shared with Gemfile)
COPY --chown=vscode:vscode .tool-versions .tool-versions
RUN RUBY_VERSION=$(awk '/^ruby/ {print $2}' .tool-versions) \
    && /home/vscode/.local/bin/mise install ruby@${RUBY_VERSION} \
    && /home/vscode/.local/bin/mise use --global ruby@${RUBY_VERSION}

# Install bundler and foreman
RUN gem install bundler foreman

# Install Ruby dependencies (cached unless Gemfile changes)
COPY --chown=vscode:vscode Gemfile Gemfile.lock ./
RUN bundle install

# Copy app source and generate .env.rb
COPY --chown=vscode:vscode . .
RUN rake overwrite_envrb

COPY --chown=vscode:vscode .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
CMD ["sleep", "infinity"]