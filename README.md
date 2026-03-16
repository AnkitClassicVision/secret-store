# secret-store

A CLI toolkit for managing secrets through AWS Secrets Manager — designed so **AI coding assistants never see your credentials**.

## The Problem

When using AI coding tools (Claude Code, Gemini CLI, Codex, Cursor, etc.), you're often asked to paste API keys and passwords directly into the conversation. That means your secrets end up in:
- AI conversation logs
- Process arguments visible via `ps aux`
- Shell history

**secret-store** solves this by routing all credential entry through a separate terminal, with the value going straight to AWS Secrets Manager over TLS. The AI only ever knows the **name** of the secret, never the value.

## How It Works

```
AI assistant needs an API key
        |
        v
AI runs:  secret-store create "myproject/stripe/api-key"
        |
        v
Prints a command for YOU to run in a separate terminal
        |
        v
You paste the command, type the value --> encrypted in AWS Secrets Manager
        |
        v
AI verifies:  secret-store verify "myproject/stripe/api-key"
        |
        v
Scripts retrieve at runtime:  $(secret-get "myproject/stripe/api-key")
```

The secret value **never appears** in the AI conversation, process args, or shell history.

## Security Model

| Stage | Protection |
|-------|-----------|
| User types value | `read -sp` — hidden input, no echo to terminal |
| On disk (briefly) | `mktemp` + `chmod 600` — only owner can read |
| Passed to AWS CLI | `--cli-input-json file://` — not in process args, invisible to `ps aux` |
| After use | `shred -u` overwrites file with random data, then deletes |
| In transit | AWS CLI uses HTTPS/TLS |
| At rest | AWS Secrets Manager encrypts with AES-256 via KMS |
| In AI conversation | Never appears — AI only sees the secret **name** |

## Quick Start

### One-Line Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/AnkitClassicVision/secret-store/main/install.sh)
```

Or clone and run:

```bash
git clone https://github.com/AnkitClassicVision/secret-store.git
bash secret-store/install.sh
```

### Prerequisites

- **AWS CLI** installed and configured (`aws configure`)
- IAM permissions for `secretsmanager:*` (or scoped to your prefix)
- `~/.local/bin` on your `PATH` (the installer handles this)

### Manual Install

```bash
cp secret-store secret-get secrets-lib.sh ~/.local/bin/
chmod +x ~/.local/bin/secret-store ~/.local/bin/secret-get ~/.local/bin/secrets-lib.sh
```

## Usage

### Store a Secret

```bash
$ secret-store create "myproject/stripe/api-key" "Stripe API key for production"
To CREATE secret 'myproject/stripe/api-key', run this in a separate terminal:

  read -sp 'Enter value: ' v && echo "" && \
  f=$(mktemp) && chmod 600 "$f" && \
  printf '{"Name":"%s","Description":"%s","SecretString":"%s"}' 'myproject/stripe/api-key' 'Stripe API key for production' "$v" > "$f" && \
  aws secretsmanager create-secret --region us-east-1 --cli-input-json "file://$f" && \
  shred -u "$f" 2>/dev/null || rm -f "$f"; \
  echo "Created."
```

Copy that command, open a new terminal tab, paste it, type your secret.

### Verify It Exists

```bash
$ secret-store verify "myproject/stripe/api-key"
Secret 'myproject/stripe/api-key' exists and has a value.
```

### Use in Scripts

```bash
# Option 1: Direct
API_KEY=$(secret-get "myproject/stripe/api-key")

# Option 2: Source the library
source ~/.local/bin/secrets-lib.sh
API_KEY=$(get_secret "myproject/stripe/api-key")

# Option 3: Fail if missing
API_KEY=$(require_secret "myproject/stripe/api-key")
```

### Rotate a Secret

```bash
$ secret-store update "myproject/stripe/api-key"
# Prints command to run in separate terminal
```

### List All Secrets

```bash
$ secret-store list
```

### Delete a Secret

```bash
$ secret-store delete "myproject/stripe/api-key"
# Prints command to run in separate terminal
```

## Naming Convention

```
<project>/<service>/<key-name>
```

Examples:
- `webapp/stripe/api-key`
- `backend/database/password`
- `mobile-app/firebase/server-key`

## AI Harness Integration

The installer automatically configures these AI tools to use the secrets protocol:

| Tool | Config File | What It Does |
|------|------------|--------------|
| **Claude Code** | `~/.claude/CLAUDE.md` | Global instruction for all projects |
| **Gemini CLI** | `~/.gemini/GEMINI.md` | Global instruction for all sessions |
| **Codex / Other** | `AGENTS.md` (per repo) | Add protocol reference manually |

### Adding to a New AI Tool

Drop this into your AI tool's instruction file:

```markdown
## Secrets Management — MANDATORY

NEVER ask the user to paste API keys, passwords, tokens, or credentials into the conversation.

When any secret/credential is needed:
1. Run: `secret-store create "project/service/key-name" "Description"`
2. Tell the user to run the printed command in a separate terminal tab
3. User types the value there — stored in AWS Secrets Manager, never visible to AI
4. Verify: `secret-store verify "project/service/key-name"`
5. In scripts: `$(secret-get "project/service/key-name")`
```

Or reference the full protocol: `AI-HARNESS-PROTOCOL.md`

## Team Setup

Each team member needs:

1. **AWS CLI configured** with their own IAM credentials
2. **IAM permissions** for Secrets Manager (example policy below)
3. **Run the installer**: `bash install.sh`

### Minimum IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:ListSecrets"
      ],
      "Resource": "arn:aws:secretsmanager:*:ACCOUNT_ID:secret:myproject/*"
    }
  ]
}
```

Replace `ACCOUNT_ID` with your AWS account ID and `myproject/*` with your prefix to scope access.

## Commands Reference

| Command | Description |
|---------|-------------|
| `secret-store create <name> [desc]` | Print command to create a new secret |
| `secret-store update <name>` | Print command to rotate a secret's value |
| `secret-store verify <name>` | Confirm a secret exists and has a value |
| `secret-store list` | List all secrets in the account |
| `secret-store delete <name>` | Print command to delete a secret |
| `secret-store get-arn <name>` | Print the ARN of a secret |
| `secret-get <name>` | Retrieve a secret's value (for scripts) |

## Files

| File | Purpose |
|------|---------|
| `secret-store` | Main CLI — create, update, verify, list, delete secrets |
| `secret-get` | Retrieve a secret value (for use in scripts) |
| `secrets-lib.sh` | Sourceable library with `get_secret()` and `require_secret()` |
| `install.sh` | One-line installer for scripts + AI harness configs |
| `AI-HARNESS-PROTOCOL.md` | Full protocol doc for any AI tool integration |

## License

MIT
