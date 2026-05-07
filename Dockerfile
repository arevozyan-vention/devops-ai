# syntax=docker/dockerfile:1.7
# devops-ai-ui — single image with the framework + FastAPI UI + every CLI tool
# the recipes need (Goose, claude CLI + ACP adapter, terragrunt, AWS CLI,
# Docker client for deploy-app, jq, yq, git).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PATH="/root/.local/bin:/usr/local/bin:${PATH}" \
    DEVOPS_AI_ROOT=/workspace \
    FRAMEWORK_DIR=/workspace/framework \
    # Tell @anthropic/claude-agent-acp this is a sandbox so it allows the
    # bypassPermissions session mode while running as root. Without this,
    # Goose crashes with "Requested mode 'bypassPermissions' not offered
    # by agent" because the SDK refuses bypass-mode for root.
    IS_SANDBOX=1

# ── system packages ─────────────────────────────────────────────────
# openssl: deploy-app self-heal generates JWT/APP secrets via
#   `openssl rand -hex 32` when an app reports "<VAR>_SECRET is required".
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release unzip \
      python3 python3-pip python3-venv \
      git jq make build-essential \
      bash openssh-client openssl \
    && rm -rf /var/lib/apt/lists/*

# ── yq (mikefarah) ──────────────────────────────────────────────────
RUN curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_$(dpkg --print-architecture)" \
    && chmod +x /usr/local/bin/yq

# ── Node (for claude CLI + claude-agent-acp) ────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Anthropic Claude CLI + ACP adapter ──────────────────────────────
# Pin claude-agent-acp to a 0.29.x: in 0.30+ the "bypassPermissions"
# session mode was renamed to "dontAsk", which Goose 1.32 can't talk to
# (it still requests bypassPermissions, gets "mode not offered").
RUN npm install -g @anthropic-ai/claude-code '@agentclientprotocol/claude-agent-acp@~0.29'

# ── AWS CLI v2 ──────────────────────────────────────────────────────
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then AWSARCH=x86_64; else AWSARCH=aarch64; fi && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSARCH}.zip" -o /tmp/awscli.zip && \
    unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && \
    rm -rf /tmp/awscli.zip /tmp/aws

# ── Session Manager plugin ──────────────────────────────────────────
# Required for `aws ecs execute-command`, which the deploy-app self-heal
# loop uses to run database migrations (Phase 4.2: typeorm/prisma/django/
# rake/etc.) inside a running task. Without this plugin, execute-command
# fails with "SessionManagerPlugin is not found".
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_${ARCH}/session-manager-plugin.deb" \
      -o /tmp/ssm.deb && \
    dpkg -i /tmp/ssm.deb && \
    rm /tmp/ssm.deb

# ── Azure CLI ───────────────────────────────────────────────────────
# Used by the Azure-flavoured recipes (deploy-app-azure, infra-apply
# identity check, audit-azure, etc.) and by the framework helpers
# `cmd_az_login` / `cmd_az_bootstrap`. Microsoft's official install
# script handles arch detection and apt repo setup in one call.
RUN curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash && \
    rm -rf /var/lib/apt/lists/*

# ── Terraform + Terragrunt ──────────────────────────────────────────
# Terraform 1.10+ is required: skeletons use `use_lockfile = true` in the
# S3 backend block, which was added in Terraform 1.10. 1.14.x is the
# current stable line.
# Terragrunt 1.0+ matches the `terragrunt run --all <cmd>` syntax used in
# the framework's recipes (older 0.x used `run-all`).
ARG TF_VERSION=1.14.9
ARG TG_VERSION=1.0.3
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${ARCH}.zip" -o /tmp/tf.zip && \
    unzip -q /tmp/tf.zip -d /usr/local/bin && rm /tmp/tf.zip && \
    curl -fsSL "https://github.com/gruntwork-io/terragrunt/releases/download/v${TG_VERSION}/terragrunt_linux_${ARCH}" \
      -o /usr/local/bin/terragrunt && chmod +x /usr/local/bin/terragrunt

# ── Terraform plugin cache + pre-baked providers ────────────────────
# Without this, every Terragrunt unit (~15 per project) does its own
# `terraform init` and re-downloads the providers it needs from scratch.
# That's ~50 MB × 15 = 750 MB and ~10 minutes of wall time on a typical
# plan-infra cold run, even though the providers are identical across
# units. The fix is two-fold:
#
#   1. TF_PLUGIN_CACHE_DIR — shared cache that Terraform consults before
#      downloading. After the first init, all subsequent inits symlink
#      from the cache instead of hitting the registry.
#
#   2. Pre-baked providers — we run a one-shot `terraform init` against a
#      tiny module that requires every provider both skeletons use, so the
#      cache is already populated when the image starts. First plan-infra
#      on a fresh container goes from ~10 min to ~2 min.
#
# Versions match the constraints in:
#   - templates/iac/ecs-fargate-rds/environments/root.hcl  (aws ~> 5.70)
#   - templates/iac/container-apps-postgres/environments/root.hcl
#     (azurerm ~> 4.10, azapi ~> 2.2, random ~> 3.6, tls ~> 4.0)
ENV TF_PLUGIN_CACHE_DIR=/root/.terraform.d/plugin-cache \
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true
RUN mkdir -p "$TF_PLUGIN_CACHE_DIR" && \
    printf 'plugin_cache_dir = "%s"\ndisable_checkpoint = true\n' "$TF_PLUGIN_CACHE_DIR" \
      > /root/.terraformrc

# Build a tiny module that pulls in every provider both skeletons need,
# then `terraform init` once. Cache is now warm for both AWS and Azure.
RUN mkdir -p /tmp/tf-prebake && \
    printf '%s\n' \
      'terraform {' \
      '  required_version = ">= 1.6.0"' \
      '  required_providers {' \
      '    random  = { source = "hashicorp/random",  version = "~> 3.6"  }' \
      '    tls     = { source = "hashicorp/tls",     version = "~> 4.0"  }' \
      '    aws     = { source = "hashicorp/aws",     version = "~> 5.70" }' \
      '    azurerm = { source = "hashicorp/azurerm", version = "~> 4.10" }' \
      '    azapi   = { source = "Azure/azapi",       version = "~> 2.2"  }' \
      '  }' \
      '}' \
      > /tmp/tf-prebake/main.tf && \
    cd /tmp/tf-prebake && \
    terraform init -input=false -backend=false && \
    rm -rf /tmp/tf-prebake && \
    echo "=== plugin cache size ===" && \
    du -sh "$TF_PLUGIN_CACHE_DIR" && \
    echo "=== providers cached ===" && \
    find "$TF_PLUGIN_CACHE_DIR" -mindepth 4 -maxdepth 4 -type d | sed 's|^|  |'

# ── Goose CLI ───────────────────────────────────────────────────────
RUN curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | \
      CONFIGURE=false bash && \
    cp /root/.local/bin/goose /usr/local/bin/goose

# ── Docker CLI (for deploy-app; build/push uses host docker via socket) ──
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin && \
    rm -rf /var/lib/apt/lists/*

# ── App layout ──────────────────────────────────────────────────────
WORKDIR /workspace
RUN mkdir -p /workspace/projects /root/.aws /root/.claude /root/.config/goose

# Goose config — claude-acp by default (uses mounted ~/.claude/ OAuth).
# Backend auto-switches to `anthropic` provider when the user pastes an
# API key, and back to `claude-acp` when they OAuth in via the wizard.
RUN printf 'GOOSE_PROVIDER: claude-acp\nGOOSE_MODEL: claude-opus-4-7\nGOOSE_MODE: auto\nGOOSE_TELEMETRY_ENABLED: false\nextensions:\n  developer:\n    enabled: true\n    type: builtin\n    name: developer\n' \
    > /root/.config/goose/config.yaml

# Pre-seed claude CLI's settings so its first-run wizard is skipped — the
# OAuth orchestrator can then jump straight to /login without TUI menus
# blocking. theme=dark just suppresses the theme picker.
RUN mkdir -p /root/.claude && \
    printf '{"theme":"dark","hasCompletedOnboarding":true,"shiftEnterKeyBindingInstalled":true}\n' \
    > /root/.claude/settings.json

# ── Python (FastAPI) deps ───────────────────────────────────────────
# Defensive flags for slow networks: 120s read timeout + 5 retries.
# Pre-install PyYAML from apt (the largest wheel in our deps; pypi likes
# to time out on it from Docker Desktop's VM) so a flaky connection on
# that one wheel doesn't kill the whole build.
RUN apt-get update && apt-get install -y --no-install-recommends python3-yaml \
    && rm -rf /var/lib/apt/lists/*
ENV PIP_DEFAULT_TIMEOUT=120 \
    PIP_RETRIES=5 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
COPY backend/requirements.txt /tmp/req.txt
RUN pip3 install --no-cache-dir --timeout 120 --retries 5 \
      -r /tmp/req.txt && rm /tmp/req.txt

# ── Copy framework + UI ─────────────────────────────────────────────
COPY framework /workspace/framework
COPY backend   /workspace/backend
COPY frontend  /workspace/frontend
RUN chmod +x /workspace/framework/devops-ai.sh \
             /workspace/framework/bootstrap.sh \
    && find /workspace/framework/lib -name '*.sh' -exec chmod +x {} \;

EXPOSE 8080
WORKDIR /workspace
CMD ["python3", "-m", "uvicorn", "--app-dir", "/workspace/backend", \
     "main:app", "--host", "0.0.0.0", "--port", "8080"]
