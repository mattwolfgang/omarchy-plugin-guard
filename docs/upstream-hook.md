# Pre-install hooks in Omarchy

Plugin Guard can check every plugin install and update before it lands only if Omarchy asks it to. Today it can't: `omarchy plugin add` and `omarchy plugin update` call no hook, and `omarchy-hook` ignores a hook's exit status. Until that changes, Plugin Guard covers typed commands with a bash function and checks everything else just after it lands (see the README).

## The proposed change

The change is on the `plugin-pre-install-hooks` branch of a fork of [omacom/omarchy](https://github.com/omacom/omarchy), one commit on top of `quattro`:

- `bin/omarchy-hook-gate` (new) runs `~/.config/omarchy/hooks/<name>` and `<name>.d/*` like `omarchy-hook`, but stops at the first one that exits non-zero and returns that status. With no hooks installed it allows the operation.
- `bin/omarchy-plugin-add` calls `omarchy-hook-gate plugin-pre-install <staged-dir> <url> <id>` after validation and the id checks, before moving the checkout into place. A refusal removes the staged checkout.
- `bin/omarchy-plugin-update` calls `omarchy-hook-gate plugin-pre-update <plugin-dir> <id> <current> <incoming>` after fetching and before fast-forwarding. A refusal leaves the plugin on its current commit.
- Both pass `OMARCHY_ASSUME_YES=1` when run with `--yes`, so a hook knows nobody is at a terminal to answer.
- `manual/31-dotfiles.md` and `default/agents/skills/omarchy/hooks.md` document the two events.
- The commits are pinned before a hook runs and checked after it: a hook that changes the checkout gets the install or update refused, never its version installed.
- `test/shell.d/plugin-add-test.sh` covers a refusing install hook, a hook that changes the checkout, an allowing one, and a refusing update hook. The new cases fail on `quattro` and pass with the change.

Sample hook files are not included: they would need a migration to reach existing installs.

## Once Omarchy has it

Run Plugin Guard's `install.sh` again. When `omarchy-hook-gate` exists it links `hooks/plugin-pre-install` and `hooks/plugin-pre-update` into `~/.config/omarchy/hooks/`, and the bash function steps aside, because the real command is then guarded. The hooks call `plugin-guard gate`:

- **In a terminal** it shows the report, refuses anything rated dangerous, and asks before allowing anything rated caution.
- **Without a terminal** (the Plugin Manager, background auto-updates) it refuses anything rated dangerous and caps the model review at `gateTimeoutSeconds` (default 100) to fit the caller's own timeout. If the model doesn't finish in time, the static checks decide and the sweep completes the review after the install.
- **If Plugin Guard is missing**, the hooks allow the operation with a warning rather than blocking every install.

## Pull request text

The description to submit with the change is in [`upstream-pr.md`](upstream-pr.md). It explains why the hooks exist, links Plugin Guard as the reason for them, and covers how a hook like this could be misused and what the change does about it.

To open it, from a clone of Omarchy with that branch checked out:

```bash
gh repo fork omacom/omarchy --remote --remote-name fork
git push fork plugin-pre-install-hooks
gh pr create --repo omacom/omarchy --base quattro --head <your-github-user>:plugin-pre-install-hooks \
  --title "Add plugin-pre-install and plugin-pre-update gate hooks" \
  --body-file <path-to-this-repo>/docs/upstream-pr.md
```
