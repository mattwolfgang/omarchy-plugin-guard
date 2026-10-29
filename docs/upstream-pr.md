## Why

Omarchy plugins run unsandboxed inside the long-lived shell, and `omarchy plugin add` says so before installing one. What a user can't do today is have anything check a plugin before it lands. Neither `omarchy plugin add` nor `omarchy plugin update` runs a hook, and `omarchy-hook` ignores a hook's exit status. Tools that install plugins on the user's behalf call both commands with `--yes`. One example is the community Plugin Manager plugin, with its marketplace installs and background auto-updates. Those pass with no review at all.

This adds two gate hooks, `plugin-pre-install` and `plugin-pre-update`, that see a plugin's code before it reaches `~/.config/omarchy/plugins` and can refuse it.

## What it's for

I wrote [Plugin Guard](https://github.com/mattwolfgang/omarchy-plugin-guard) to screen plugins for remote-access tools, keyloggers, phoning home, credential theft, and similar. It runs fixed static checks, then a review by a local model or a frontier model through the claude, codex, or grok CLI, and refuses anything rated dangerous.

Without a hook it can only wrap `omarchy plugin add|update` in a bash function for typed commands, and check installs made by other tools after they've already landed. With this change it registers as both hooks and checks every install and update, whichever path it came from, before anything is installed. The hook isn't specific to it: an allowlist of trusted authors, a "show me the diff and ask" step, or a company policy check would use the same two events.

## Changes

- New `bin/omarchy-hook-gate`. It runs a hook's scripts like `omarchy-hook` and stops at the first non-zero exit, returning that status. With no hooks installed it allows everything, so nothing changes for anyone who doesn't add one.
- `omarchy plugin add` runs `plugin-pre-install <staged-dir> <url> <id>` after validation and the id checks, just before moving the checkout into place. A refusal deletes the staged checkout.
- `omarchy plugin update` runs `plugin-pre-update <plugin-dir> <id> <current> <incoming>` after the fetch and before the fast-forward. A refusal leaves the plugin on its current commit.
- `OMARCHY_ASSUME_YES=1` tells a hook it was run with `--yes`, so nobody is at a terminal to answer a question.
- Both events are documented in the manual's hooks table and in the hooks skill.
- Tests extend `test/shell.d/plugin-add-test.sh`: a refusing install hook, a hook that changes the checkout, an allowing hook, and a refusing update hook. The new cases fail on `quattro` and pass with the change.

`omarchy-hook` still ignores exit statuses, so existing hooks behave exactly as before.

## Could a hook like this be abused?

I thought about this, because a hook that sits in front of every plugin install is exactly what an attacker would want. Here is what a malicious hook could and couldn't do:

- **It gains no access it didn't already have.** Hooks live in `~/.config/omarchy/hooks/`, which only the user can write, and they run as the user with no added privileges. Anything able to plant a hook could already edit `~/.bashrc`, drop a `post-boot` hook, or change the installed plugins themselves. The gate hooks add no privilege and no new way in.
- **It can't swap in its own code.** This is the one new risk, and the change closes it. A hook is handed a writable checkout, so a malicious one could edit the plugin and then allow it, getting its version installed under a trusted plugin's name. To prevent that, the commit is pinned before the hook runs. Afterwards, `omarchy plugin add` requires the staged checkout to be on that commit with no changed, added, or ignored files. `omarchy plugin update` requires the plugin to be unchanged and fast-forwards to the pinned commit, not whatever `FETCH_HEAD` points to by then. A hook that changes anything gets the operation refused. The test suite covers the install case.
- **It can't block silently.** A hook could refuse every install or hold back every update, for example to keep a vulnerable plugin from being fixed. When that happens, `omarchy-hook-gate` prints `Refused by hook: <path>`, and the add or update fails with a message naming the event, so the cause is visible and the file is easy to find and delete.
- **A hung hook holds up only its own command.** A hook that never exits blocks the `omarchy plugin add` or `update` that ran it, as a stuck clone would. Callers that run unattended already wrap these commands in timeouts; the Plugin Manager plugin uses 180 seconds for installs and 120 for updates. Plugin Guard caps its own unattended review to fit inside that.
- **The manual tells users plainly:** plugin hooks can only allow or refuse, Omarchy names the hook that refused, and hooks run as you, so install only ones you trust.

Not covered: a hook could still read the plugin's code, which is public, and do anything else a user script can. That was already true of every Omarchy hook.

## Testing

- `bash test/shell.d/plugin-add-test.sh`: all cases pass. The four new ones fail without the change.
- End to end, on a real Omarchy install with Plugin Guard as both hooks: `omarchy plugin add` refused a deliberately malicious test plugin and installed a clean one, and `omarchy plugin update --yes` refused a dangerous update and left the plugin on its current commit.
- `./test/cli` has not been run locally.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_018kpnUwzwwWTT2hPMcpBXGM
