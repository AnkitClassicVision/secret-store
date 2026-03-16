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

cp ~/.local/bin/secret-store ~/.local/bin/secret-store 2>/dev/null || cat > ~/.local/bin/secret-store << 'SCRIPT'
#!/bin/bash
# Values pass through a temp file (mode 600, shredded after) so they never
# appear in process args visible via ps/proc.
set -euo pipefail
ACTION="${1:-}" SECRET_NAME="${2:-}" DESCRIPTION="${3:-Managed by ai-harness}"
REGION="${AWS_REGION:-us-east-1}"
usage() {
    cat <<'U'
Usage: secret-store <action> <secret-name> [description]
  create  <name> [desc]  Print command to create a new secret
  update  <name>         Print command to update an existing secret
  verify  <name>         Check that a secret exists and has a value
  delete  <name>         Print command to delete a secret
  list                   List all secrets
  get-arn <name>         Print the ARN of a secret
U
    exit 1
}
_secure_create_cmd() {
    echo "  read -sp 'Enter value: ' v && echo \"\" && \\"
    echo "  f=\$(mktemp) && chmod 600 \"\$f\" && \\"
    echo "  printf '{\"Name\":\"%s\",\"Description\":\"%s\",\"SecretString\":\"%s\"}' '$1' '$2' \"\$v\" > \"\$f\" && \\"
    echo "  aws secretsmanager create-secret --region $REGION --cli-input-json \"file://\$f\" && \\"
    echo "  shred -u \"\$f\" 2>/dev/null || rm -f \"\$f\"; echo 'Created.'"
}
_secure_update_cmd() {
    echo "  read -sp 'Enter value: ' v && echo \"\" && \\"
    echo "  f=\$(mktemp) && chmod 600 \"\$f\" && \\"
    echo "  printf '{\"SecretId\":\"%s\",\"SecretString\":\"%s\"}' '$1' \"\$v\" > \"\$f\" && \\"
    echo "  aws secretsmanager put-secret-value --region $REGION --cli-input-json \"file://\$f\" && \\"
    echo "  shred -u \"\$f\" 2>/dev/null || rm -f \"\$f\"; echo 'Updated.'"
}
[ -z "$ACTION" ] && usage
case "$ACTION" in
    create)
        [ -z "$SECRET_NAME" ] && usage
        if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
            echo "Secret '$SECRET_NAME' already exists. To UPDATE, run in a separate terminal:"
            echo ""; _secure_update_cmd "$SECRET_NAME"
        else
            echo "To CREATE secret '$SECRET_NAME', run in a separate terminal:"
            echo ""; _secure_create_cmd "$SECRET_NAME" "$DESCRIPTION"
        fi ;;
    update)
        [ -z "$SECRET_NAME" ] && usage
        echo "To UPDATE secret '$SECRET_NAME', run in a separate terminal:"
        echo ""; _secure_update_cmd "$SECRET_NAME" ;;
    verify)
        [ -z "$SECRET_NAME" ] && usage
        if aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'Name' --output text &>/dev/null; then
            echo "Secret '$SECRET_NAME' exists and has a value."
        else echo "Secret '$SECRET_NAME' not found or empty."; exit 1
        fi ;;
    delete)
        [ -z "$SECRET_NAME" ] && usage
        echo "To DELETE, run: aws secretsmanager delete-secret --secret-id '$SECRET_NAME' --force-delete-without-recovery --region $REGION" ;;
    list)
        aws secretsmanager list-secrets --region "$REGION" \
            --query 'SecretList[].{Name:Name,Description:Description,LastChanged:LastChangedDate}' \
            --output table 2>/dev/null || echo "No secrets found." ;;
    get-arn)
        [ -z "$SECRET_NAME" ] && usage
        aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" --query 'ARN' --output text ;;
    *) usage ;;
esac
SCRIPT

cat > ~/.local/bin/secret-get << 'SCRIPT'
#!/bin/bash
set -euo pipefail
SECRET_NAME="${1:-}" REGION="${AWS_REGION:-us-east-1}"
[ -z "$SECRET_NAME" ] && { echo "Usage: secret-get <secret-name>" >&2; exit 1; }
aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query 'SecretString' --output text
SCRIPT

cat > ~/.local/bin/secrets-lib.sh << 'SCRIPT'
#!/bin/bash
get_secret() {
    local name="$1" region="${AWS_REGION:-us-east-1}"
    aws secretsmanager get-secret-value --secret-id "$name" --region "$region" --query 'SecretString' --output text 2>/dev/null
}
require_secret() {
    local name="$1" val
    val=$(get_secret "$name")
    [ -z "$val" ] && { echo "FATAL: Required secret '$name' not found. Run: secret-store create '$name'" >&2; exit 1; }
    echo "$val"
}
SCRIPT

chmod +x ~/.local/bin/secret-store ~/.local/bin/secret-get ~/.local/bin/secrets-lib.sh
echo "Installed: secret-store, secret-get, secrets-lib.sh → ~/.local/bin/"

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
