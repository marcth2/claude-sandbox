# claude-sandbox — Glossary

## Profile

A locked-per-checkout choice (`vanilla`/`omc`/`aihero`) between **alternative, potentially-
contradictory skill ecosystems** — its purpose is to keep two skill packs that might issue
overlapping or conflicting instructions (e.g. `omc` and `aihero`) from ever coexisting in the same
`.home/`. It is not a general feature-gating mechanism: a capability that doesn't overlap with any
profile's skill ecosystem (e.g. the TELUS plugin marketplace) is cross-cutting and belongs in the
shared `_common.sh` helpers every profile already calls uniformly, not behind a profile choice.

## Git identity mount

The host's real `~/.ssh` directory, bind-mounted read-only into the container at
`$CONTAINER_HOME/.ssh` when the user opts in during `common_prompt_git` (the `SSH_DIR` setting).
Exists today for the user's own `git push`/`git clone` inside the container. Also, incidentally,
the credential Claude Code's `/plugin marketplace add owner/repo` needs for a private GitHub repo
over SSH (its default transport) — no separate mechanism required, provided the mounted key
actually has access to the org in question.

## Plugin marketplace opt-in

A setup-time (not runtime) decision, per profile per checkout, of whether to register a given
Claude Code plugin marketplace (e.g. `telus/claude-telus-plugins`) at all. Distinct from **plugin
selection** below — registering a marketplace and installing a plugin from it are two different
questions with two different answers.

## Plugin selection

Given a registered marketplace, which of its plugins actually get installed. A marketplace can be
opted into while installing none, one, or several of its plugins — this is a second, independent
choice from marketplace opt-in.

## Plugin credential

A secret a specific installed plugin needs to do its job at runtime (e.g. `telus-dynatrace`'s
Dynatrace Platform token) — distinct from both the **git identity mount** (which authenticates
*fetching* the plugin) and the container's Anthropic auth mode (`apikey`/`sso`, which authenticates
talking to Claude). Not every plugin has one — `telus-claude-admin` needs none.

## System-prompt seed

A cross-cutting, opt-in-at-setup addition to every claude-sandbox session's system prompt (e.g. a
fetched communication-style fragment). Distinct from **Profile**: a profile exists to keep
*contradictory skill ecosystems* apart, while a system-prompt seed is a personal *communication-
style* preference that applies the same way no matter which profile is active — so, like the
**plugin marketplace opt-in**, it's decided once per checkout during setup via the shared
`_common.sh` helpers, not behind a profile choice. Its opt-in is its own independent axis, separate
from plugin marketplace opt-in and plugin selection above.
