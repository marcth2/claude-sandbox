# GitHub personal-account hardening capabilities (2026)

Research for [wayfinder ticket #57](https://github.com/marcth2/claude-sandbox/issues/57), part of [Map: GitHub hardening + CI policy for personal repos](https://github.com/marcth2/claude-sandbox/issues/56).

Context: marcth2's account is a **personal** GitHub account (not an organization), and claude-sandbox is a **private** repo.

## 1. Secret scanning + push protection

**Not available for private repos on a personal account, at any individual plan tier (Free or Pro).**

- Public repos get secret scanning + push protection for free by default, no license needed.
- Private/internal repos require **GitHub Secret Protection** — a standalone paid product (split out of GitHub Advanced Security in a 2025 repackaging), billed per active committer, available only on **GitHub Team** or **GitHub Enterprise Cloud** — both organization-level plans. A personal account cannot buy this for a private repo.
- Sources: [About GitHub Advanced Security](https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security), [Push protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection), [community discussion #197712](https://github.com/orgs/community/discussions/197712).

**Implication:** claude-sandbox cannot get native GitHub push protection while private and personally-owned. Options are: make the repo public (exposes source), move it under a paid GitHub Team org, or substitute an open-source secret scanner (e.g. gitleaks) as a CI lint step instead of GitHub's native feature. This invalidates the original "just enable it" framing of the secret-scanning task ticket — see map update.

## 2. Dependabot

**Fully available and free on private repos owned by a personal account** — alerts, security updates, and version updates all work.

- Owners/admins enable Dependabot alerts by turning on the dependency graph + Dependabot alerts per repo, or account-wide for all repos owned by the personal account.
- The only cost nuance: on private repos the automation consumes GitHub Actions minutes (part of the Pro plan's 3,000 min/month quota); public repos cost no Actions minutes at all.
- `dependabot.yml` (version updates) is configured per-repo, in that repo's own `.github/` directory — it is **not** an account/org-wide default file (see §7).
- Sources: [Dependabot security updates](https://docs.github.com/en/code-security/concepts/supply-chain-security/dependabot-security-updates), [Configuring Dependabot alerts](https://docs.github.com/en/code-security/dependabot/dependabot-alerts/configuring-dependabot-alerts), [Dependabot quickstart](https://docs.github.com/en/code-security/getting-started/dependabot-quickstart-guide).

## 3. Repository rulesets / branch protection

- Rulesets work on private repos for personal accounts, but **only from GitHub Pro up** (public repos get rulesets on Free too).
- **No cross-repo application exists for personal accounts.** Applying one ruleset to multiple repos in a single action requires an **organization** on GitHub Team/Enterprise — org owners can target multiple org repos from one org-level ruleset. A personal account has no equivalent settings hub.
- **Workaround:** configure a ruleset once on one repo, export it as JSON, and import that JSON into each additional repo to replicate the settings (GitHub also publishes prebuilt rulesets at [github/ruleset-recipes](https://github.com/github/ruleset-recipes)). This is the practical way to "template" a ruleset across marcth2's personal repos without an org.
- Sources: [About rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets), [Creating rulesets for repositories in your organization](https://docs.github.com/en/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization).

**Implication for the map:** the `marcth2/.github` repo should hold a template ruleset **JSON export**, not just prose docs, so rollout to future repos is "import this JSON" rather than manual re-clicking. (The actual scripted/automated rollout mechanism is still explicitly out of scope per the map — this is just what the template artifact should contain for a human to import by hand.)

## 4. Require signed commits

- When enabled, only signed-and-verified commits can land on the protected branch. Contributors pushing unsigned commits must rebase to add a signature and force-push.
- **Merge-method interaction is the real gotcha:**
  - Merge commits: work fine with signed, verified source commits.
  - Squash merging: blocked unless you are the PR author (squash creates a new commit GitHub can't reattribute signature-wise to someone else).
  - Rebase merging: **effectively incompatible** — GitHub creates brand-new, unsigned commits during a rebase merge, so this will fail if signed commits are required.
- Branch protections/rulesets do **not** apply to commits on a fork, so external forked contributions bypass the signing requirement entirely (relevant only if the repo ever takes outside PRs).
- **Solo-maintainer footgun, confirmed:** turning this on before configuring a signing key means your own next push/merge to the protected branch will be rejected. Set up signing first (ticket #61), then enable the requirement.
- Sources: [About protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [renovatebot/renovate#1828](https://github.com/renovatebot/renovate/issues/1828), [Mergify: (Un)signed commits](https://articles.mergify.com/un-signed-commits-how-we-found-a-non-security-bug-in-github/).

## 5. CODEOWNERS + required reviews for a solo maintainer

- GitHub always blocks a PR author from approving their own PR — this applies to owners/admins too, by default, once required reviews are on.
- **Classic branch protection:** "Include administrators" is the toggle — leave it **unchecked** and repo admins (i.e. the solo owner) bypass the review requirement automatically. Check it to force even admins to comply (then you're locked out unless you also use one of the bypass mechanisms below).
- **Rulesets (the newer mechanism):** support an explicit **bypass list** of actors who skip the rule entirely. Community reports say *individual users* can't always be named directly in an **organization**-level ruleset's bypass list (only roles/teams/apps), but the repo-admin role can be added, which is the practical equivalent for a solo owner. This nuance is for org-level rulesets specifically — repo-level (non-org) rulesets on a personal account are less documented here and should be spot-checked in the GitHub UI when the actual ruleset is built, rather than assumed.
- Sources: [Approving a pull request with required reviews](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews), [community discussion #150545](https://github.com/orgs/community/discussions/150545), [community discussion #136200](https://github.com/orgs/community/discussions/136200).

## 6. Reusable Actions workflows across private repos owned by the same personal account

Works, but needs two settings configured (not automatic):

1. On the **called** repo (`marcth2/.github`, if kept private): Settings → Actions → General → Access policy, set to "Accessible from repositories owned by the 'marcth2' user."
2. On the **caller** repo (e.g. claude-sandbox): Actions permissions must allow using external actions/reusable workflows.
3. Both repos must be genuinely "private" — "internal" visibility (an Enterprise-only concept anyway) behaves differently and has been reported broken for this use case.
4. Reference syntax: `uses: {owner}/{repo}/.github/workflows/{filename}@{ref}` — prefer pinning `{ref}` to a release tag or commit SHA over a branch name for stability.
5. Security note: making a private repo's workflows accessible to other repos means outside collaborators on those *other* repos can indirectly trigger/view runs that touch the shared repo's workflow files, via a short-lived scoped token — low risk here since all repos are same-owner, but worth knowing.

**This is moot if `marcth2/.github` ends up public (see §7) — public reusable workflows are callable from anywhere with no access-policy step.**

Sources: [Sharing actions and workflows from your private repository](https://docs.github.com/actions/creating-actions/sharing-actions-and-workflows-from-your-private-repository), [Reusing workflow configurations](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).

## 7. The `.github` special repository

**Must be public.** This is unconditional — "private `.github` repositories are not supported" for the default-community-health-file behavior. There's no personal-account exception.

- Default files apply to any repo owned by the account that doesn't have its own file of that type (e.g. a repo without its own `CONTRIBUTING.md` shows a link to the `.github` repo's default one).
- A repo overrides a default entirely per file-type if it has any file of its own in that category (e.g. any file in `.github/ISSUE_TEMPLATE/` suppresses all default issue templates, not just the overlapping ones).
- **Confirmed NOT supported as account-wide defaults:** `LICENSE`, `CODEOWNERS`, and `dependabot.yml` — these three are per-repo only, full stop, regardless of `.github` repo setup. (This matches what the map's tickets already assume — CODEOWNERS and Dependabot config are both scoped as per-repo tasks.)
- Default files don't show up in a repo's own file browser, git history, clones, or downloads — they're an overlay, not a copy.
- Source: [Creating a default community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file).

## Bottom line for the map's open decisions

- **`marcth2/.github` visibility (ticket #63):** should be **public** — this isn't really an open choice, it's a hard requirement for the community-health-file behavior this repo exists to provide, and it also sidesteps the private-repo reusable-workflow access-policy dance in §6. There's no secret content in generic policy/workflow templates, so no downside found.
- **Branch protection spec (ticket #64):** use a **ruleset** (not classic branch protection) since GitHub is steering toward rulesets and they support bypass lists; export it as JSON into the `.github` template repo for manual replication to future repos (no automated cross-repo rollout exists for personal accounts — confirmed, matches the map's existing out-of-scope call). Sequence "require signed commits" strictly after commit signing is configured (ticket #61).
- **Secret scanning task (ticket #65):** as originally scoped ("enable it"), this is **not achievable** on a private personal repo. Needs to become a decision — accept the gap, go public, upgrade to a paid org plan, or substitute a non-GitHub-native scanner (e.g. gitleaks) as a CI lint step.
