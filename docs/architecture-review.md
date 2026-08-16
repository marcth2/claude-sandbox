# Architecture Review — Phase 1 (claude-sandbox)

Synthesis of the decision map tracked in [#1](https://github.com/marcth2/claude-sandbox/issues/1). Each ticket below reviewed one facet of claude-sandbox's built Phase 1 architecture — the profile/image split, `.home/` isolation, auth injection, and the `claude.sh`/`setup.sh`/`_common.sh` script structure — and landed on **accept-as-sound** or **gap-with-recommendation**. No fixes were made as part of this review; gaps become follow-on implementation work. This document is the destination artifact for the map; the tickets themselves remain the decision record.

Closing this document unblocks Phase 3 (docs) and Phase 4 (MCP servers).

## Decisions

### Profile lock-in per checkout ([#8](https://github.com/marcth2/claude-sandbox/issues/8))

**Accept-as-sound.** Each checkout is locked to one profile with no `--profile` override flag. The tradeoffs this creates — alias collisions across checkouts, secret duplication in each `.env`, version drift between checkouts — are real but only surface under manual multi-checkout testing, not the expected real-world single-checkout usage pattern. No change recommended.

### Accepted risks: Docker socket mount, `--dangerously-skip-permissions`, telemetry soft-block ([#2](https://github.com/marcth2/claude-sandbox/issues/2))

**Mixed.** Socket mount and telemetry soft-block: accept-as-sound — the containerization rationale is plugin/config isolation and org-hook containment, not device-policy obfuscation, so neither risk undermines the stated goal.

`--dangerously-skip-permissions`: **gap-with-recommendation** — add an `--interactive` flag giving a real permissions allow/deny list, documented in `--help`.

This ticket also surfaced a documentation gap: host safety currently depends on an unwritten rule (API key auth on host, SSO only inside container) that isn't recorded anywhere.

### Auth/secret handling: `.env` plaintext, Docker `-e` injection, `gh`'s plaintext-credential warning ([#5](https://github.com/marcth2/claude-sandbox/issues/5))

**Accept-as-sound across the board.** The threat model is single-developer, non-shared laptop — there's no other local user who could read `.env` permissions or `docker run` argv, so the multi-user secret-exposure threat model doesn't apply. `gh`'s own credential storage under `.home/.config/gh/` is upstream behavior already covered by the `.home*/` gitignore entry. (The ticket's original "GITHUB_TOKEN (planned)" text was stale — no such feature exists in the current code.)

### Does `.home/` fully isolate org-hook writes from the host? ([#4](https://github.com/marcth2/claude-sandbox/issues/4))

**Accept-as-sound for observed behavior** — `$HOME` wiring was verified end-to-end across the Dockerfile, compose file, and `claude.sh`, and keeps every currently-known hook write contained inside `.home/`.

**Gap-with-recommendation:** containment isn't structurally guaranteed against a hypothetical hook that writes outside `$HOME`. Recommended:
- a `handoff.md` Threat Model caveat noting this is an observed-behavior guarantee, not a structural one
- `--read-only` rootfs + tmpfs `/tmp` in `claude.sh`'s `DOCKER_ARGS`, to structurally force writes into mounted paths

### Is the `claude.sh` / `setup.sh` / `_common.sh` split the right shape? ([#6](https://github.com/marcth2/claude-sandbox/issues/6))

**Accept-as-sound.** The split tracks a real setup-time-vs-runtime boundary. The small `DOCKER_GID` detection logic duplicated between `claude.sh` and `_common.sh` (4 lines, 2 call sites) is fine as-is — not worth abstracting. No preemptive restructuring recommended ahead of Phase 4.

Planning note for Phase 4: sequence the MCP server work starting with one server (GitHub or Slack) as a proof of concept before building out the rest.

### The 2-image/3-profile split ([#3](https://github.com/marcth2/claude-sandbox/issues/3))

**Accept-as-sound.** `vanilla` and `aihero` share `claude-code:base` because their only difference is trusted Markdown skill files copied into `.home/` at setup time — not an image-level dependency. `omc` gets its own image (`claude-code:omc`) because it needs a real npm package baked in. No near-term profile is expected to break this split.

**Gap-with-recommendation:** add a one-line `handoff.md` note on the "image = system deps, setup.sh = config" rule, so future profiles are added consistently. (Full workflow documentation remains deferred to Phase 3.)

Reconfirmed twice more during dogfooding (see [Dogfood validation](#dogfood-validation-11) below): both the `aihero` and `vanilla` runs built `claude-code:base` as a 100% cache-hit against the same image.

### Cross-platform (macOS/WSL) code paths are unverified ([#7](https://github.com/marcth2/claude-sandbox/issues/7))

**Gap-with-recommendation.** Only the Linux + native Docker Engine path has been exercised. Recommended: add a `handoff.md` caveat now (full README treatment still deferred to Phase 3) stating that Linux is tested, while macOS Terminal / WSL2 Terminal via Docker Desktop are expected-but-untested — with a real, not just formal, uncertainty flagged around Docker Desktop's virtualization layer. PowerShell/CMD are already unsupported via the existing shell guard in `claude.sh`. macOS/Windows users should be encouraged to file a GitHub issue if they hit problems.

### Testing approach ([#9](https://github.com/marcth2/claude-sandbox/issues/9) research / [#10](https://github.com/marcth2/claude-sandbox/issues/10) decision)

**Decision:** adopt `shellcheck` + `shfmt` now, via a local pre-commit hook — not CI, since no CI infrastructure exists and the project's 1–2-developer, every-few-months cadence doesn't justify standing one up. Defer `bats-core` until Phase 4's actual shape is known. Explicitly skip building an automated Docker-driving integration harness (the dogfood validation ticket's manual checklist covers this instead) and skip `shunit2` (no incremental value over `bats-core` here).

### Dogfood validation ([#11](https://github.com/marcth2/claude-sandbox/issues/11))

Not a soundness decision itself — a validation pass confirming the above decisions hold under a real, fresh, end-to-end run. All three profiles (`aihero`, `omc`, `vanilla`) were dogfooded in separate checkouts, each covering `--reset` → wizard → `setup.sh` → image build → `.home/` seed → alias → real container launch.

**Result: no verdict changes to any ticket above.** Two findings came out of it:
- A testing-harness-only gotcha (not a `claude.sh` bug): `docker run -it` requires a real TTY; scripted/non-interactive smoke tests need a pty shim (e.g. `script -qec "..." /tmp/x.typescript`). Relevant to any future work on #9/#10's testing approach, not a product change.
- A real functional gap, `omc`-specific: the `oh-my-claudecode` plugin is not actually wired up by `setup.sh` — `enabledPlugins`/`extraKnownMarketplaces` keys in `settings.json` aren't sufficient for Claude Code to auto-install/register it, so the profile's headline multi-agent capability doesn't work out of the box. Split out to its own ticket, [#13](https://github.com/marcth2/claude-sandbox/issues/13), since it's a `profiles/omc/setup.sh` product bug, not a sandbox-architecture question.

## Follow-on work

Gap-with-recommendation items above, collected as a punch list for implementation after this map closes:

1. Add an `--interactive` flag to `claude.sh` (real permissions allow/deny list, documented in `--help`). — [#2](https://github.com/marcth2/claude-sandbox/issues/2)
2. Document the host-safety rule: API key auth on host, SSO only inside the container. — [#2](https://github.com/marcth2/claude-sandbox/issues/2)
3. Add a `handoff.md` Threat Model caveat: `.home/` containment is observed behavior for known hooks, not a structural guarantee. — [#4](https://github.com/marcth2/claude-sandbox/issues/4)
4. Harden `claude.sh`'s `DOCKER_ARGS` with `--read-only` rootfs + tmpfs `/tmp`. — [#4](https://github.com/marcth2/claude-sandbox/issues/4)
5. Add a one-line `handoff.md` note codifying "image = system deps, setup.sh = config" for future profiles. — [#3](https://github.com/marcth2/claude-sandbox/issues/3)
6. Add a `handoff.md` cross-platform caveat (Linux tested; macOS/WSL2 expected-but-untested; PowerShell/CMD unsupported). — [#7](https://github.com/marcth2/claude-sandbox/issues/7)
7. Set up `shellcheck` + `shfmt` as a local pre-commit hook. — [#9](https://github.com/marcth2/claude-sandbox/issues/9)/[#10](https://github.com/marcth2/claude-sandbox/issues/10)
8. Fix `profiles/omc/setup.sh` so the `oh-my-claudecode` plugin actually registers on fresh setup. — [#13](https://github.com/marcth2/claude-sandbox/issues/13)

Items 1–7 are documentation/hardening notes small enough to fold into Phase 3; item 8 is a standalone profile bug that can be fixed independently at any time.

## Out of scope

Documentation (Phase 3: `README.md`, `CLAUDE.md`) is deferred as a later enhancement after Phase 4 MCP work — not gated by this architecture soundness review.
