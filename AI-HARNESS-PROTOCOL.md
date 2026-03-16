# Secrets Protocol — For All AI Coding Assistants

## Rule
NEVER ask the user to paste API keys, passwords, tokens, or credentials into the conversation.

## Workflow
When any secret or credential is needed:

1. Generate the AWS Secrets Manager creation command:
   ```bash
   secret-store create "<project>/<service>/<key>" "Description of what this is"
   ```
2. Instruct the user to open a **separate terminal** and run the printed command
3. The user types the secret value there — it is stored encrypted in AWS Secrets Manager and never visible to the AI
4. Confirm storage: `secret-store verify "<project>/<service>/<key>"`
5. In code/scripts, retrieve at runtime:
   ```bash
   VALUE=$(secret-get "<project>/<service>/<key>")
   ```

## Naming Convention
`<project>/<service>/<key-name>`

Examples:
- `myproject/stripe/api-key`
- `webapp/sendgrid/api-key`
- `backend/database/password`

## Commands (on PATH at ~/.local/bin/)
| Command | Purpose |
|---------|---------|
| `secret-store create <name> [desc]` | Print command to create a new secret |
| `secret-store update <name>` | Print command to rotate a value |
| `secret-store verify <name>` | Confirm secret exists and has value |
| `secret-store list` | List all stored secrets |
| `secret-store delete <name>` | Print command to remove a secret |
| `secret-get <name>` | Retrieve value (for scripts only — NEVER display) |

## For Script Authors
Source the helper library:
```bash
source ~/.local/bin/secrets-lib.sh  # if installed globally
# OR
source scripts/lib/secrets.sh       # if using per-repo copy

API_KEY=$(get_secret "project/service/key")
# or with fatal-on-missing:
API_KEY=$(require_secret "project/service/key")
```

## Integration

The installer (`install.sh`) automatically configures all three major AI coding tools:

| Tool | Global Config | Auto-configured |
|------|--------------|-----------------|
| **Claude Code** | `~/.claude/CLAUDE.md` | Yes |
| **Gemini CLI** | `~/.gemini/GEMINI.md` | Yes |
| **Codex CLI** | `~/.codex/instructions.md` | Yes |

For any other AI tool, add the Secrets Management block from this file into the tool's instruction config, or reference this file directly.
