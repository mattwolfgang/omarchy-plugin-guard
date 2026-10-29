#!/bin/bash
# Install Plugin Guard: copy the plugin into the Omarchy shell's plugin folder
# (unless this is already the installed copy, as after `omarchy plugin add`),
# enable it, and link the plugin-guard command into ~/.local/bin.
#
# It also offers two changes to your own configuration, and makes each only
# with your consent: a line in ~/.bashrc that routes typed
# `omarchy plugin add|update` through Plugin Guard, and, on Omarchy versions
# that have pre-install hooks, Plugin Guard as those hooks. In a terminal it
# asks; otherwise it makes neither change unless --bashrc or --hooks says to.
# Re-run after editing to update the installed copy; the shell hot-reloads it.
#
#   ./install.sh [bar-section]            default section: right
#   ./install.sh --bashrc --hooks         make both changes without asking
#   ./install.sh --no-bashrc --no-hooks   make neither, without asking
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="io.github.mattwolfgang.plugin-guard"
dest="$HOME/.config/omarchy/plugins/$id"
section=right
bashrc=ask
hooks=ask
for arg in "$@"; do
  case $arg in
    --bashrc) bashrc=yes ;;
    --no-bashrc) bashrc=no ;;
    --hooks) hooks=yes ;;
    --no-hooks) hooks=no ;;
    -*) echo "install.sh: unknown option $arg" >&2; exit 1 ;;
    *) section=$arg ;;
  esac
done

# Ask once in a terminal; without one, "ask" means no.
consent() {
  local choice=$1 question=$2 answer
  [[ $choice == yes ]] && return 0
  [[ $choice == no ]] && return 1
  [[ -t 0 && -t 1 ]] || return 1
  read -r -p "$question [y/N] " answer || return 1
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

omarchy plugin validate "$src"

if [[ $(realpath -m "$src") != $(realpath -m "$dest") ]]; then
  mkdir -p "$dest/bin" "$dest/i18n" "$dest/shell" "$dest/hooks"
  cp "$src/manifest.json" "$src/BarWidget.qml" "$src/Panel.qml" "$src/LICENSE" "$dest/"
  cp "$src/bin/plugin-guard" "$dest/bin/"
  cp "$src"/i18n/*.json "$dest/i18n/"
  cp "$src/shell/omarchy-plugin-guard.bash" "$dest/shell/"
  cp "$src"/hooks/plugin-pre-* "$dest/hooks/"
fi

mkdir -p "$HOME/.local/bin"
ln -sfn "$dest/bin/plugin-guard" "$HOME/.local/bin/plugin-guard"

if grep -qF "omarchy-plugin-guard.bash" "$HOME/.bashrc" 2>/dev/null; then
  : # Already added on an earlier run.
elif consent "$bashrc" "Add a line to ~/.bashrc so typed 'omarchy plugin add|update' commands are scanned first?"; then
  line="[[ -r $dest/shell/omarchy-plugin-guard.bash ]] && source $dest/shell/omarchy-plugin-guard.bash"
  printf '\n# Plugin Guard: scan plugins typed into `omarchy plugin add|update` first\n%s\n' "$line" >>"$HOME/.bashrc"
  echo "Added Plugin Guard to ~/.bashrc; open a new terminal for it to take effect. Remove that line to undo it."
fi

# Omarchy versions with a blocking pre-install hook (omarchy-hook-gate) check
# every install and update before it lands, including those other tools make.
if command -v omarchy-hook-gate >/dev/null 2>&1; then
  if [[ -e $HOME/.config/omarchy/hooks/plugin-pre-install.d/plugin-guard ]] ||
    consent "$hooks" "Register Plugin Guard as Omarchy's plugin pre-install and pre-update hook?"; then
    for hook in plugin-pre-install plugin-pre-update; do
      mkdir -p "$HOME/.config/omarchy/hooks/$hook.d"
      ln -sfn "$dest/hooks/$hook" "$HOME/.config/omarchy/hooks/$hook.d/plugin-guard"
    done
    echo "Plugin Guard is Omarchy's plugin pre-install and pre-update hook. Delete ~/.config/omarchy/hooks/plugin-pre-*.d/plugin-guard to undo it."
  fi
fi

# A first install is a new folder the shell may not have scanned yet. The
# shell can be busy hot-reloading the files just copied, so retry briefly.
for _ in 1 2 3 4 5; do
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 && break
  sleep 1
done

enabled="$(omarchy plugin list --json | python3 -I -c '
import json, sys
print(any(p.get("id") == sys.argv[1] and p.get("enabled") for p in json.load(sys.stdin)))
' "$id")"

if [[ $enabled != True ]]; then
  omarchy plugin enable "$id" --section "$section"
fi

echo "Installed $id to $dest"
echo "Command: $HOME/.local/bin/plugin-guard"
