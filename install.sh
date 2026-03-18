#!/bin/bash
# install-secrets-cli.sh — One-liner setup for the secrets management workflow
# Installs secret-store/secret-get to ~/.local/bin and configures all AI harnesses.
#
# Usage (team members):
#   curl -sL https://raw.githubusercontent.com/AnkitClassicVision/secret-store/main/install.sh | bash
#   OR
#   bash /path/to/install-secrets-cli.sh
#
# Prerequisites: AWS CLI configured with access to Secrets Manager
set -euo pipefail

echo "=== Secrets CLI Installer ==="
echo ""

# ── 1. Check AWS CLI ──
if ! command -v aws &>/dev/null; then
    echo "ERROR: AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS CLI not configured. Run 'aws configure' first."
    exit 1
fi

# Verify AWS access (don't print account ID)
aws sts get-caller-identity --query 'Account' --output text >/dev/null
echo "AWS access verified."

# ── 2. Install scripts to ~/.local/bin ──
mkdir -p ~/.local/bin

cat > ~/.local/bin/secret-store << 'SCRIPT'
#!/bin/bash
# secret-store — Manage secrets in AWS Secrets Manager
# Values pass through a temp file (mode 600, shredded after) so they never
# appear in process args visible via ps/proc.
set -euo pipefail

ACTION="${1:-}"
SECRET_NAME="${2:-}"
DESCRIPTION="${3:-Managed by ai-harness}"
REGION="${AWS_REGION:-us-east-1}"

usage() {
    cat <<'USAGE'
Usage: secret-store <action> <secret-name> [description]

Actions:
  create  <name> [desc]  Print command to create a new secret (run in separate terminal)
  update  <name>         Print command to update an existing secret
  verify  <name>         Check that a secret exists and has a value
  delete  <name>         Print command to delete a secret
  list                   List all secrets in the account
  get-arn <name>         Print the ARN of a secret
USAGE
    exit 1
}

[ -z "$ACTION" ] && usage

case "$ACTION" in
    create)
        [ -z "$SECRET_NAME" ] && usage
        if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
            echo "Secret '$SECRET_NAME' already exists."
            echo ""
            echo "To UPDATE it, run this in a separate terminal:"
            echo ""
            cat <<CMD
  read -sp 'Enter value: ' v && echo "" && \\
  f=\$(mktemp) && chmod 600 "\$f" && \\
  printf '{"SecretId":"%s","SecretString":"%s"}' '$SECRET_NAME' "\$v" > "\$f" && \\
  aws secretsmanager put-secret-value --region $REGION --cli-input-json "file://\$f" && \\
  shred -u "\$f" 2>/dev/null || rm -f "\$f"; \\
  echo "Updated."
CMD
        else
            echo "To CREATE secret '$SECRET_NAME', run this in a separate terminal:"
            echo ""
            cat <<CMD
  read -sp 'Enter value: ' v && echo "" && \\
  f=\$(mktemp) && chmod 600 "\$f" && \\
  printf '{"Name":"%s","Description":"%s","SecretString":"%s"}' '$SECRET_NAME' '$DESCRIPTION' "\$v" > "\$f" && \\
  aws secretsmanager create-secret --region $REGION --cli-input-json "file://\$f" && \\
  shred -u "\$f" 2>/dev/null || rm -f "\$f"; \\
  echo "Created."
CMD
        fi
        ;;
    update)
        [ -z "$SECRET_NAME" ] && usage
        echo "To UPDATE secret '$SECRET_NAME', run this in a separate terminal:"
        echo ""
        cat <<CMD
  read -sp 'Enter value: ' v && echo "" && \\
  f=\$(mktemp) && chmod 600 "\$f" && \\
  printf '{"SecretId":"%s","SecretString":"%s"}' '$SECRET_NAME' "\$v" > "\$f" && \\
  aws secretsmanager put-secret-value --region $REGION --cli-input-json "file://\$f" && \\
  shred -u "\$f" 2>/dev/null || rm -f "\$f"; \\
  echo "Updated."
CMD
        ;;
    verify)
        [ -z "$SECRET_NAME" ] && usage
        if aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'Name' --output text &>/dev/null; then
            echo "Secret '$SECRET_NAME' exists and has a value."
        else
            echo "Secret '$SECRET_NAME' not found or empty."
            exit 1
        fi
        ;;
    delete)
        [ -z "$SECRET_NAME" ] && usage
        echo "To DELETE secret '$SECRET_NAME', run this in a separate terminal:"
        echo ""
        echo "  aws secretsmanager delete-secret --secret-id '$SECRET_NAME' --force-delete-without-recovery --region $REGION && echo 'Deleted.'"
        ;;
    list)
        aws secretsmanager list-secrets --region "$REGION" \
            --query 'SecretList[].{Name:Name,Description:Description,LastChanged:LastChangedDate}' \
            --output table 2>/dev/null || echo "No secrets found."
        ;;
    get-arn)
        [ -z "$SECRET_NAME" ] && usage
        aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" \
            --query 'ARN' --output text
        ;;
    *)
        usage
        ;;
esac
SCRIPT

cat > ~/.local/bin/secret-get << 'SCRIPT'
#!/bin/bash
# secret-get — Retrieve a secret value from AWS Secrets Manager
# Use in other scripts: VAL=$(secret-get my-secret-name)
set -euo pipefail

SECRET_NAME="${1:-}"
REGION="${AWS_REGION:-us-east-1}"

if [ -z "$SECRET_NAME" ]; then
    echo "Usage: secret-get <secret-name>" >&2
    exit 1
fi

aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$REGION" \
    --query 'SecretString' \
    --output text
SCRIPT

cat > ~/.local/bin/secret-env << 'SCRIPT'
#!/bin/bash
# secret-env — Load secrets from AWS SM into env, then run a command.
# Usage: secret-env <prefix> [prefix2...] -- <command...>
# Example: secret-env finances/env -- python3 scripts/plaid_client.py
#          secret-env skills/exa skills/dataforseo -- python3 my_script.py
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIXES=()

# Parse prefixes (everything before --)
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        *) PREFIXES+=("$1"); shift ;;
    esac
done

if [ ${#PREFIXES[@]} -eq 0 ] || [ $# -eq 0 ]; then
    echo "Usage: secret-env <prefix> [prefix2...] -- <command...>" >&2
    echo "Example: secret-env finances/env -- python3 my_script.py" >&2
    exit 1
fi

for prefix in "${PREFIXES[@]}"; do
    # List secrets under this prefix
    NAMES=$(aws secretsmanager list-secrets --region "$REGION" \
        --filter "Key=name,Values=${prefix}/" \
        --query 'SecretList[].Name' --output text 2>/dev/null) || continue

    for name in $NAMES; do
        VAL=$(aws secretsmanager get-secret-value --secret-id "$name" --region "$REGION" \
            --query 'SecretString' --output text 2>/dev/null) || continue
        # Convert "prefix/some-key-name" → "SOME_KEY_NAME"
        KEY=$(echo "${name##*/}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        export "$KEY=$VAL"
    done
done

exec "$@"
SCRIPT

cat > ~/.local/bin/secrets-lib.sh << 'SCRIPT'
#!/bin/bash
# secrets.sh — Source this file in any script to load secrets from AWS Secrets Manager
#
# Usage:
#   source "$(dirname "$0")/lib/secrets.sh"
#   API_KEY=$(get_secret "myproject/my-api-key")

get_secret() {
    local name="$1"
    local region="${AWS_REGION:-us-east-1}"
    aws secretsmanager get-secret-value \
        --secret-id "$name" \
        --region "$region" \
        --query 'SecretString' \
        --output text 2>/dev/null
}

require_secret() {
    local name="$1"
    local val
    val=$(get_secret "$name")
    if [ -z "$val" ]; then
        echo "FATAL: Required secret '$name' not found in AWS Secrets Manager." >&2
        echo "Run: secret-store create '$name'" >&2
        exit 1
    fi
    echo "$val"
}
SCRIPT

cat > ~/.local/bin/secret-seed << 'SCRIPT'
#!/bin/bash
# secret-seed — Bulk-create/update secrets from a manifest file.
#
# Manifest format (one per line):
#   name|description
# Lines starting with # are ignored.
#
# Examples:
#   myproject/stripe/api-key|Stripe API key (prod)
#   myproject/db/password|Postgres password
#
# This tool prompts for each secret value using hidden input and sends
# the value to AWS via --cli-input-json file://... so it never appears
# in process args (`ps aux`) or shell history.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
UPDATE_EXISTING="false"
MANIFEST=""
CURRENT_TMP=""

usage() {
    cat <<'USAGE'
Usage: secret-seed [--region <aws-region>] [--update-existing] <manifest-file>

Options:
  --region <region>      AWS region (default: $AWS_REGION or us-east-1)
  --update-existing      Update secrets that already exist (default: skip)

Manifest format:
  name|description
  # comments and blank lines are ignored

Example:
  secret-seed --update-existing ./secrets.seed
USAGE
    exit 1
}

cleanup_tmp() {
    if [ -n "$CURRENT_TMP" ] && [ -f "$CURRENT_TMP" ]; then
        shred -u "$CURRENT_TMP" 2>/dev/null || rm -f "$CURRENT_TMP"
    fi
    CURRENT_TMP=""
}
trap cleanup_tmp EXIT INT TERM

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --region)
            [ $# -lt 2 ] && usage
            REGION="$2"
            shift 2
            ;;
        --update-existing)
            UPDATE_EXISTING="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [ -z "$MANIFEST" ]; then
                MANIFEST="$1"
                shift
            else
                echo "Unexpected argument: $1" >&2
                usage
            fi
            ;;
    esac
done

[ -z "$MANIFEST" ] && usage
[ ! -f "$MANIFEST" ] && { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

if ! command -v aws &>/dev/null; then
    echo "ERROR: AWS CLI not found." >&2
    exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS CLI not configured. Run 'aws configure' first." >&2
    exit 1
fi

created=0
updated=0
skipped=0
failed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip CRLF and trim whitespace
    line="${raw_line%%$'\r'}"
    line="$(trim "$line")"

    [ -z "$line" ] && continue
    case "$line" in
        \#*) continue ;;
    esac

    name="$line"
    desc=""
    if [[ "$line" == *"|"* ]]; then
        name="$(trim "${line%%|*}")"
        desc="$(trim "${line#*|}")"
    fi

    [ -z "$name" ] && continue

    if aws secretsmanager describe-secret --secret-id "$name" --region "$REGION" &>/dev/null; then
        if [ "$UPDATE_EXISTING" != "true" ]; then
            echo "SKIP (exists): $name"
            skipped=$((skipped + 1))
            continue
        fi
        mode="update"
    else
        mode="create"
    fi

    echo ""
    echo "==> $mode: $name"

    while true; do
        read -rsp "Enter value: " v1; echo ""
        read -rsp "Confirm value: " v2; echo ""
        if [ "$v1" != "$v2" ]; then
            echo "Values did not match. Try again."
            continue
        fi
        break
    done

    cleanup_tmp
    CURRENT_TMP="$(mktemp)"
    chmod 600 "$CURRENT_TMP"

    if [ "$mode" = "update" ]; then
        printf '{"SecretId":"%s","SecretString":"%s"}' "$name" "$v1" > "$CURRENT_TMP"
        if aws secretsmanager put-secret-value --region "$REGION" --cli-input-json "file://$CURRENT_TMP" &>/dev/null; then
            updated=$((updated + 1))
        else
            echo "ERROR: failed to update $name" >&2
            failed=$((failed + 1))
            continue
        fi
    else
        [ -z "$desc" ] && desc="Seeded by secret-seed"
        printf '{"Name":"%s","Description":"%s","SecretString":"%s"}' "$name" "$desc" "$v1" > "$CURRENT_TMP"
        if aws secretsmanager create-secret --region "$REGION" --cli-input-json "file://$CURRENT_TMP" &>/dev/null; then
            created=$((created + 1))
        else
            echo "ERROR: failed to create $name" >&2
            failed=$((failed + 1))
            continue
        fi
    fi

    cleanup_tmp
    unset v1 v2

    if aws secretsmanager get-secret-value --secret-id "$name" --region "$REGION" --query 'Name' --output text &>/dev/null; then
        echo "OK: $name"
    else
        echo "WARN: could not verify $name" >&2
    fi
done < "$MANIFEST"

echo ""
echo "Done. Created: $created  Updated: $updated  Skipped: $skipped  Failed: $failed"
[ "$failed" -eq 0 ] || exit 1
SCRIPT

cat > ~/.local/bin/secret-rotation-check << 'SCRIPT'
#!/usr/bin/env python3
"""
secret-rotation-check — Flag secrets that haven't changed recently.

This does NOT rotate secrets automatically. It only checks `LastChangedDate`
from AWS Secrets Manager and prints anything older than N days (default: 30).

Examples:
  secret-rotation-check --prefix myproject --days 30
  secret-rotation-check --prefix myproject --fail
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from typing import Any


def _aws_list_secrets(region: str, prefix: str | None) -> list[dict[str, Any]]:
    cmd = [
        "aws",
        "secretsmanager",
        "list-secrets",
        "--region",
        region,
        "--query",
        "SecretList[].{Name:Name,LastChangedDate:LastChangedDate}",
        "--output",
        "json",
    ]
    if prefix:
        cmd.extend(["--filter", f"Key=name,Values={prefix}/"])

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(stderr or "aws secretsmanager list-secrets failed")

    try:
        data = json.loads(result.stdout)
        if isinstance(data, list):
            return data
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse AWS JSON output: {e}") from e
    return []


def _parse_ts(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(v)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def main() -> int:
    parser = argparse.ArgumentParser(prog="secret-rotation-check")
    parser.add_argument("--prefix", action="append", default=[], help="Limit to secrets under prefix/ (repeatable)")
    parser.add_argument("--days", type=int, default=30, help="Age threshold in days (default: 30)")
    parser.add_argument("--fail", action="store_true", help="Exit non-zero if any stale secrets are found")
    parser.add_argument("--region", default=os.getenv("AWS_REGION", "us-east-1"), help="AWS region (default: $AWS_REGION or us-east-1)")
    args = parser.parse_args()

    prefixes: list[str] = [p.rstrip("/") for p in args.prefix if p.strip()]
    now = dt.datetime.now(dt.timezone.utc)

    secrets: dict[str, dt.datetime] = {}
    try:
        if prefixes:
            for p in prefixes:
                for item in _aws_list_secrets(args.region, p):
                    name = item.get("Name")
                    ts = _parse_ts(item.get("LastChangedDate"))
                    if isinstance(name, str) and ts is not None:
                        secrets[name] = ts
        else:
            for item in _aws_list_secrets(args.region, None):
                name = item.get("Name")
                ts = _parse_ts(item.get("LastChangedDate"))
                if isinstance(name, str) and ts is not None:
                    secrets[name] = ts
    except FileNotFoundError:
        print("ERROR: AWS CLI not found on PATH.", file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    stale: list[tuple[int, str, dt.datetime]] = []
    for name, last_changed in secrets.items():
        age_days = int((now - last_changed).total_seconds() // 86400)
        if age_days >= args.days:
            stale.append((age_days, name, last_changed))

    stale.sort(key=lambda t: (-t[0], t[1]))

    if not stale:
        print(f"OK: No secrets older than {args.days} days.")
        return 0

    print(f"Stale secrets (>= {args.days} days since last change):")
    for age_days, name, last_changed in stale:
        print(f"- {name}  age_days={age_days}  last_changed={last_changed.isoformat()}")

    return 2 if args.fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
SCRIPT

chmod +x \
  ~/.local/bin/secret-store \
  ~/.local/bin/secret-get \
  ~/.local/bin/secret-env \
  ~/.local/bin/secret-seed \
  ~/.local/bin/secret-rotation-check \
  ~/.local/bin/secrets-lib.sh
echo "Installed: secret-store, secret-get, secret-env, secret-seed, secret-rotation-check, secrets-lib.sh → ~/.local/bin/"

# ── 3. Ensure ~/.local/bin is on PATH ──
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    SHELL_RC=""
    if [ -f ~/.zshrc ]; then SHELL_RC=~/.zshrc
    elif [ -f ~/.bashrc ]; then SHELL_RC=~/.bashrc
    fi
    if [ -n "$SHELL_RC" ] && ! grep -q 'local/bin' "$SHELL_RC"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
        echo "Added ~/.local/bin to PATH in $SHELL_RC (restart shell or source it)"
    fi
fi

# ── 4. Install AI harness configs ──
PROTOCOL='## Secrets Management — MANDATORY

**NEVER ask the user to paste API keys, passwords, tokens, or credentials into the conversation.**

When any secret/credential is needed:
1. Run: `secret-store create "project/service/key-name" "Description"`
2. Tell the user to run the printed command in a **separate terminal tab**
3. User types the value there — stored in AWS Secrets Manager, never visible to AI
4. Verify: `secret-store verify "project/service/key-name"`
5. In scripts: `$(secret-get "project/service/key-name")`

Naming: `<project>/<service>/<key>`. NEVER run `secret-get` and display the output.'

# Claude Code global instructions
mkdir -p ~/.claude
if [ -f ~/.claude/CLAUDE.md ]; then
    if ! grep -q "Secrets Management" ~/.claude/CLAUDE.md; then
        echo -e "\n$PROTOCOL" >> ~/.claude/CLAUDE.md
        echo "Updated: ~/.claude/CLAUDE.md"
    else
        echo "Already in: ~/.claude/CLAUDE.md"
    fi
else
    echo -e "# Global Instructions\n\n$PROTOCOL" > ~/.claude/CLAUDE.md
    echo "Created: ~/.claude/CLAUDE.md"
fi

# Gemini CLI global instructions
mkdir -p ~/.gemini
if [ -f ~/.gemini/GEMINI.md ]; then
    if ! grep -q "Secrets Management" ~/.gemini/GEMINI.md; then
        echo -e "\n$PROTOCOL" >> ~/.gemini/GEMINI.md
        echo "Updated: ~/.gemini/GEMINI.md"
    else
        echo "Already in: ~/.gemini/GEMINI.md"
    fi
else
    echo -e "$PROTOCOL" > ~/.gemini/GEMINI.md
    echo "Created: ~/.gemini/GEMINI.md"
fi

# Codex CLI global instructions
mkdir -p ~/.codex
if [ -f ~/.codex/instructions.md ]; then
    if ! grep -q "Secrets Management" ~/.codex/instructions.md; then
        echo -e "\n$PROTOCOL" >> ~/.codex/instructions.md
        echo "Updated: ~/.codex/instructions.md"
    else
        echo "Already in: ~/.codex/instructions.md"
    fi
else
    echo -e "# Global Instructions\n\n$PROTOCOL" > ~/.codex/instructions.md
    echo "Created: ~/.codex/instructions.md"
fi

# Save full protocol doc
mkdir -p ~/.config/ai-harness
cat > ~/.config/ai-harness/secrets-protocol.md << 'DOC'
# Secrets Protocol — For All AI Coding Assistants

## Rule
NEVER ask the user to paste API keys, passwords, tokens, or credentials into the conversation.

## Workflow
1. `secret-store create "<project>/<service>/<key>" "Description"` — prints the command
2. User runs the printed command in a **separate terminal** — types the value there
3. `secret-store verify "<project>/<service>/<key>"` — confirm it's stored
4. In scripts: `VALUE=$(secret-get "<project>/<service>/<key>")`

## Naming Convention
`<project>/<service>/<key-name>` — e.g., `myproject/stripe/api-key`

## Commands (on PATH at ~/.local/bin/)
- `secret-store create <name> [desc]` — Print command to create
- `secret-store update <name>` — Print command to rotate
- `secret-store verify <name>` — Confirm exists
- `secret-store list` — List all secrets
- `secret-store delete <name>` — Print command to remove
- `secret-get <name>` — Retrieve value (scripts only, NEVER display)

## For Script Authors
```bash
source ~/.local/bin/secrets-lib.sh
API_KEY=$(get_secret "project/service/key")
API_KEY=$(require_secret "project/service/key")  # fatal if missing
```

## Auto-configured Tools
The installer configures all three:
- **Claude Code**: ~/.claude/CLAUDE.md
- **Gemini CLI**: ~/.gemini/GEMINI.md
- **Codex CLI**: ~/.codex/instructions.md
DOC
echo "Saved: ~/.config/ai-harness/secrets-protocol.md"

# ── 5. Verify ──
echo ""
echo "=== Setup Complete ==="
echo ""
echo "Test it: secret-store list"
echo ""
echo "To add a secret:  secret-store create 'myproject/service/key' 'Description'"
echo "Then run the printed command in another terminal."
