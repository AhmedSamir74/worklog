#!/bin/sh
# Installs `wl` for the current user.
#   sh install.sh                 -> install wl, add ~/.local/bin to PATH
#   sh install.sh /path/to/repo … -> also install the git hooks in those repos
# Re-running is safe.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
JIRA_URL="${JIRA_URL:-https://jira.alinma.com}"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required (xcode-select --install)"; exit 1; }

mkdir -p "$BIN"
cp "$HERE/wl" "$BIN/wl"
chmod 755 "$BIN/wl"
echo "installed $BIN/wl"

# PATH: add once to the user's shell profile
case "$SHELL" in
  */zsh)  RC="$HOME/.zshrc" ;;
  */bash) RC="$HOME/.bashrc" ;;
  *)      RC="$HOME/.profile" ;;
esac
if ! grep -qs '\.local/bin' "$RC"; then
  printf '\n# worklog (wl)\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
  echo "added ~/.local/bin to PATH in $RC (open a new terminal or: source $RC)"
fi
export PATH="$BIN:$PATH"

# Jira base URL (token is entered by `wl setup`)
"$BIN/wl" config set jira_base_url "$JIRA_URL" >/dev/null
echo "jira url: $JIRA_URL"

# Git hooks for the repos given on the command line
if [ "$#" -gt 0 ]; then
  "$BIN/wl" install-hooks "$@"
fi

cat <<EOF

Next:
  1. wl setup                       # paste a Jira Personal Access Token
  2. cd <your repo> && wl install-hooks   # if you did not pass repos above
  3. wl report                      # at the end of the day
EOF
