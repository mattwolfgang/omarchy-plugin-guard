# Plugin Guard for typed commands: `omarchy plugin add|install|update` go
# through plugin-guard, which scans a plugin before installing it and an
# update before applying it. Every other omarchy command runs unchanged.
#
# Sourced from ~/.bashrc by Plugin Guard's install.sh. Bypass it for one
# command with PLUGIN_GUARD_BYPASS=1, or call the real one with
# `command omarchy ...`.
omarchy() {
  local guard=${PLUGIN_GUARD_BIN:-$HOME/.local/bin/plugin-guard}
  # Once Omarchy runs Plugin Guard as its pre-install hook, the real command
  # is already guarded.
  if [[ -e $HOME/.config/omarchy/hooks/plugin-pre-install.d/plugin-guard ]] && command -v omarchy-hook-gate >/dev/null 2>&1; then
    command omarchy "$@"
    return
  fi
  if [[ ${1-} == plugin && -z ${PLUGIN_GUARD_BYPASS-} && -x $guard ]]; then
    case ${2-} in
      add | install)
        shift 2
        "$guard" add "$@"
        return
        ;;
      update)
        shift 2
        "$guard" update "$@"
        return
        ;;
    esac
  fi
  command omarchy "$@"
}
