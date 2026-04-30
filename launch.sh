#!/bin/bash
# launch.sh — General-purpose multi-agent Claude Code launcher
#
# Usage:
#   bash launch.sh                                     # interactive wizard
#   bash launch.sh --repo-a PATH_OR_OWNER/REPO         # single repo, one agent
#   bash launch.sh --repo-a owner/fe --repo-b owner/be # two-repo pair
#   bash launch.sh --repo-a ./fe --repo-b ./be --features "auth,payments,dashboard"
#
# Options:
#   --repo-a        PATH or OWNER/REPO for agent A (clones via gh if not local)
#   --repo-b        PATH or OWNER/REPO for agent B (optional; omit for single-repo mode)
#   --features      Comma-separated list of feature names (default: "main")
#   --role-a        Label for agent A (default: "primary")
#   --role-b        Label for agent B (default: "secondary")
#   --session       tmux session name (default: "claude-dev")
#   --base-dir      Where to clone repos (default: ~/sites)
#   --pick-terminal Force terminal picker even if ~/.claude-dev-global has one saved
#   --end           Interactively tear down a running session (kill tmux, remove worktrees)

set -euo pipefail

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
  printf 'claude-dev — multi-agent Claude Code launcher\n'
  printf '\n'
  printf 'USAGE\n'
  printf '  claude-dev                          interactive wizard\n'
  printf '  claude-dev --repo-a PATH_OR_REPO    single repo, one agent\n'
  printf '  claude-dev --repo-a fe --repo-b be  two-repo pair\n'
  printf '  claude-dev --end                    tear down the current session\n'
  printf '\n'
  printf 'OPTIONS\n'
  printf '  --repo-a PATH|OWNER/REPO    Repo A (cloned automatically if not local)\n'
  printf '  --repo-b PATH|OWNER/REPO    Repo B (omit for single-repo mode)\n'
  printf '  --features NAMES            Comma-separated feature names (default: main)\n'
  printf '  --role-a LABEL              Agent A label (default: primary)\n'
  printf '  --role-b LABEL              Agent B label (default: secondary)\n'
  printf '  --session NAME              tmux session base name (default: claude-dev)\n'
  printf '  --base-dir PATH             Where to clone repos (default: ~/sites)\n'
  printf '  --preset NAME               Preset: sanity-nextjs (Sanity+Next.js co-located repo)\n'
  printf '  --pick-terminal             Re-run the terminal picker\n'
  printf '  --end                       Kill tmux session, remove worktrees & branches\n'
  printf '  -h, --help                  Show this help\n'
  printf '\n'
  printf 'EXAMPLES\n'
  printf '  claude-dev --repo-a owner/fe --repo-b owner/be --features auth,payments\n'
  printf '  claude-dev --pick-terminal\n'
  printf '  cd ~/sites/my-app && claude-dev --end\n'
  printf '  claude-dev --repo-a ./my-app --preset sanity-nextjs\n'
  printf '\n'
  printf 'Terminal preference is saved to ~/.claude-dev-global after first run.\n'
  printf 'Session config is saved to .claude-dev in each repo after first launch.\n'
}

# ── Defaults ──────────────────────────────────────────────────────────────────
SESSION_NAME="claude-dev"
REPO_A=""
REPO_B=""
RAW_FEATURES=""
ROLE_A="primary"
ROLE_B="secondary"
BASE_DIR="$HOME/sites"
BRIDGE_BASE="/tmp/claude-bridge"
CONFIG_FILE=".claude-dev"
GLOBAL_CONFIG="$HOME/.claude-dev-global"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE_PICK_TERMINAL=false
END_SESSION=false
PRESET=""
RESUMING=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo-a)        REPO_A="$2";      shift 2 ;;
    --repo-b)        REPO_B="$2";      shift 2 ;;
    --features)      RAW_FEATURES="$2";shift 2 ;;
    --session)       SESSION_NAME="$2";shift 2 ;;
    --role-a)        ROLE_A="$2";      shift 2 ;;
    --role-b)        ROLE_B="$2";      shift 2 ;;
    --base-dir)      BASE_DIR="$2";    shift 2 ;;
    --preset)        PRESET="$2";             shift 2 ;;
    --pick-terminal) FORCE_PICK_TERMINAL=true; shift ;;
    --end)           END_SESSION=true; shift ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' is not installed." >&2; exit 1; }
}

require_cmd gum

# ── Terminal detection ────────────────────────────────────────────────────────
detect_terminals() {
  local found=()
  if command -v ghostty &>/dev/null || [[ -x "/Applications/Ghostty.app/Contents/MacOS/ghostty" ]]; then
    found+=("ghostty")
  fi
  [[ -d "/Applications/iTerm.app" ]] && found+=("iterm")
  [[ -d "/System/Applications/Utilities/Terminal.app" ]] && found+=("terminal")
  printf '%s\n' "${found[@]}"
}

# ── Machine-level config (terminal preference) ────────────────────────────────
TERMINAL_APP=""
if [[ -f "$GLOBAL_CONFIG" ]]; then
  _saved=$(grep '^TERMINAL=' "$GLOBAL_CONFIG" 2>/dev/null | cut -d= -f2-)
  [[ -n "$_saved" ]] && TERMINAL_APP="$_saved"
fi

save_global_config() {
  local tmp
  tmp=$(mktemp)
  grep -v '^TERMINAL=' "$GLOBAL_CONFIG" 2>/dev/null >> "$tmp" || true
  echo "TERMINAL=$TERMINAL_APP" >> "$tmp"
  mv "$tmp" "$GLOBAL_CONFIG"
}

# ── Repo resolution ───────────────────────────────────────────────────────────
resolve_repo() {
  local spec="$1" label="$2"
  if [[ -d "$spec" ]]; then
    echo "$(cd "$spec" && pwd)"
    return
  fi
  if [[ "$spec" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    local name="${spec##*/}" dest
    dest="$BASE_DIR/$name"
    if [[ -d "$dest" ]]; then
      gum style --foreground 40 "✓ $label already cloned at $dest" >&2
    else
      mkdir -p "$BASE_DIR"
      gum spin --title "Cloning $spec → $dest …" -- \
        gh repo clone "$spec" "$dest" >&2
    fi
    echo "$dest"
    return
  fi
  echo "Error: Cannot resolve '$spec'. Provide a local path or OWNER/REPO." >&2
  exit 1
}

# ── Repo pickers ──────────────────────────────────────────────────────────────
pick_local_repo() {
  local label="$1"
  if [[ ! -d "$BASE_DIR" ]]; then
    gum style --foreground 196 "$BASE_DIR does not exist — no local repos." >&2
    return 1
  fi

  local dirs=() names=() d chosen
  while IFS= read -r d; do dirs+=("$d"); done \
    < <(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d | sort)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    gum style --foreground 196 "No directories found in $BASE_DIR." >&2
    return 1
  fi

  for d in "${dirs[@]}"; do names+=("${d##*/}"); done

  chosen=$(printf '%s\n' "${names[@]}" \
    | gum filter --header "Select $label" --placeholder "Type to filter…" --height 15)

  for d in "${dirs[@]}"; do
    [[ "${d##*/}" == "$chosen" ]] && echo "$d" && return
  done
}

pick_github_repo() {
  local label="$1"
  require_cmd gh
  gh repo list --limit 200 --json nameWithOwner --jq '.[].nameWithOwner' \
    | gum filter \
        --header "Select $label repo" \
        --placeholder "Type to search…" \
        --height 15
}

# Open one terminal window with a tmux session.
# When dir_b/label_b are supplied the window is split into two side-by-side panes.
open_in_terminal() {
  local dir_a="$1" tmux_session="$2" label_a="$3"
  local dir_b="${4:-}" label_b="${5:-}"

  local agent_script_a launcher
  agent_script_a=$(mktemp /tmp/claude-agent-XXXXXX)
  launcher=$(mktemp /tmp/claude-launcher-XXXXXX)
  chmod +x "$agent_script_a" "$launcher"

  make_agent_script() {
    local script="$1" label="$2" dir="$3"
    { printf '#!/bin/bash\n'
      printf 'clear\n'
      printf 'echo %q\n' "── $label ──"
      printf 'echo %q\n' "$dir"
      printf 'echo\n'
      printf 'exec claude --dangerously-skip-permissions\n'
    } > "$script"
  }

  make_agent_script "$agent_script_a" "$label_a" "$dir_a"

  if [[ -n "$dir_b" ]]; then
    local agent_script_b
    agent_script_b=$(mktemp /tmp/claude-agent-XXXXXX)
    chmod +x "$agent_script_b"
    make_agent_script "$agent_script_b" "$label_b" "$dir_b"

    # Use /usr/bin/env tmux so Terminal.app (minimal PATH) finds it.
    { printf '#!/bin/bash\n'
      printf '/usr/bin/env tmux new-session -d -s %q -c %q %q\n' \
        "$tmux_session" "$dir_a" "$agent_script_a"
      printf '/usr/bin/env tmux split-window -h -t %q -c %q %q\n' \
        "$tmux_session" "$dir_b" "$agent_script_b"
      printf 'exec /usr/bin/env tmux attach-session -t %q\n' \
        "$tmux_session"
    } > "$launcher"
  else
    { printf '#!/bin/bash\n'
      printf 'exec /usr/bin/env tmux new-session -s %q -c %q %q\n' \
        "$tmux_session" "$dir_a" "$agent_script_a"
    } > "$launcher"
  fi

  case "$TERMINAL_APP" in
    ghostty)
      open -na Ghostty --args -e "$launcher" ;;
    iterm)
      osascript -e \
        "tell application \"iTerm2\" to create window with default profile command \"$launcher\"" ;;
    terminal)
      osascript -e \
        "tell application \"Terminal\" to do script \"$launcher\"" ;;
  esac
  sleep 0.4
}

# Create a git worktree for an agent.  Prints the worktree path to stdout.
# Falls back to the original repo dir if not a git repo or HEAD is detached.
create_worktree() {
  local repo_dir="$1" branch="$2"

  if ! git -C "$repo_dir" rev-parse --show-toplevel &>/dev/null; then
    echo "$repo_dir"
    return
  fi

  local repo_root parent_branch wt_dir
  repo_root=$(git -C "$repo_dir" rev-parse --show-toplevel)
  parent_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null)

  if [[ "$parent_branch" == "HEAD" ]]; then
    gum style --foreground 220 \
      "⚠  Detached HEAD in $(basename "$repo_root") — using repo directly." >&2
    echo "$repo_root"
    return
  fi

  wt_dir="$(dirname "$repo_root")/$branch"

  if [[ -d "$wt_dir" ]]; then
    gum style --foreground 220 "⚠  Worktree already exists — reusing $wt_dir" >&2
    echo "$wt_dir"
    return
  fi

  # Suppress all git output — stdout of this function must only contain $wt_dir
  if ! git -C "$repo_root" worktree add -b "$branch" "$wt_dir" "$parent_branch" \
      >/dev/null 2>&1; then
    gum style --foreground 196 "✗ Failed to create worktree $branch" >&2
    echo "$repo_root"
    return
  fi

  gum style --foreground 40 \
    "✓ Worktree: $wt_dir  ($branch ← $parent_branch)" >&2

  echo "$wt_dir"
}

# ── CLAUDE.md installer ───────────────────────────────────────────────────────
install_claude_md() {
  local template="$1" dest="$2" bridge="$3" feature="$4"
  # Optional: pass worktree paths as $5/$6 to override $DIR_A/$DIR_B in templates
  local wt_a="${5:-$DIR_A}" wt_b="${6:-${DIR_B:-}}"
  [[ -f "$SCRIPT_DIR/$template" ]] || return

  local tmp
  tmp=$(mktemp)
  sed \
    -e "s|{{BRIDGE}}|$bridge|g" \
    -e "s|{{ROLE_A}}|$ROLE_A|g" \
    -e "s|{{ROLE_B}}|$ROLE_B|g" \
    -e "s|{{DIR_A}}|$wt_a|g" \
    -e "s|{{DIR_B}}|${wt_b:-none}|g" \
    -e "s|{{FEATURE}}|$feature|g" \
    -e "s|{{SESSION}}|$SESSION_NAME|g" \
    "$SCRIPT_DIR/$template" > "$tmp"

  if [[ -f "$dest" ]]; then
    local choice
    choice=$(gum choose \
      "Skip — leave it untouched" \
      "Overwrite — replace entirely" \
      "Append — add agent config to end" \
      --header "CLAUDE.md already exists: $(basename "$dest") in ${dest%/*}")
    case "$choice" in
      "Overwrite — replace entirely")
        cp "$tmp" "$dest"
        gum style --foreground 40 "✓ Overwrote $dest" >&2
        ;;
      "Append — add agent config to end")
        printf "\n\n---\n\n" >> "$dest"
        cat "$tmp" >> "$dest"
        gum style --foreground 40 "✓ Appended to $dest" >&2
        ;;
      *)
        gum style --faint "  Skipped $dest" >&2
        ;;
    esac
  else
    cp "$tmp" "$dest"
    gum style --foreground 40 "✓ Installed $dest" >&2
  fi

  rm -f "$tmp"
}

# Ensure CLAUDE.md is excluded from git tracking in the repo that contains $dir.
# Uses .git/info/exclude (local, never committed) so it applies to all worktrees
# without modifying .gitignore.
exclude_claude_md_from_git() {
  local dir="$1"
  local git_common_dir
  git_common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return
  mkdir -p "$git_common_dir/info"
  grep -qxF 'CLAUDE.md' "$git_common_dir/info/exclude" 2>/dev/null \
    || echo 'CLAUDE.md' >> "$git_common_dir/info/exclude"
}

# ── Config helpers ────────────────────────────────────────────────────────────
load_config() {
  local cfg="$1" val
  val=$(grep '^REPO_A='    "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && REPO_A="$val"
  val=$(grep '^REPO_B='    "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && REPO_B="$val"
  val=$(grep '^ROLE_A='    "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && ROLE_A="$val"
  val=$(grep '^ROLE_B='    "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && ROLE_B="$val"
  val=$(grep '^FEATURES='  "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && RAW_FEATURES="$val"
  val=$(grep '^SESSION='   "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && SESSION_NAME="$val"
  val=$(grep '^PRESET='    "$cfg" 2>/dev/null | cut -d= -f2-); [[ -n "$val" ]] && PRESET="$val"
}

save_repo_config() {
  local dir="$1"
  [[ -d "$dir" ]] || return
  printf 'REPO_A=%s\nREPO_B=%s\nROLE_A=%s\nROLE_B=%s\nFEATURES=%s\nSESSION=%s\nPRESET=%s\n' \
    "$DIR_A" "${DIR_B:-}" "$ROLE_A" "$ROLE_B" "$RAW_FEATURES" "$SESSION_NAME" "${PRESET:-}" \
    > "$dir/$CONFIG_FILE"
  gum style --foreground 40 "✓ Saved session config → $dir/$CONFIG_FILE" >&2
}

# ── End / teardown mode ───────────────────────────────────────────────────────
if [[ "$END_SESSION" == true ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: No .claude-dev found in current directory." >&2
    echo "Run claude-dev --end from inside a repo that was launched with claude-dev." >&2
    exit 1
  fi
  load_config "$CONFIG_FILE"

  IFS=',' read -ra _end_features <<< "$RAW_FEATURES"
  for i in "${!_end_features[@]}"; do _end_features[$i]="${_end_features[$i]// /}"; done

  _repo_a="$REPO_A"
  _repo_b="${REPO_B:-}"

  # Resolve git roots (same logic as create_worktree uses for dirname).
  _root_a=$(git -C "$_repo_a" rev-parse --show-toplevel 2>/dev/null || echo "$_repo_a")
  _root_b=""
  [[ -n "$_repo_b" ]] && _root_b=$(git -C "$_repo_b" rev-parse --show-toplevel 2>/dev/null || echo "$_repo_b")

  _summary_lines=""
  declare -a _sessions=() _worktrees=() _branches=() _bridges=() _configs=()

  for _f in "${_end_features[@]}"; do
    _sess="${SESSION_NAME}-${_f}-a"
    if [[ "$PRESET" == "sanity-nextjs" ]]; then
      _branch_a="${SESSION_NAME}-${_f}-sanity"
      _branch_b="${SESSION_NAME}-${_f}-nextjs"
    else
      _branch_a="${SESSION_NAME}-${_f}-a"
      _branch_b="${SESSION_NAME}-${_f}-b"
    fi
    _wt_a="$(dirname "$_root_a")/$_branch_a"
    _bridge="$BRIDGE_BASE-${SESSION_NAME}-${_f}"

    _sessions+=("$_sess")
    _bridges+=("$_bridge")
    [[ -d "$_wt_a" ]]  && _worktrees+=("$_root_a|$_wt_a") && _branches+=("$_root_a|$_branch_a")

    if [[ -n "$_root_b" ]]; then
      _wt_b="$(dirname "$_root_b")/$_branch_b"
      [[ -d "$_wt_b" ]] && _worktrees+=("$_root_b|$_wt_b") && _branches+=("$_root_b|$_branch_b")
    fi

    _summary_lines+=$'\n'"  [$_f]"
    tmux has-session -t "$_sess" 2>/dev/null && _summary_lines+=$'\n'"    tmux session:  $_sess"
    [[ -d "$_wt_a" ]]   && _summary_lines+=$'\n'"    worktree:      $_wt_a  (branch $_branch_a)"
    [[ -n "$_root_b" && -d "$(dirname "$_root_b")/$_branch_b" ]] && \
      _summary_lines+=$'\n'"    worktree:      $(dirname "$_root_b")/$_branch_b  (branch $_branch_b)"
    [[ -d "$_bridge" ]] && _summary_lines+=$'\n'"    bridge:        $_bridge"
  done

  _configs+=("$_root_a/$CONFIG_FILE")
  [[ -n "$_root_b" ]] && _configs+=("$_root_b/$CONFIG_FILE")

  gum style \
    --border rounded --border-foreground 196 \
    --bold --padding "0 2" --margin "1 0" \
    "End Session: $SESSION_NAME" \
    "" \
    "Will remove:$_summary_lines" >&2

  if ! gum confirm --default=false "End this session and clean up?"; then
    gum style --faint "Cancelled." >&2
    exit 0
  fi

  # ── Helpers (bash 3.2 compat — no associative arrays) ────────────────────────
  _branches_to_keep=()
  _worktrees_to_keep=()
  _merge_ops=()

  _mark_keep()    { _branches_to_keep+=("$1"); }
  _mark_wt_keep() { _worktrees_to_keep+=("$1"); }
  _is_kept() {
    local _e="$1" _k
    for _k in "${_branches_to_keep[@]:-}"; do [[ "$_k" == "$_e" ]] && return 0; done
    return 1
  }
  _wt_is_kept() {
    local _e="$1" _k
    for _k in "${_worktrees_to_keep[@]:-}"; do [[ "$_k" == "$_e" ]] && return 0; done
    return 1
  }

  # ── Kill tmux sessions first so agents stop before we touch git ───────────────
  for _sess in "${_sessions[@]}"; do
    if tmux kill-session -t "$_sess" 2>/dev/null; then
      gum style --foreground 40 "✓ Killed tmux session $_sess" >&2
    else
      gum style --faint "  (tmux session $_sess not running)" >&2
    fi
  done

  # ── Uncommitted changes check ─────────────────────────────────────────────────
  for _entry in "${_worktrees[@]}"; do
    IFS='|' read -r _uc_repo _uc_wt <<< "$_entry"
    [[ ! -d "$_uc_wt" ]] && continue

    _uc_status=$(git -C "$_uc_wt" status --porcelain 2>/dev/null)
    [[ -z "$_uc_status" ]] && continue

    _uc_branch=$(git -C "$_uc_wt" rev-parse --abbrev-ref HEAD 2>/dev/null)

    gum style \
      --border rounded --border-foreground 196 \
      --padding "0 1" --margin "1 0" \
      "Uncommitted changes: $_uc_branch" \
      "" \
      "$_uc_status" >&2

    _uc_action=$(gum choose \
      "Commit all changes" \
      "Discard changes" \
      "Keep worktree — skip cleanup" \
      --header "Uncommitted changes in $_uc_branch")

    case "$_uc_action" in
      "Commit all changes")
        _uc_msg=$(gum input --placeholder "feat: ..." --prompt "Commit message ❯ ")
        if [[ -n "$_uc_msg" ]]; then
          git -C "$_uc_wt" add -A >/dev/null
          git -C "$_uc_wt" commit -m "$_uc_msg" >/dev/null
          gum style --foreground 40 "✓ Committed to $_uc_branch" >&2
        else
          gum style --faint "  Empty message — keeping worktree" >&2
          _mark_wt_keep "$_entry"
          _mark_keep "$_uc_repo|$_uc_branch"
        fi
        ;;
      "Discard changes")
        git -C "$_uc_wt" reset --hard HEAD >/dev/null 2>&1
        git -C "$_uc_wt" clean -fd >/dev/null 2>&1
        gum style --foreground 40 "✓ Discarded changes in $_uc_branch" >&2
        ;;
      "Keep worktree — skip cleanup")
        _mark_wt_keep "$_entry"
        _mark_keep "$_uc_repo|$_uc_branch"
        gum style --foreground 220 "  Keeping $_uc_wt" >&2
        ;;
    esac
  done

  # ── Merge picker ─────────────────────────────────────────────────────────────
  for _entry in "${_branches[@]}"; do
    IFS='|' read -r _mp_repo _mp_branch <<< "$_entry"
    _mp_repo_name=$(basename "$_mp_repo")

    _is_kept "$_entry" && continue  # user opted out of cleanup for this branch

    _mp_ahead=$(git -C "$_mp_repo" log --oneline "$_mp_branch" --not HEAD 2>/dev/null \
      | wc -l | tr -d ' ')

    if [[ "$_mp_ahead" -eq 0 ]]; then
      gum style --faint "  $_mp_branch — no new commits" >&2
      continue
    fi

    _mp_preview=$(git -C "$_mp_repo" log --oneline --decorate -8 "$_mp_branch" \
      --not HEAD 2>/dev/null)

    gum style \
      --border rounded --border-foreground 220 \
      --padding "0 1" --margin "1 0" \
      "Branch: $_mp_branch  ($_mp_repo_name)" \
      "" \
      "$_mp_ahead commit(s) not in HEAD:" \
      "$_mp_preview" >&2

    _mp_action=$(gum choose \
      "Merge into a branch" \
      "Keep branch (remove worktree only)" \
      "Delete without merging" \
      --header "What to do with $_mp_branch?")

    case "$_mp_action" in
      "Merge into a branch")
        _mp_target=$(git -C "$_mp_repo" branch --format='%(refname:short)' \
          | grep -v "^$_mp_branch$" \
          | gum filter \
              --header "Merge $_mp_branch into:" \
              --placeholder "Type to filter…" \
              --height 15)
        if [[ -n "$_mp_target" ]]; then
          _merge_ops+=("$_mp_repo|$_mp_branch|$_mp_target")
        else
          gum style --faint "  No target selected — keeping branch." >&2
          _mark_keep "$_entry"
        fi
        ;;
      "Keep branch (remove worktree only)")
        _mark_keep "$_entry"
        ;;
      "Delete without merging") ;;  # default: delete
    esac
  done

  # ── Execute merges ───────────────────────────────────────────────────────────
  for _op in ${_merge_ops[@]+"${_merge_ops[@]}"}; do
    IFS='|' read -r _mg_repo _mg_src _mg_tgt <<< "$_op"
    _mg_saved=$(git -C "$_mg_repo" rev-parse --abbrev-ref HEAD 2>/dev/null)

    if ! git -C "$_mg_repo" checkout "$_mg_tgt" >/dev/null 2>&1; then
      gum style --foreground 196 "✗ Could not checkout $_mg_tgt in $(basename "$_mg_repo")" >&2
      continue
    fi

    if git -C "$_mg_repo" merge --no-ff "$_mg_src" 2>/dev/null; then
      gum style --foreground 40 "✓ Merged $_mg_src → $_mg_tgt" >&2
    else
      gum style --foreground 196 \
        "✗ Merge conflict: $_mg_src → $_mg_tgt  — resolve manually, branch kept" >&2
      git -C "$_mg_repo" merge --abort 2>/dev/null || true
      _mark_keep "$_mg_repo|$_mg_src"
    fi

    # Restore original HEAD
    if [[ -n "$_mg_saved" && "$_mg_saved" != "HEAD" ]]; then
      git -C "$_mg_repo" checkout "$_mg_saved" >/dev/null 2>&1 || true
    fi
  done

  for _entry in "${_worktrees[@]}"; do
    IFS='|' read -r _repo _wt <<< "$_entry"
    if _wt_is_kept "$_entry"; then
      gum style --foreground 220 "  Kept worktree $_wt" >&2
      continue
    fi
    if git -C "$_repo" worktree remove "$_wt" 2>/dev/null; then
      gum style --foreground 40 "✓ Removed worktree $_wt" >&2
    else
      gum style --faint "  (worktree $_wt not found or has changes)" >&2
    fi
  done

  for _entry in "${_branches[@]}"; do
    IFS='|' read -r _repo _branch <<< "$_entry"
    if _is_kept "$_entry"; then
      gum style --foreground 220 "  Kept branch $_branch" >&2
      continue
    fi
    if git -C "$_repo" branch -d "$_branch" 2>/dev/null; then
      gum style --foreground 40 "✓ Deleted branch $_branch" >&2
    else
      gum style --faint "  (branch $_branch not found)" >&2
    fi
  done

  for _bridge in "${_bridges[@]}"; do
    if [[ -d "$_bridge" ]]; then
      rm -rf "$_bridge"
      gum style --foreground 40 "✓ Removed bridge $_bridge" >&2
    fi
  done

  for _cfg in "${_configs[@]}"; do
    if [[ -f "$_cfg" ]]; then
      rm -f "$_cfg"
      gum style --foreground 40 "✓ Removed $_cfg" >&2
    fi
  done

  gum style \
    --border rounded --border-foreground 40 \
    --bold --padding "0 2" --margin "1 0" \
    "Session '$SESSION_NAME' ended." >&2
  exit 0
fi

# ── Config auto-detection ─────────────────────────────────────────────────────
if [[ -z "$REPO_A" && -f "$CONFIG_FILE" ]]; then
  _cfg_a=$(grep '^REPO_A='   "$CONFIG_FILE" | cut -d= -f2-)
  _cfg_b=$(grep '^REPO_B='   "$CONFIG_FILE" | cut -d= -f2-)
  _cfg_f=$(grep '^FEATURES=' "$CONFIG_FILE" | cut -d= -f2-)
  _cfg_s=$(grep '^SESSION='  "$CONFIG_FILE" | cut -d= -f2-)

  _info="Repo A:    $_cfg_a"
  [[ -n "$_cfg_b" ]] && _info+=$'\n'"Repo B:    $_cfg_b"
  _info+=$'\n'"Features:  $_cfg_f"
  _info+=$'\n'"Session:   $_cfg_s"

  gum style \
    --border rounded --border-foreground 220 \
    --bold --padding "0 2" --margin "1 0" \
    "Claude Dev — Saved Session" \
    "" \
    "$_info" >&2

  if gum confirm --default=true "Resume saved session?"; then
    load_config "$CONFIG_FILE"
    RESUMING=true
  fi
fi

# ── Terminal picker ───────────────────────────────────────────────────────────
if [[ -z "$TERMINAL_APP" || "$FORCE_PICK_TERMINAL" == true ]]; then
  _available=$(detect_terminals)
  if [[ -z "$_available" ]]; then
    echo "Error: No supported terminal found (Ghostty, iTerm2, Terminal.app)." >&2
    exit 1
  fi
  _count=$(printf '%s\n' "$_available" | wc -l | tr -d ' ')
  if [[ "$_count" -eq 1 && "$FORCE_PICK_TERMINAL" != true ]]; then
    TERMINAL_APP="$_available"
    gum style --foreground 40 "✓ Terminal: $TERMINAL_APP (only option found)" >&2
  else
    TERMINAL_APP=$(printf '%s\n' "$_available" \
      | gum choose --header "Select terminal emulator for agent windows")
  fi
  save_global_config
  gum style --foreground 40 "✓ Saved terminal preference → $GLOBAL_CONFIG" >&2
fi

# ── Interactive wizard ────────────────────────────────────────────────────────
if [[ -z "$REPO_A" ]]; then
  gum style \
    --border rounded --border-foreground 51 \
    --bold --padding "0 2" --margin "1 0" \
    "Claude Dev Launcher" >&2

  _src=$(gum choose \
    "Pick from $BASE_DIR" \
    "Clone from GitHub" \
    "Enter a local path" \
    --header "Repo A ($ROLE_A) — source")
  case "$_src" in
    "Pick from $BASE_DIR") REPO_A=$(pick_local_repo "Repo A") ;;
    "Clone from GitHub")   REPO_A=$(pick_github_repo "Repo A") ;;
    *)                     REPO_A=$(gum input --placeholder "~/sites/my-repo" --prompt "Repo A ❯ ") ;;
  esac
fi

# ── Preset auto-detection ─────────────────────────────────────────────────────
if [[ -z "$PRESET" ]]; then
  _check_dir="${REPO_A/#\~/$HOME}"
  if [[ -d "$_check_dir" && -f "$_check_dir/sanity.config.ts" && -f "$_check_dir/next.config.ts" ]]; then
    if gum confirm --default=true "Sanity+Next.js project detected. Use sanity-nextjs preset?"; then
      PRESET="sanity-nextjs"
    fi
  fi
fi

if [[ -z "$REPO_B" && "$PRESET" != "sanity-nextjs" ]]; then
  _src=$(gum choose \
    "Pick from $BASE_DIR" \
    "Clone from GitHub" \
    "Enter a local path" \
    "Skip — single-repo mode" \
    --header "Repo B ($ROLE_B) — source (optional)")
  case "$_src" in
    "Pick from $BASE_DIR")    REPO_B=$(pick_local_repo "Repo B") ;;
    "Clone from GitHub")      REPO_B=$(pick_github_repo "Repo B") ;;
    "Enter a local path")     REPO_B=$(gum input --placeholder "~/sites/my-repo" --prompt "Repo B ❯ ") ;;
    "Skip — single-repo mode") REPO_B="" ;;
  esac
fi

if [[ -z "$RAW_FEATURES" ]]; then
  RAW_FEATURES=$(gum input \
    --placeholder "auth,payments,dashboard" \
    --prompt "Features ❯ " \
    --value "main")
  [[ -z "$RAW_FEATURES" ]] && RAW_FEATURES="main"
fi

# ── Parse feature list ────────────────────────────────────────────────────────
IFS=',' read -ra FEATURES <<< "$RAW_FEATURES"
for i in "${!FEATURES[@]}"; do
  FEATURES[$i]="${FEATURES[$i]// /}"
done

# ── Validate dependencies ─────────────────────────────────────────────────────
require_cmd tmux
require_cmd claude

# ── Apply preset ──────────────────────────────────────────────────────────────
if [[ "$PRESET" == "sanity-nextjs" ]]; then
  [[ "$ROLE_A" == "primary" ]]   && ROLE_A="sanity"
  [[ "$ROLE_B" == "secondary" ]] && ROLE_B="nextjs"
  REPO_B="$REPO_A"
fi

# ── Resolve repos to local paths ──────────────────────────────────────────────
DIR_A=$(resolve_repo "$REPO_A" "$ROLE_A")
DIR_B=""
[[ -n "$REPO_B" ]] && DIR_B=$(resolve_repo "$REPO_B" "$ROLE_B")

# ── Persist session config into both repos ────────────────────────────────────
save_repo_config "$DIR_A"
[[ -n "$DIR_B" ]] && save_repo_config "$DIR_B"

# ── Print session config ──────────────────────────────────────────────────────
_summary="Session:   $SESSION_NAME"$'\n'"Repo A:    $DIR_A  ($ROLE_A)"
[[ -n "$DIR_B" && "$PRESET" != "sanity-nextjs" ]] && _summary+=$'\n'"Repo B:    $DIR_B  ($ROLE_B)"
[[ "$PRESET" == "sanity-nextjs" ]] && _summary+=$'\n'"Preset:    sanity-nextjs"
_summary+=$'\n'"Features:  ${FEATURES[*]}"
gum style \
  --border rounded --border-foreground 51 \
  --padding "0 2" --margin "1 0" \
  "$_summary" >&2

# ── Create worktrees + open terminal windows per agent per feature ────────────
CLEANUP_HINTS=()

for feature in "${FEATURES[@]}"; do
  BRIDGE="$BRIDGE_BASE-${SESSION_NAME}-${feature}"
  SESSION_A="${SESSION_NAME}-${feature}-a"
  SESSION_B="${SESSION_NAME}-${feature}-b"
  if [[ "$PRESET" == "sanity-nextjs" ]]; then
    BRANCH_A="${SESSION_NAME}-${feature}-sanity"
    BRANCH_B="${SESSION_NAME}-${feature}-nextjs"
  else
    BRANCH_A="${SESSION_NAME}-${feature}-a"
    BRANCH_B="${SESSION_NAME}-${feature}-b"
  fi

  # Create isolated worktrees for each agent
  WT_A=$(create_worktree "$DIR_A" "$BRANCH_A")
  WT_B=""
  [[ -n "$DIR_B" ]] && WT_B=$(create_worktree "$DIR_B" "$BRANCH_B")

  exclude_claude_md_from_git "$WT_A"
  [[ -n "$WT_B" ]] && exclude_claude_md_from_git "$WT_B"

  rm -rf "$BRIDGE"
  mkdir -p "$BRIDGE"
  printf "" > "$BRIDGE/a-to-b.md"
  printf "" > "$BRIDGE/b-to-a.md"
  printf "" > "$BRIDGE/conversation-log.md"
  echo "idle"    > "$BRIDGE/a-status"
  echo "idle"    > "$BRIDGE/b-status"
  echo "$WT_A"   > "$BRIDGE/dir-a"
  echo "${WT_B:-}" > "$BRIDGE/dir-b"
  echo "$ROLE_A" > "$BRIDGE/role-a"
  echo "${ROLE_B:-}" > "$BRIDGE/role-b"
  # Both agents share one tmux session; target panes explicitly for send-to-agent.
  echo "$SESSION_A:0.0" > "$BRIDGE/session-a"
  [[ -n "$WT_B" ]] && echo "$SESSION_A:0.1" > "$BRIDGE/session-b"

  if [[ "$PRESET" == "sanity-nextjs" ]]; then
    echo "idle"           > "$BRIDGE/typegen-status"
    printf ""             > "$BRIDGE/typegen-log.md"
    printf ""             > "$BRIDGE/schema-contract.md"
    printf ""             > "$BRIDGE/module-registry-queue.md"
    echo "sanity-nextjs"  > "$BRIDGE/preset"
  fi

  tmux kill-session -t "$SESSION_A" 2>/dev/null || true

  cp "$SCRIPT_DIR/send-to-agent.sh" "$BRIDGE/send-to-agent.sh"
  chmod +x "$BRIDGE/send-to-agent.sh"

  if [[ "$PRESET" == "sanity-nextjs" ]]; then
    _tmpl_a="CLAUDE-agent-sanity.md"
    _tmpl_b="CLAUDE-agent-nextjs.md"
  else
    _tmpl_a="CLAUDE-agent-a.md"
    _tmpl_b="CLAUDE-agent-b.md"
  fi
  if [[ "$RESUMING" == false ]]; then
    install_claude_md "$_tmpl_a" "$WT_A/CLAUDE.md" "$BRIDGE" "$feature" \
      "$WT_A" "${WT_B:-}"
    [[ -n "$WT_B" ]] && install_claude_md "$_tmpl_b" "$WT_B/CLAUDE.md" "$BRIDGE" "$feature" \
      "$WT_A" "$WT_B"
  fi

  if [[ -n "$WT_B" ]]; then
    open_in_terminal "$WT_A" "$SESSION_A" "$ROLE_A agent [$feature]" \
      "$WT_B" "$ROLE_B agent [$feature]"
  else
    open_in_terminal "$WT_A" "$SESSION_A" "$ROLE_A agent [$feature]"
  fi

  gum style --foreground 40 \
    "✓ Launched '$feature' — $SESSION_A${WT_B:+ · $SESSION_B}" >&2

done

# ── Final summary ─────────────────────────────────────────────────────────────
feat_count=${#FEATURES[@]}
_ready="Claude Dev — $feat_count feature(s) launched: ${FEATURES[*]}"$'\n'
_ready+=$'\n'"  Repo A:  $DIR_A"
[[ -n "$DIR_B" && "$PRESET" != "sanity-nextjs" ]] && _ready+=$'\n'"  Repo B:  $DIR_B"
[[ "$PRESET" == "sanity-nextjs" ]] && _ready+=$'\n'"  Preset:  sanity-nextjs  (Studio at localhost:3000/studio)"
_ready+=$'\n'
_ready+=$'\n'"  Each agent has its own worktree + $TERMINAL_APP window."
_ready+=$'\n'"  Re-attach:  tmux attach -t ${SESSION_NAME}-<feature>-a"
_ready+=$'\n'
_ready+=$'\n'"  When done, run from either repo:"
_ready+=$'\n'"    claude-dev --end"

gum style \
  --border rounded --border-foreground 40 \
  --bold --padding "0 2" --margin "1 0" \
  "$_ready"
