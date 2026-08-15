FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code oh-my-claudecode

ARG DOCKER_GID=984
# node:22-slim ships a 'node' user at uid/gid 1000 — rename it to marc
RUN groupmod -n marc node && \
    usermod -l marc -m -d /home/marc node && \
    groupadd -g "${DOCKER_GID}" docker && \
    usermod -aG docker marc

RUN mkdir -p /work/projects && chown marc:marc /work/projects

USER marc
WORKDIR /work/projects

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
