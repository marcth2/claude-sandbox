FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

ARG DOCKER_GID=984
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupmod -g "${USER_GID}" -n "${USERNAME}" node && \
    usermod -l "${USERNAME}" -u "${USER_UID}" -m -d "/home/${USERNAME}" node && \
    groupadd -g "${DOCKER_GID}" docker && \
    usermod -aG docker "${USERNAME}"

RUN mkdir -p /work/projects && chown "${USERNAME}:${USERNAME}" /work/projects

USER ${USERNAME}
WORKDIR /work/projects

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
