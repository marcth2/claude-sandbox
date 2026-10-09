FROM node:26-slim

# pandoc + weasyprint (PDF engine: `pandoc --pdf-engine=weasyprint`; typst isn't packaged in trixie).
# python3-munkres satisfies python3-fonttools' `python3-scipy | python3-munkres` dependency so
# apt doesn't pull in scipy + numpy (~100MB) that weasyprint never uses.
RUN apt-get update && apt-get install -y \
    git curl ca-certificates gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli gh \
    && apt-get install -y --no-install-recommends pandoc weasyprint python3-munkres \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code oh-my-claude-sisyphus

ARG DOCKER_GID=984
ARG USERNAME=claude
ARG USER_UID=1000
ARG USER_GID=1000
# node:22-slim ships a 'node' user at uid/gid 1000 — rename to match the host user
RUN groupmod -g "${USER_GID}" -n "${USERNAME}" node && \
    usermod -l "${USERNAME}" -u "${USER_UID}" -m -d "/home/${USERNAME}" node && \
    groupadd -g "${DOCKER_GID}" docker && \
    usermod -aG docker "${USERNAME}"

RUN mkdir -p /work/projects && chown "${USERNAME}:${USERNAME}" /work/projects

USER ${USERNAME}
WORKDIR /work/projects

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
