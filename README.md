# agent2agent-dev

A launcher for paired Claude Code agents. Each agent gets its own **git worktree** and runs side-by-side in a **split-pane terminal window** backed by tmux — so multiple agents can work in parallel without stepping on each other's files or branches.

## What it does

1. Creates a **git worktree** for each agent from your current branch — isolated working directories, shared git history
2. Opens **one terminal window per feature** with agents in side-by-side tmux panes
3. Wires up a **file bridge** so agents can message each other mid-task
4. Installs a **`CLAUDE.md`** into each worktree so agents know their role, paths, and how to communicate
5. Saves session config into each repo so `claude-dev` from either repo resumes instantly

---

## Quick reference

```bash
# First-time setup
bash install.sh && source ~/.zshrc

# Interactive wizard (first launch)
claude-dev

# Scripted launch
claude-dev --repo-a owner/frontend --repo-b owner/backend --features "auth,payments"

# Resume saved session (run from inside either repo)
cd ~/sites/my-app && claude-dev

# Re-attach after closing the terminal window
tmux attach -t claude-dev-auth-a

# Force terminal picker (e.g. new machine)
claude-dev --pick-terminal

# End session + clean up worktrees, branches, bridge
cd ~/sites/my-app && claude-dev --end

# Show help
claude-dev --help
```

**Agent messaging (from inside a Claude session):**

```bash
# Send a message to the other agent
/tmp/claude-bridge-claude-dev-auth/send-to-agent.sh b "What does POST /api/login return?"

# Read a message from the other agent
cat /tmp/claude-bridge-claude-dev-auth/a-to-b.md

# Check the full conversation history
cat /tmp/claude-bridge-claude-dev-auth/conversation-log.md
```

---

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `tmux` | Yes | `brew install tmux` |
| `claude` | Yes | Claude Code CLI |
| `gum` | Yes | Installed automatically by `install.sh` |
| `git` | Yes | v2.5+ for worktree support |
| `gh` | Only for GitHub cloning | `brew install gh && gh auth login` |

**Supported terminals (macOS):** Ghostty, iTerm2, Terminal.app. You pick once on first run; the choice is saved to `~/.claude-dev-global`.

## Installation

Run once from the `agent2agent-dev` directory:

```bash
bash install.sh
source ~/.zshrc
```

`install.sh` will:
1. Install `gum` via Homebrew (or apt on Linux) if not already present — prompts before installing
2. Add a `claude-dev` shell function to your `~/.zshrc` so the launcher is available from anywhere

## First launch

```bash
claude-dev
```

The interactive wizard walks you through:

1. **Terminal** — pick Ghostty, iTerm2, or Terminal.app (only installed terminals are shown). Saved to `~/.claude-dev-global` and skipped on future runs
2. **Repo A** — pick from `~/sites/`, clone a GitHub repo, or enter a local path
3. **Repo B** — same options, plus "Skip" for single-repo mode
4. **Features** — comma-separated names (one terminal window per feature), defaults to `main`

After the first launch, a `.claude-dev` config file is saved into both repos. Next time you run `claude-dev` from either repo it detects the saved config and offers to resume.

## Subsequent launches

```bash
cd ~/sites/my-frontend   # or my-backend — works from either repo
claude-dev               # detects saved config, asks "Resume saved session?"
```

To force the terminal picker again (e.g. on a new machine):

```bash
claude-dev --pick-terminal
```

## Ending a session

```bash
cd ~/sites/my-frontend   # or my-backend
claude-dev --end
```

Shows a summary of everything that will be removed — tmux session, worktrees, branches, bridge dirs, and `.claude-dev` config files — then asks for confirmation before acting. Safe to run even if parts of the session are already gone.

### Teardown order

1. **Kill tmux sessions first** so agents stop before git state is touched.
2. **Uncommitted changes check** — for each worktree with dirty state, prompts:
   - **Commit all changes** — asks for a message, runs `git add -A && git commit`. Empty message keeps the worktree intact.
   - **Discard changes** — `git reset --hard HEAD && git clean -fd`.
   - **Keep worktree — skip cleanup** — leaves worktree + branch untouched.
3. **Per-branch action picker** — for every agent branch with commits not in HEAD:
   - **Merge into a branch** — pick any branch in the repo via `gum filter`; merges with `--no-ff`.
   - **Keep branch (remove worktree only)** — branch survives, worktree gone.
   - **Delete without merging** — default action when no commits ahead.
   - Branches with no new commits are skipped silently.
4. **Execute merges** — checks out target, runs `git merge --no-ff <branch>`, then restores original HEAD.
   - **CLAUDE.md conflicts auto-resolve** to the target version (since each worktree carries its own agent template).
   - **Committed symlinks auto-strip** — any `120000`-mode (symlink) entries merged in from agent branches (e.g. Statamic cross-link artifacts) are restored to their pre-merge state and the merge commit is amended.
   - **Any other conflict aborts the merge** (`git merge --abort`) and keeps the branch so you can resolve manually.
5. **Remove worktrees** → **delete branches** (kept ones skipped) → **remove bridge dirs** → **remove `.claude-dev` config files**.

## Scripted (no wizard)

```bash
claude-dev \
  --repo-a owner/frontend \
  --repo-b owner/backend \
  --features "auth,payments,dashboard" \
  --role-a frontend \
  --role-b backend
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--repo-a` | — | Repo A: local path or `OWNER/REPO` (cloned automatically) |
| `--repo-b` | — | Repo B: local path or `OWNER/REPO`. Omit for single-repo mode |
| `--features` | `main` | Comma-separated feature names — one terminal window per feature |
| `--role-a` | `primary` | Label shown in agent headers and `CLAUDE.md` |
| `--role-b` | `secondary` | Label shown in agent headers and `CLAUDE.md` |
| `--session` | `claude-dev` | Base name for tmux sessions and worktree branches |
| `--base-dir` | `~/sites` | Where to clone repos and where the local picker looks |
| `--preset` | — | `sanity-nextjs`, `payload-nextjs`, or `statamic` — two worktrees from one repo with role-specific templates |
| `--pick-terminal` | — | Force the terminal picker even if `~/.claude-dev-global` already has one saved |
| `--end` | — | Interactively tear down the session for the current repo |
| `--preview` | — | Merge agent branches into main so you can test in the browser |
| `-h, --help` | — | Show usage and examples |

---

## Worktree isolation

This is the core safety mechanism. Without it, two agents writing to the same files at the same time cause conflicts. With worktrees, each agent owns a private copy of the working tree on a dedicated branch.

### How it works

For a session named `claude-dev` with feature `auth` and two repos:

```
~/sites/
  frontend/              ← original repo (your working branch, e.g. main)
  claude-dev-auth-a/     ← Agent A's worktree (branch: claude-dev-auth-a)
  backend/               ← original repo
  claude-dev-auth-b/     ← Agent B's worktree (branch: claude-dev-auth-b)
```

- Worktrees are created from **your current branch** at launch time
- Each agent gets a `CLAUDE.md` and bridge config installed into its worktree, not the original repo
- Agents commit to their own branches — no merge conflicts mid-session
- The original repos are untouched during the session

### Branch naming

```
{session}-{feature}-a    e.g.  claude-dev-auth-a
{session}-{feature}-b    e.g.  claude-dev-auth-b
```

### Worktree location

Worktrees are created as siblings of the original repo:

```
$(dirname <repo-root>)/{branch-name}
```

So if your repo is at `~/sites/frontend`, the worktree lands at `~/sites/claude-dev-auth-a`.

### Edge cases

| Situation | Behaviour |
|-----------|-----------|
| Repo is not a git repo | Skips worktree creation, agent uses the repo dir directly |
| HEAD is detached | Warns and uses the repo dir directly |
| Worktree dir already exists | Reuses it — useful when re-launching after a crash |
| Branch already exists but dir is gone | Git will error — run `claude-dev --end` or delete the branch manually |

### Testing in the browser mid-session

While agents are still working, run from inside the repo:

```bash
claude-dev --preview
```

This merges each agent's branch into your current HEAD (`main`), runs `php please stache:clear` for Statamic projects, and the already-running dev server picks up the changes automatically. The worktrees remain intact so agents can keep working.

Run `--preview` as many times as you like — it only merges commits that aren't already in HEAD. Any symlinks committed into agent branches (e.g. Statamic cross-link artifacts) are automatically stripped from the preview merge commit so they don't land in your main worktree.

### Merging work back at session end

`claude-dev --end` includes an interactive merge picker per branch — pick a target via `gum filter`, it runs `git merge --no-ff` and auto-resolves the `CLAUDE.md` conflict to the target version. Any other conflict aborts the merge and keeps the branch.

For a manual merge outside `--end`:

```bash
git -C ~/sites/frontend checkout main
git -C ~/sites/frontend merge --no-ff claude-dev-auth-a
```

### Cleanup

The recommended way is `claude-dev --end` run from inside either repo — it handles everything interactively. For manual cleanup of a single worktree:

```bash
git -C ~/sites/frontend worktree remove ~/sites/claude-dev-auth-a
git -C ~/sites/frontend branch -d claude-dev-auth-a
```

> Worktrees are **not** removed automatically — you may want to commit, review, or merge the agent's work first.

---

## Sanity/Next.js co-located repo

For projects where Sanity Studio is embedded in a Next.js app (a single `package.json`, one `npm run dev`), use the `sanity-nextjs` preset:

```bash
# From inside the repo, or pointing at it:
claude-dev --repo-a ./my-app --preset sanity-nextjs

# Features work the same way:
claude-dev --repo-a ./my-app --preset sanity-nextjs --features "homepage,blog"
```

If you run `claude-dev` interactively and the selected repo has both `sanity.config.ts` and `next.config.ts` at its root, the preset is offered automatically.

### What the preset does

- Creates **two worktrees from the same repo**: one for the Sanity agent (`-sanity` branch), one for the Next.js agent (`-nextjs` branch)
- Installs role-specific `CLAUDE.md` templates (`CLAUDE-agent-sanity.md` / `CLAUDE-agent-nextjs.md`) instead of the generic A/B ones
- Defaults roles to `sanity` and `nextjs`
- Adds coordination files to the bridge (see below)

### Agent ownership

| Agent | Owns | Reads but doesn't edit |
|---|---|---|
| **Sanity** | `/sanity/schemas/`, `/sanity/lib/queries/`, `sanity.config.ts`, `sanity.types.ts` | `/app/`, `/components/`, `/lib/` |
| **Next.js** | `/app/`, `/components/`, `/lib/`, `module-registry.ts` | `/sanity/`, `sanity.types.ts` |

### Extra bridge files (preset only)

```
typegen-status          idle | running | done — Next.js agent waits for "done" before using new types
typegen-log.md          output of the last `npx sanity typegen generate` run
schema-contract.md      Sanity agent documents GROQ return shapes; Next.js reads before writing fetch functions
module-registry-queue.md  append-only queue of new module names pending component registration
preset                  "sanity-nextjs" — used internally by the bridge
```

### Module addition workflow

When a new Sanity module is needed (e.g. Hero), the work spans both agents:

**Sanity agent:**
1. Create `sanity/schemas/modules/hero.ts`
2. Add GROQ projection to `sanity/lib/queries/modules.ts`
3. Run typegen → write status to bridge
4. Append `hero|HeroModule` to `module-registry-queue.md`
5. Notify Next.js agent via bridge

**Next.js agent (on notification):**
1. Wait for `typegen-status = done`
2. Read `schema-contract.md` for the type shape
3. Create `components/modules/templates/Hero.tsx`
4. Add entry to `components/modules/module-registry.ts`
5. Confirm back via bridge

### Dev server

Both Next.js and the embedded Studio run from a single command — no separate Studio process:

```bash
npm run dev
# Next.js:  http://localhost:3000
# Studio:   http://localhost:3000/studio
```

### Branch naming

```
{session}-{feature}-sanity    e.g. claude-dev-main-sanity
{session}-{feature}-nextjs    e.g. claude-dev-main-nextjs
```

---

## Payload/Next.js co-located repo

For projects where Payload CMS is embedded in a Next.js app (`src/payload.config.ts` + `next.config.ts`, single dev server), use the `payload-nextjs` preset:

```bash
# From inside the repo, or pointing at it:
claude-dev --repo-a ./my-app --preset payload-nextjs

# Features work the same way:
claude-dev --repo-a ./my-app --preset payload-nextjs --features "homepage,blog"
```

If you run `claude-dev` interactively and the selected repo has both `payload.config.ts` (at root or in `src/`) and `next.config.ts`, the preset is offered automatically.

### What the preset does

- Creates **two worktrees from the same repo**: one for the Payload agent (`-payload` branch), one for the Next.js agent (`-nextjs` branch)
- Installs role-specific `CLAUDE.md` templates (`CLAUDE-agent-payload.md` / `CLAUDE-agent-nextjs-payload.md`) instead of the generic A/B ones
- Defaults roles to `payload` and `nextjs`
- Adds coordination files to the bridge (see below)

### Agent ownership

| Agent | Owns | Reads but doesn't edit |
|---|---|---|
| **Payload** | `src/payload.config.ts`, `src/collections/`, `src/blocks/*/config.ts`, `src/fields/`, `src/plugins/`, `src/hooks/` | `src/app/(frontend)/`, `src/components/`, `src/blocks/*/Component.tsx` |
| **Next.js** | `src/app/(frontend)/`, `src/components/`, `src/heros/`, `src/blocks/*/Component.tsx`, `src/blocks/RenderBlocks.tsx` | `src/collections/`, `src/payload-types.ts` |

### Extra bridge files (preset only)

```
typegen-status          idle | running | done — Next.js agent waits for "done" before using new types
typegen-log.md          output of the last `pnpm payload generate:types` run
schema-contract.md      Payload agent documents collection field shapes and REST endpoints; Next.js reads before writing fetch code
block-registry-queue.md  append-only queue of new block types pending Component.tsx creation
preset                  "payload-nextjs" — used internally by the bridge
```

### Block addition workflow

When a new Payload block is needed (e.g. Hero), the work spans both agents:

**Payload agent:**
1. Create `src/blocks/Hero/config.ts`
2. Register block in `payload.config.ts`
3. Run `pnpm payload generate:types` → write status to bridge
4. Document field shape in `schema-contract.md`
5. Append `hero|HeroBlock` to `block-registry-queue.md`
6. Notify Next.js agent via bridge

**Next.js agent (on notification):**
1. Wait for `typegen-status = done`
2. Read `schema-contract.md` + grep `payload-types.ts` for the type
3. Create `src/blocks/Hero/Component.tsx`
4. Register in `src/blocks/RenderBlocks.tsx`
5. Confirm back via bridge

### Dev server

Payload admin runs inside Next.js — no separate process:

```bash
pnpm dev
# Next.js:  http://localhost:3000
# Admin:    http://localhost:3000/admin
```

### Branch naming

```
{session}-{feature}-payload    e.g. claude-dev-main-payload
{session}-{feature}-nextjs     e.g. claude-dev-main-nextjs
```

---

## Statamic single-repo

For Statamic 6 + Laravel projects (single Laravel app, Control Panel + frontend in one codebase), use the `statamic` preset:

```bash
claude-dev --repo-a ./my-app --preset statamic

# With features:
claude-dev --repo-a ./my-app --preset statamic --features "homepage,blog"
```

If you run `claude-dev` interactively and the selected repo's `composer.json` declares `statamic/cms`, the preset is offered automatically.

This preset assumes **Blade templates only** — Antlers is not used. Templates and bridge contract are written for Blade exclusively.

### What the preset does

- Creates **two worktrees from the same repo**: one for the Statamic agent (`-statamic` branch), one for the frontend agent (`-frontend` branch)
- Installs role-specific `CLAUDE.md` templates (`CLAUDE-agent-statamic.md` / `CLAUDE-agent-frontend-statamic.md`)
- Defaults roles to `statamic` and `frontend`
- Adds coordination files to the bridge (see below)

### Agent ownership

| Agent | Owns | Reads but doesn't edit |
|---|---|---|
| **Statamic** | `resources/blueprints/`, `resources/fieldsets/`, `resources/forms/`, `content/collections/*.yaml`, `content/globals/`, `content/taxonomies/`, `config/statamic/`, `app/Tags/`, `app/Modifiers/`, `app/Scopes/`, `app/Fieldtypes/`, `app/Providers/`, `routes/web.php` | `resources/views/`, `resources/css/`, `resources/scss/`, `resources/js/` |
| **Frontend** | `resources/views/**/*.blade.php`, `resources/views/components/`, `resources/views/partials/`, `resources/views/layouts/`, `resources/css/`, `resources/scss/`, `resources/js/`, `vite.config.js` | `resources/blueprints/`, `resources/fieldsets/`, `content/collections/*.yaml` |

Neither agent commits entry edits (`content/collections/<x>/*.md`) unless explicitly asked — those are runtime content.

### Extra bridge files (preset only)

```
blueprint-status         idle | working | done — frontend agent waits for "done" before coding against new fields
stache-status            clean | dirty — set to "clean" after Statamic agent runs `php please stache:clear`
blueprint-contract.md    Statamic agent documents handle names, field types, expected Blade accessors, and partial paths
module-registry-queue.md append-only queue of new Bard module sets pending Blade template creation
preset                   "statamic" — used internally by the bridge
```

### Bard module set workflow

When a new module set is needed (e.g. `hero`), the work spans both agents:

**Statamic agent:**
1. Add the set to `resources/fieldsets/modules.yaml` (under `sets.module_sets.sets`)
2. Import any new shared fieldsets
3. Run `php please stache:clear` → write `clean` / `done` to bridge statuses
4. Document field shape in `blueprint-contract.md`
5. Append `hero|hero.blade.php` to `module-registry-queue.md`
6. Notify frontend agent via bridge

**Frontend agent (on notification):**
1. Wait for `blueprint-status = done` and `stache-status = clean`
2. Read `blueprint-contract.md` for the field shape and accessors
3. Create `resources/views/components/modules/hero.blade.php`
4. No switch registration — `partials/modules.blade.php` auto-discovers any `components/modules/<handle>.blade.php` via `view()->exists`
5. Confirm back via bridge

### Worktree cross-links

Both agents share one repo but work in separate worktrees. At launch, `launch.sh` symlinks each agent's owned directories into the other's worktree so the running PHP app can see both agents' changes without a merge:

| Path in Statamic worktree (`-statamic`) | Points to |
|---|---|
| `resources/views/` | frontend worktree's `resources/views/` |
| `resources/css/` | frontend worktree's `resources/css/` |
| `resources/scss/` | frontend worktree's `resources/scss/` |
| `resources/js/` | frontend worktree's `resources/js/` |

| Path in frontend worktree (`-frontend`) | Points to |
|---|---|
| `resources/blueprints/` | Statamic worktree's `resources/blueprints/` |
| `resources/fieldsets/` | Statamic worktree's `resources/fieldsets/` |

`git update-index --skip-worktree` is set on all replaced tracked files so `git status` stays clean. **Agents must not commit these paths** — they're cross-links, not owned files.

The PHP server must run from the **Statamic worktree** (`-statamic`) — it's the only worktree where both blueprint changes and view changes are simultaneously visible.

Cross-links are only created in true linked worktrees. If worktree creation falls back to the main repo (detached HEAD, branch conflict), symlinking is skipped entirely to avoid polluting the main repo.

Any symlinks that do get committed into an agent branch (e.g. via an explicit `git add`) are automatically stripped from the merge commit when you run `--preview` or `--end`.

### Dev server

Statamic CP and frontend run from the same Laravel app — no separate process:

```bash
php artisan serve
# Frontend:        http://localhost:3000/
# Control Panel:   http://localhost:3000/cp
```

### Branch naming

```
{session}-{feature}-statamic    e.g. claude-dev-main-statamic
{session}-{feature}-frontend    e.g. claude-dev-main-frontend
```

---

## Session layout

For `--features "auth,payments"` with two repos, the launcher opens **two** terminal windows — one per feature, each split into two panes:

```
Window 1 (auth):
  Left pane:  "frontend agent [auth]"     pane claude-dev-auth-a:0.0
  Right pane: "backend agent [auth]"      pane claude-dev-auth-a:0.1

Window 2 (payments):
  Left pane:  "frontend agent [payments]" pane claude-dev-payments-a:0.0
  Right pane: "backend agent [payments]"  pane claude-dev-payments-a:0.1
```

Both agents in a window share one tmux session. Each window has an independent bridge at:

```
/tmp/claude-bridge-{session}-{feature}/
```

If you accidentally close a terminal window, re-attach with:

```bash
tmux attach -t claude-dev-auth-a
```

For single-repo mode (no Repo B), each window has a single full-pane agent.

---

## How agents communicate

Agents message each other using the bridge script from within their Claude session:

```bash
# Agent A sends a question to Agent B
/tmp/claude-bridge-claude-dev-auth/send-to-agent.sh b "What does POST /api/login return?"

# Agent B sends a response back to Agent A
/tmp/claude-bridge-claude-dev-auth/send-to-agent.sh a "Returns {token, user} on 200. Errors: 401, 422."
```

The script writes the message to a file and injects a prompt into the receiving agent's tmux pane. Each agent's `CLAUDE.md` documents the full path to the bridge so they can find it without being told.

### Bridge directory contents

```
/tmp/claude-bridge-{session}-{feature}/
  a-to-b.md            latest message from A → B
  b-to-a.md            latest message from B → A
  a-status             idle | waiting | pending | working
  b-status             idle | waiting | pending | working
  conversation-log.md  append-only full history
  send-to-agent.sh     bridge script (copied here at launch)
  session-a            tmux pane target for agent A  (e.g. claude-dev-auth-a:0.0)
  session-b            tmux pane target for agent B  (e.g. claude-dev-auth-a:0.1)
  dir-a                absolute path to agent A's worktree
  dir-b                absolute path to agent B's worktree
  role-a / role-b      role labels
```

---

## CLAUDE.md installation

At launch, `CLAUDE.md` is installed into each **worktree** (not the original repo) from the templates `CLAUDE-agent-a.md` / `CLAUDE-agent-b.md`. Placeholders are replaced with real paths, roles, and bridge location.

If a `CLAUDE.md` already exists you're prompted to skip, overwrite, or append. **Append** is recommended for existing projects — it preserves your project instructions and adds the bridge config below a `---` separator.

---

## Saved config

### Per-repo: `.claude-dev`

Written into the **original repos** (not worktrees) after each launch:

```
REPO_A=/abs/path/to/repo-a
REPO_B=/abs/path/to/repo-b
ROLE_A=primary
ROLE_B=secondary
FEATURES=main
SESSION=claude-dev
```

Running `claude-dev` from either repo detects this file and offers to resume. The config stores original repo paths — worktrees are always created fresh from whatever branch those repos are on at launch time.

### Per-machine: `~/.claude-dev-global`

Stores your terminal preference so the picker only runs once per machine:

```
TERMINAL=ghostty   # or: iterm | terminal
```

Delete this file (or run `claude-dev --pick-terminal`) to change your terminal.

---

## Files

```
agent2agent-dev/
  launch.sh                  Main launcher
  install.sh                 One-time setup: installs gum + adds claude-dev to shell
  send-to-agent.sh           Bridge messaging script (copied into each bridge dir at launch)
  CLAUDE-agent-a.md          Agent A instructions template (generic)
  CLAUDE-agent-b.md          Agent B instructions template (generic)
  CLAUDE-agent-sanity.md          Sanity agent template (--preset sanity-nextjs)
  CLAUDE-agent-nextjs.md          Next.js agent template (--preset sanity-nextjs)
  CLAUDE-agent-payload.md         Payload agent template (--preset payload-nextjs)
  CLAUDE-agent-nextjs-payload.md  Next.js agent template (--preset payload-nextjs)
  CLAUDE-agent-statamic.md           Statamic agent template (--preset statamic)
  CLAUDE-agent-frontend-statamic.md  Frontend agent template (--preset statamic)
  README.md                       This file
```

---

## Customising agent templates

`CLAUDE-agent-a.md`, `CLAUDE-agent-b.md`, `CLAUDE-agent-sanity.md`, `CLAUDE-agent-nextjs.md`, `CLAUDE-agent-payload.md`, `CLAUDE-agent-nextjs-payload.md`, `CLAUDE-agent-statamic.md`, and `CLAUDE-agent-frontend-statamic.md` are plain markdown files. Edit them to bake in team conventions, coding standards, or response formats. Every session inherits whatever is in these files.

The `--preset sanity-nextjs` flag uses the `sanity`/`nextjs` templates instead of the generic `a`/`b` ones.
The `--preset payload-nextjs` flag uses the `payload`/`nextjs-payload` templates instead of the generic `a`/`b` ones.
The `--preset statamic` flag uses the `statamic`/`frontend-statamic` templates instead of the generic `a`/`b` ones.

Available placeholders:

| Placeholder | Replaced with |
|-------------|---------------|
| `{{BRIDGE}}` | Absolute path to this feature's bridge directory |
| `{{ROLE_A}}` | `--role-a` value (e.g. `frontend`) |
| `{{ROLE_B}}` | `--role-b` value (e.g. `backend`) |
| `{{DIR_A}}` | Absolute path to agent A's **worktree** |
| `{{DIR_B}}` | Absolute path to agent B's **worktree** |
| `{{FEATURE}}` | Feature name (e.g. `auth`) |
| `{{SESSION}}` | tmux session base name |

> Note: `{{DIR_A}}` and `{{DIR_B}}` resolve to the **worktree paths**, not the original repos. Agents should do all their work there.
