#!/usr/bin/env bash
# Source this (or set the same variables another way) before running the scripts.
# Everything except VAST_KEY is optional; see the table in README.md.

export VAST_KEY="${VAST_KEY:-$HOME/.ssh/id_ed25519}"

# If the key has a passphrase, keep one agent socket around and point the scripts at it:
#   ssh-agent -a "$HOME/.ssh/vast-agent.sock" && ssh-add "$VAST_KEY"
# export VAST_AGENT="$HOME/.ssh/vast-agent.sock"

# Strongly recommended: a private results repo plus a fine-grained token scoped to it.
# export HF_REPO="you/my-project-runs"
# export HF_TOKEN_FILE="$HOME/.hf_token"    # laptop path; SKILL.md step 5 copies it to /root/.hf_token

# export VAST_RUNS_DIR="$HOME/vast-runs"
