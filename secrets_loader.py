"""
secrets_loader.py — Drop-in replacement for dotenv's load_dotenv().

Instead of reading from .env files, fetches secrets from AWS Secrets Manager
and sets them as environment variables. Existing os.getenv() calls keep working.

Usage:
    # Replace: from dotenv import load_dotenv; load_dotenv()
    # With:    from secrets_loader import load_secrets; load_secrets("finances/env")

    # Or load multiple prefixes:
    load_secrets("finances/env", "claude/global")

    # With .env fallback (for local dev without AWS):
    load_secrets("finances/env", fallback=".env")
"""

import os
import subprocess
import json
import sys


def _get_secret(name, region="us-east-1"):
    """Retrieve a single secret value from AWS Secrets Manager."""
    try:
        result = subprocess.run(
            ["aws", "secretsmanager", "get-secret-value",
             "--secret-id", name, "--region", region,
             "--query", "SecretString", "--output", "text"],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def _list_secrets_by_prefix(prefix, region="us-east-1"):
    """List all secret names under a given prefix."""
    try:
        result = subprocess.run(
            ["aws", "secretsmanager", "list-secrets", "--region", region,
             "--filter", f"Key=name,Values={prefix}/",
             "--query", "SecretList[].Name", "--output", "json"],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
        pass
    return []


def _secret_name_to_env_key(secret_name):
    """Convert 'prefix/some-key-name' to 'SOME_KEY_NAME'."""
    key = secret_name.rsplit("/", 1)[-1]
    return key.upper().replace("-", "_")


def load_secrets(*prefixes, fallback=None, override=False):
    """
    Load secrets from AWS Secrets Manager into os.environ.

    Args:
        *prefixes: One or more SM prefixes (e.g., "finances/env", "skills/exa")
        fallback: Path to .env file to use if AWS is unavailable
        override: If True, overwrite existing env vars (default: False)
    """
    region = os.getenv("AWS_REGION", "us-east-1")
    loaded = 0

    for prefix in prefixes:
        names = _list_secrets_by_prefix(prefix, region)
        for name in names:
            env_key = _secret_name_to_env_key(name)
            if not override and env_key in os.environ:
                continue
            value = _get_secret(name, region)
            if value is not None:
                os.environ[env_key] = value
                loaded += 1

    if loaded == 0 and fallback:
        # AWS unavailable or no secrets found — fall back to .env file
        _load_env_file(fallback)

    return loaded


def load_secret(name, env_key=None, fallback_value=None):
    """
    Load a single secret into os.environ.

    Args:
        name: Full SM secret name (e.g., "skills/exa/exa-api-key")
        env_key: Env var name to set (auto-derived if not given)
        fallback_value: Value to use if AWS is unavailable
    """
    region = os.getenv("AWS_REGION", "us-east-1")
    if env_key is None:
        env_key = _secret_name_to_env_key(name)

    value = _get_secret(name, region)
    if value is not None:
        os.environ[env_key] = value
        return True
    elif fallback_value is not None:
        os.environ[env_key] = fallback_value
    return False


def _load_env_file(path):
    """Minimal .env file parser (no external deps)."""
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip("'\"")
                if key and value:
                    os.environ.setdefault(key, value)


def get_secret(name):
    """Get a secret value without setting it in os.environ."""
    return _get_secret(name, os.getenv("AWS_REGION", "us-east-1"))
