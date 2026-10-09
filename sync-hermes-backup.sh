#!/bin/bash
# Auto-sync Hermes config to a PRIVATE GitHub backup repo
# Configure via env vars: HERMES_DATA, GITHUB_TOKEN (or in $HERMES_DATA/.env),
#                         GITHUB_USER, BACKUP_REPO, GIT_EMAIL, GIT_USERNAME
#
# Usage:
#   export HERMES_DATA="/path/to/hermes/data"
#   export GITHUB_USER="your-username"
#   bash sync-hermes-backup.sh

set -euo pipefail

# --- Configuration (override via env vars) ---
SRC="${HERMES_DATA:-/opt/data}"
DST="${BACKUP_DIR:-/tmp/hermes-backup-sync}"

# Token: prefer the environment, fall back to $SRC/.env
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$SRC/.env" ]; then
    TOKEN=$(grep "^GITHUB_TOKEN=" "$SRC/.env" | head -1 | cut -d= -f2- | tr -d '\n\r' || true)
fi
if [ -z "$TOKEN" ]; then
    echo "ERROR: GITHUB_TOKEN not set (export it or put it in $SRC/.env)" >&2
    exit 1
fi
GITHUB_USER="${GITHUB_USER:-your-username}"
BACKUP_REPO="${BACKUP_REPO:-https://${TOKEN}@github.com/${GITHUB_USER}/hermes-backup.git}"

# --- Safety: refuse to push a backup unless the repo is CONFIRMED private ---
# Fail CLOSED. The API answer is parsed as JSON and only a literal true passes:
# a 404 (typo'd or deleted repo), a 401 (dead token), a rate-limit body or any
# other non-2xx used to produce an EMPTY grep result, which the old "grep -q
# false" test treated as "not public" and let the backup through. An unverifiable
# destination must abort, not proceed.
REPO_PATH=$(echo "$BACKUP_REPO" | sed -E 's#.*github\.com/##; s#\.git$##')
echo "Checking that $REPO_PATH is a private repository..."
VISIBILITY=$(VIS_STATUS=$(curl -s -o /tmp/.hbs-repo.json -w '%{http_code}' \
        -H "Authorization: token ${TOKEN}" \
        "https://api.github.com/repos/$REPO_PATH" || true)
    python3 -c "
import json, sys
status = '$VIS_STATUS'
try:
    data = json.load(open('/tmp/.hbs-repo.json'))
except Exception:
    data = None
private = isinstance(data, dict) and data.get('private') is True
print(('ok' if private else 'not-private') + '|' + status)
" 2>/dev/null || echo "unverifiable|${VIS_STATUS:-none}")
rm -f /tmp/.hbs-repo.json

case "$VISIBILITY" in
    ok\|2*)
        : ;;
    not-private\|2*)
        echo "ERROR: $REPO_PATH is PUBLIC. Backups contain your configuration. Refusing to push." >&2
        echo "Make the repo private, or point BACKUP_REPO at a private repo." >&2
        exit 1
        ;;
    *)
        echo "ERROR: could not CONFIRM that $REPO_PATH is private (GitHub answered: ${VISIBILITY#*|})." >&2
        echo "Refusing to push. Check the token, the repo name, and that the token can read the repo." >&2
        exit 1
        ;;
esac

# --- Clone or pull ---
if [ -d "$DST/.git" ]; then
    cd "$DST"
    git fetch origin main 2>/dev/null || true
    git reset --hard origin/main 2>/dev/null || true
else
    rm -rf "$DST" 2>/dev/null || true
    git clone "$BACKUP_REPO" "$DST"
    cd "$DST"
fi
# The clone's .git/config contains the token: keep the directory private
chmod 700 "$DST"

# Rewrite the remote WITHOUT the token, and hand git the credential through the
# environment instead. `git clone https://$TOKEN@host/repo` leaves the token in
# this clone's .git/config on the backup host (a local at-rest exposure, and the
# exact thing the README's chmod 700 note admits to). git reads GIT_ASKPASS for
# https credentials, so the token stays out of the on-disk config entirely.
CLEAN_URL=$(echo "$BACKUP_REPO" | sed -E 's#://[^@/]*@#://#')
git remote set-url origin "$CLEAN_URL" 2>/dev/null || git remote add origin "$CLEAN_URL"
if git ls-remote origin >/dev/null 2>&1; then
    unset GIT_ASKPASS
else
    # No ambient credential helper for this host: fall back to an askpass script
    # that supplies the token, kept outside the clone and removed on exit.
    ASKPASS=$(mktemp /tmp/.hbs-askpass.XXXXXX)
    printf '#!/bin/sh\ncase "$1" in *Username*) echo "x-access-token" ;; *) echo "%s" ;; esac\n' "$TOKEN" > "$ASKPASS"
    chmod 700 "$ASKPASS"
    export GIT_ASKPASS="$ASKPASS"
    trap 'rm -f "$ASKPASS"' EXIT
fi
# Works for fresh/empty repos too (first-ever backup run)
git checkout -B main 2>/dev/null || git symbolic-ref HEAD refs/heads/main

# --- Copy config and settings (tolerant: skip files your instance doesn't have) ---
for f in config.yaml SOUL.md channel_directory.json; do
    if [ -f "$SRC/$f" ]; then cp "$SRC/$f" .; fi
done

# Session history often contains sensitive commands and prompts.
# Uncomment ONLY if you accept that risk:
# if [ -f "$SRC/.hermes_history" ]; then cp "$SRC/.hermes_history" .; fi

# A SOUL.md is not templated, so an edit can leave a credential in it. Refuse
# rather than publish it: these files are copied verbatim into a repo.
for f in SOUL.md config.yaml channel_directory.json; do
    if [ -f "$f" ] && grep -qEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$f"; then
        echo "ERROR: $f looks like it contains a credential (token or private key)." >&2
        echo "Remove it from $SRC/$f (or extend this exclusion), then re-run." >&2
        exit 1
    fi
done

# --- Create templates (structure only, no secret values) ---
if [ -f "$SRC/.env" ]; then
    grep -E "^[A-Za-z_][A-Za-z0-9_]*=" "$SRC/.env" | sed 's/=.*$/=/' > .env.template || true
fi
if [ -f "$SRC/auth.json" ]; then
    python3 - "$SRC/auth.json" <<'PY' || true
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

def strip_values(obj):
    if isinstance(obj, dict):
        return {k: strip_values(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [strip_values(i) for i in obj]
    elif isinstance(obj, str):
        return '***REDACTED***'
    else:
        return obj

with open('auth.json.template', 'w') as f:
    json.dump(strip_values(data), f, indent=2)
PY
fi

# --- Exclude patterns: large runtime caches, binaries, and runtime STATE ---
# A backup should carry the parts a restore can actually reuse. The state files
# below are written by whatever process is running on the SOURCE machine, and
# several legitimately contain secrets (a pairing token, a session store, an OAuth
# cache), which defeats the point of templating .env and auth.json only.
EXCLUDES=(
    --exclude=.cache
    --exclude=.npm
    --exclude=.pki
    --exclude=node_modules
    --exclude=.local/bin
    --exclude=.local/lib
    --exclude=.local/include
    --exclude=.agent-browser
    --exclude=.config/google-chrome-for-testing
    --exclude=.config/browseruse
    --exclude=.bun
    # --- runtime state (added: these are machine state, not backup material) ---
    --exclude=state.db
    --exclude='state.db*'
    --exclude=kanban.db
    --exclude='kanban.db*'
    --exclude=executions.db
    --exclude='executions.db*'
    --exclude='github-pr-autopilot-state.json*'
    --exclude='*.operational-error.json'
    --exclude='*.done'
    --exclude='*.latch.json'
    --exclude='*.ticks'
    # --- credentials and pairing material that live inside the synced dirs ---
    --exclude=.env
    --exclude=auth.json
    --exclude='*.pem'
    --exclude=pairing
    --exclude=external-workers
)

# Files that must never appear in the backup even if a directory-level exclude
# misses them. Checked after the copy; refusing is better than pushing one.
FORBIDDEN=(
    .env
    auth.json
)

# --- Sync directories ---
for dir in skills memories cron platforms plans skins hooks home; do
    if [ -d "$SRC/$dir" ]; then
        if [ "$dir" = "home" ]; then
            # home/ is typically the largest; select only useful dotfiles.
            # Customize this list for your instance.
            #
            # SECURITY: never add .ssh or any private-key material here.
            # Private keys must not be pushed to ANY remote, even a private
            # repo. If you need key backups, encrypt them first (age,
            # git-crypt) and back up the encrypted file instead.
            rm -rf "home" 2>/dev/null || true
            mkdir -p "home"
            for sub in .hermes .profile; do
                if [ -e "$SRC/home/$sub" ]; then
                    cp -a "$SRC/home/$sub" "home/$sub" 2>/dev/null || true
                fi
            done
        else
            rm -rf "$dir" 2>/dev/null || true
            tar -cf - -C "$SRC" "$dir" --dereference --ignore-failed-read \
                "${EXCLUDES[@]}" 2>/dev/null | tar -xf - 2>/dev/null || true
        fi

        # Clean up artifacts that are useless in a backup.
        #
        # `.tick.lock` is the scheduler's own lock file and safe to drop. A bare
        # `*.lock` is NOT: it also matches `skills/.locks/<sha>.lock` (the skill
        # manager's integrity locks), `memories/*.md.lock` (the memory file locks)
        # and the scheduler's `.fire-*.lock` markers, so the old
        # `find "$dir" -name "*.lock" -delete` deleted real files from the copy and
        # made every backup look like a change. The per-job locks live under cron/,
        # where they are machine state and are excluded wholesale above.
        find "$dir" -name ".tick.lock" -delete 2>/dev/null || true
        find "$dir" -name ".usage.json" -delete 2>/dev/null || true
        find "$dir" -name ".usage.json.lock" -delete 2>/dev/null || true
        find "$dir" -name ".curator_state" -delete 2>/dev/null || true
        find "$dir" -name "request_dump_*" -delete 2>/dev/null || true
        find "$dir" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$dir" -name "*.pyc" -delete 2>/dev/null || true
    fi
done

# --- Safety: no credential file may reach the backup ---
for f in "${FORBIDDEN[@]}"; do
    found=$(find . -name "$f" -not -path "./.git/*" 2>/dev/null | head -3)
    if [ -n "$found" ]; then
        echo "ERROR: refusing to commit credential file(s) into the backup:" >&2
        echo "$found" >&2
        echo "Add an EXCLUDES entry for the directory they came from, then re-run." >&2
        exit 1
    fi
done

# --- Commit and push ---
git config user.email "${GIT_EMAIL:-user@example.com}"
git config user.name "${GIT_USERNAME:-GitHub User}"
git add -A

if git diff --cached --quiet; then
    echo "No changes to sync."
    exit 0
fi

git commit -m "Auto-sync: $(date -u '+%Y-%m-%d %H:%M UTC')"
git push origin main
echo "Synced at $(date -u '+%Y-%m-%d %H:%M UTC')"
