"""Regression tests for skipping your own plugins (plugin-guard own). A plugin
counts as yours only when GitHub confirms it, or when it is built locally in a
folder you trust or listed by id; everything else is scanned. Run by
tests/run.sh as: python3 -I own.py <bin/plugin-guard>. GitHub is a fake API
server on 127.0.0.1; nothing leaves the machine.
"""
import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

GUARD = Path(sys.argv[1]).resolve()
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "clean-clock"
loader = importlib.machinery.SourceFileLoader("plugin_guard", str(GUARD))
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)

failed = False
work = Path(tempfile.mkdtemp(prefix="plugin-guard-own-"))
plugins = work / "config" / "omarchy" / "plugins"
plugins.mkdir(parents=True)
projects = work / "projects"
elsewhere = work / "elsewhere"
projects.mkdir()
elsewhere.mkdir()

# path -> (status, body); the handler records every path it was asked for.
routes, asked = {}, []


class FakeGitHub(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    asked.append(self.path)
    status, body = routes.get(self.path, (404, {"message": "Not Found"}))
    data = json.dumps(body).encode()
    self.send_response(status)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(data)))
    self.end_headers()
    self.wfile.write(data)

  def log_message(self, *_):
    pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
threading.Thread(target=server.serve_forever, daemon=True).start()
ENV = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"), XDG_STATE_HOME=str(work / "state"))
ENV.pop("PLUGIN_GUARD_CATALOG_URL", None)
API = f"http://127.0.0.1:{server.server_port}"
# Plugin Guard always asks api.github.com; nothing in its environment can
# change that. The tests load it as a module and point it at the fake.
RUN = """
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("plugin_guard", sys.argv[1])
spec = importlib.util.spec_from_loader("plugin_guard", loader)
pg = importlib.util.module_from_spec(spec)
loader.exec_module(pg)
pg.GITHUB_API = sys.argv[2]
sys.exit(pg.main(sys.argv[3:]))
"""
# The marketplace catalog is never fetched: a cached empty one is fresh.
(work / "state" / "plugin-guard").mkdir(parents=True)
(work / "state" / "plugin-guard" / "marketplace.json").write_text(json.dumps(
  {"url": pg.MARKETPLACE_URL, "fetchedAt": pg.now_iso(), "verified": {}}))


def guard(*args, check=True):
  r = subprocess.run([sys.executable, "-I", "-c", RUN, str(GUARD), API, *args], env=ENV, capture_output=True, text=True,
                     timeout=120, stdin=subprocess.DEVNULL)
  if check and r.returncode != 0:
    raise AssertionError(f"plugin-guard {' '.join(args)} failed: {r.stderr.strip()[-500:]}")
  return r


def git(cwd, *args):
  return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                         *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


def make_plugin(where, plugin_id, remote=None, commit=True):
  shutil.copytree(FIXTURE, where)
  manifest = json.loads((where / "manifest.json").read_text())
  manifest["id"] = plugin_id
  (where / "manifest.json").write_text(json.dumps(manifest))
  if remote is not None:
    git(where, "init", "-q", "-b", "main")
    if remote:
      git(where, "remote", "add", "origin", remote)
    if commit:
      git(where, "add", "-A")
      git(where, "commit", "-q", "-m", "init")
  return where


def skipped(plugin_id, *extra):
  """The ownPlugin reason of a check of an installed plugin, or None if it was scanned."""
  report = json.loads(guard("check", plugin_id, "--no-model", "--json", *extra).stdout)
  return (report.get("ownPlugin") or {}).get("reason")


def clear_cache():
  (work / "state" / "plugin-guard" / "ownership.json").unlink(missing_ok=True)


def case(name):
  def wrap(fn):
    global failed
    try:
      problem = fn()
    except Exception as e:  # a test that raises has failed
      problem = f"{type(e).__name__}: {e}"
    if problem:
      failed = True
      print(f"FAIL {name}\n  {problem}")
    else:
      print(f"ok   {name}")
    return fn
  return wrap


@case("only plain https github.com repository URLs name an owner")
def _():
  good = {"https://github.com/alice/plug": ("alice", "plug"), "https://github.com/alice/plug.git": ("alice", "plug"),
          "https://github.com/Alice/my.plug/": ("Alice", "my.plug")}
  bad = ["http://github.com/alice/plug", "git@github.com:alice/plug.git", "ssh://git@github.com/alice/plug",
         "https://github.com.evil.example/alice/plug", "https://evil.example/github.com/alice/plug",
         "https://alice@github.com/alice/plug", "https://github.com:443/alice/plug",
         "https://github.com/alice/plug/tree/main", "https://github.com/alice/plug?x=1",
         "https://github.com/alice/..", "https://github.com/alice/.git", "https://github.com/-alice/plug",
         "https://github.com/alice/plug\n", "https://GITHUB.com/alice/plug", None, 7]
  wrong = {u: pg.github_repo(u) for u in good if pg.github_repo(u) != good[u]}
  wrong.update({repr(u): pg.github_repo(u) for u in bad if pg.github_repo(u) is not None})
  return f"misparsed: {wrong}" if wrong else None


# --------------------------------------------------------------------- setup

routes["/users/alice"] = (200, {"login": "alice", "id": 101})


@case("own add-owner stores the account's numeric id")
def _():
  guard("own", "add-owner", "alice")
  state = json.loads(guard("own", "--json").stdout)
  if state["owners"] != [{"login": "alice", "id": 101}]:
    return f"owners: {state['owners']}"
  if state["skipOwn"]:
    return "skipOwn turned on by add-owner"


@case("own add-path refuses the plugins folder and the home folder")
def _():
  for path in (plugins, plugins.parent, Path.home(), "/"):
    r = guard("own", "add-path", str(path), check=False)
    if r.returncode == 0:
      return f"accepted {path}"
  guard("own", "add-path", str(projects))


gh = make_plugin(plugins / "own.gh", "own.gh", remote="https://github.com/alice/plug")
head = git(gh, "rev-parse", "HEAD")
REPO = "/repos/alice/plug"
COMPARE = f"/repos/alice/plug/compare/{head}...main?per_page=1"


def github_says(owner_id=101, status="identical", base=None):
  routes[REPO] = (200, {"full_name": "alice/plug", "default_branch": "main", "owner": {"login": "alice", "id": owner_id}})
  routes[COMPARE] = (200, {"status": status, "merge_base_commit": {"sha": base or head}})


github_says()


@case("with own off, your plugins are scanned")
def _():
  reason = skipped("own.gh")
  return f"skipped ({reason})" if reason else None


guard("own", "on")

# --------------------------------------------------------------------- GitHub


@case("a clone of your repository at a commit on its default branch is skipped")
def _():
  clear_cache()
  reason = skipped("own.gh")
  return None if reason == "github" else f"reason: {reason}"


@case("a confirmation is cached, so GitHub is not asked again")
def _():
  asked.clear()
  reason = skipped("own.gh")
  return None if reason == "github" and not asked else f"reason {reason}, asked {asked}"


@case("--scan-all scans your own plugins too")
def _():
  reason = skipped("own.gh", "--scan-all")
  return f"skipped ({reason})" if reason else None


@case("a repository now owned by another account is scanned")
def _():
  clear_cache()
  github_says(owner_id=202)
  reason = skipped("own.gh")
  return f"skipped ({reason})" if reason else None


@case("a commit outside the default branch's history is scanned")
def _():
  for status, base in (("diverged", "0" * 40), ("behind", None), ("ahead", "1" * 40)):
    clear_cache()
    github_says(status=status, base=base)
    reason = skipped("own.gh")
    if reason:
      return f"{status} skipped ({reason})"


@case("a GitHub error or a reply it can't read means a scan")
def _():
  for reply in ((500, {}), (403, {"message": "rate limited"}), (200, ["not", "an", "object"]),
                (200, {"full_name": "alice/plug", "owner": {"id": 101}})):
    clear_cache()
    github_says()
    routes[REPO] = reply
    reason = skipped("own.gh")
    if reason:
      return f"{reply} skipped ({reason})"
  github_says()


@case("a clone with local changes is scanned")
def _():
  clear_cache()
  (gh / "extra.qml").write_text("// added\n")
  try:
    reason = skipped("own.gh")
  finally:
    (gh / "extra.qml").unlink()
  return f"skipped ({reason})" if reason else None


@case("only settings files the commit's own .gitignore excludes are allowed")
def _():
  global head, COMPARE
  clear_cache()
  (gh / "config.json").write_text("{}\n")
  try:
    if skipped("own.gh"):
      return "skipped with a config.json the commit does not ignore"
    (gh / ".git" / "info" / "exclude").write_text("config.json\n")
    if skipped("own.gh"):
      return "skipped with a config.json only the clone's info/exclude ignores"
    (gh / ".git" / "info" / "exclude").write_text("")
    (gh / ".gitignore").write_text("*.json\n")
    git(gh, "add", ".gitignore")
    git(gh, "commit", "-q", "-m", "ignore settings")
    head = git(gh, "rev-parse", "HEAD")
    COMPARE = f"/repos/alice/plug/compare/{head}...main?per_page=1"
    github_says()
    if skipped("own.gh") != "github":
      return "a config.json the commit ignores made it scanned"
    (gh / "sub").mkdir()
    cases = (("helper.qml", 0o644), ("notes.json", 0o755), ("sub/manifest.json", 0o644))
    for name, mode in cases:
      (gh / name).write_text("{}\n")
      os.chmod(gh / name, mode)
      try:
        if skipped("own.gh"):
          return f"skipped with an extra {name} ({oct(mode)})"
      finally:
        (gh / name).unlink()
    (gh / "sub").rmdir()
  finally:
    (gh / "config.json").unlink()


def with_link(name, target, also=()):
  """Commit a symlink (and any further ones), check, then undo the commit."""
  global head, COMPARE
  for n, t in ((name, target), *also):
    (gh / n).symlink_to(t)
    git(gh, "add", n)
  git(gh, "commit", "-q", "-m", "link")
  old_head, old_compare = head, COMPARE
  head = git(gh, "rev-parse", "HEAD")
  COMPARE = f"/repos/alice/plug/compare/{head}...main?per_page=1"
  github_says()
  clear_cache()
  try:
    return skipped("own.gh")
  finally:
    git(gh, "reset", "-q", "--hard", "HEAD~1")
    head, COMPARE = old_head, old_compare
    github_says()


@case("a committed symlink chain to a committed file is fine")
def _():
  reason = with_link("alias.qml", "again.qml", also=(("again.qml", "./BarWidget.qml"),))
  return None if reason == "github" else f"reason: {reason}"


@case("a committed symlink that passes through .git is scanned")
def _():
  reason = with_link("sneaky.qml", ".git/../BarWidget.qml")
  return f"skipped ({reason})" if reason else None


@case("a committed symlink to a folder is scanned")
def _():
  reason = with_link("dir-link", ".")
  return f"skipped ({reason})" if reason else None


@case("a tracked symlink that leads to an untracked settings file is scanned")
def _():
  global head, COMPARE
  (gh / "loaded.qml").symlink_to("settings.json")
  git(gh, "add", "loaded.qml")
  git(gh, "commit", "-q", "-m", "link to settings")
  old_head, old_compare = head, COMPARE
  head = git(gh, "rev-parse", "HEAD")
  COMPARE = f"/repos/alice/plug/compare/{head}...main?per_page=1"
  github_says()
  clear_cache()
  (gh / "settings.json").write_text("{}\n")
  try:
    reason = skipped("own.gh")
  finally:
    (gh / "settings.json").unlink()
    git(gh, "reset", "-q", "--hard", "HEAD~1")
    head, COMPARE = old_head, old_compare
    github_says()
  return f"skipped ({reason})" if reason else None


@case("a tracked symlink that leads outside the checkout is scanned")
def _():
  global head, COMPARE
  outside = work / "outside.qml"
  outside.write_text("// not in the commit\n")
  (gh / "linked.qml").symlink_to(outside)
  git(gh, "add", "linked.qml")
  git(gh, "commit", "-q", "-m", "link out")
  old_head, old_compare = head, COMPARE
  head = git(gh, "rev-parse", "HEAD")
  COMPARE = f"/repos/alice/plug/compare/{head}...main?per_page=1"
  github_says()
  clear_cache()
  try:
    reason = skipped("own.gh")
  finally:
    git(gh, "reset", "-q", "--hard", "HEAD~1")
    head, COMPARE = old_head, old_compare
    github_says()
  return f"skipped ({reason})" if reason else None


@case("a change hidden from git status with skip-worktree is scanned")
def _():
  clear_cache()
  original = (gh / "BarWidget.qml").read_bytes()
  (gh / "BarWidget.qml").write_bytes(original + b"// changed\n")
  git(gh, "update-index", "--skip-worktree", "BarWidget.qml")
  try:
    if git(gh, "status", "--porcelain"):
      return "git status saw the change; the case tests nothing"
    reason = skipped("own.gh")
  finally:
    git(gh, "update-index", "--no-skip-worktree", "BarWidget.qml")
    (gh / "BarWidget.qml").write_bytes(original)
  return f"skipped ({reason})" if reason else None


@case("a forged object in the clone's own store is caught")
def _():
  # Rewrite the commit's tree object file to hold another tree, under the
  # old name. Plugin Guard hashes every object it reads, whatever git does.
  import zlib
  tree = git(gh, "rev-parse", "HEAD^{tree}")
  (gh / "evil.qml").write_text("// not in the commit\n")
  git(gh, "add", "evil.qml")
  forged_tree = git(gh, "write-tree")
  git(gh, "reset", "-q", "evil.qml")
  objects = gh / ".git" / "objects"
  forged = zlib.decompress((objects / forged_tree[:2] / forged_tree[2:]).read_bytes())
  target = objects / tree[:2] / tree[2:]
  saved = target.read_bytes()
  os.chmod(target, 0o644)
  target.write_bytes(zlib.compress(forged))
  clear_cache()
  try:
    # Recent git also refuses it; either way the plugin must be scanned.
    reason = skipped("own.gh")
  finally:
    target.write_bytes(saved)
    (gh / "evil.qml").unlink()
  return f"skipped ({reason})" if reason else None


@case("an object whose content does not hash to its name is refused")
def _():
  sha = "a" * 40
  body = b"tree 1234567890abcdef\n"
  fake = type("R", (), {"returncode": 0, "stdout": b"%s commit %d\n%s\n" % (sha.encode(), len(body), body)})
  real = pg.run_bounded
  pg.run_bounded = lambda *a, **k: fake
  try:
    pg.git_objects(work, [sha], 1 << 20, time.monotonic() + 30)
  except pg.GuardError as e:
    return None if "does not match" in str(e) else f"refused for another reason: {e}"
  finally:
    pg.run_bounded = real
  return "accepted"


@case("a clone of a repository under an account you didn't add is scanned, without asking GitHub")
def _():
  make_plugin(plugins / "other.gh", "other.gh", remote="https://github.com/bob/plug")
  asked.clear()
  reason = skipped("other.gh")
  return f"skipped ({reason})" if reason else (f"asked GitHub: {asked}" if asked else None)


@case("an ssh remote on your account is scanned (ssh config can remap the host)")
def _():
  make_plugin(plugins / "ssh.gh", "ssh.gh", remote="git@github.com:alice/plug.git")
  reason = skipped("ssh.gh")
  return f"skipped ({reason})" if reason else None

# --------------------------------------------------------------------- local


@case("a plugin symlinked from a trusted folder is skipped")
def _():
  make_plugin(projects / "local", "own.local")
  (plugins / "own.local").symlink_to(projects / "local")
  reason = skipped("own.local")
  return None if reason == "path" else f"reason: {reason}"


@case("a plugin symlinked from a trusted folder with a remote GitHub says you own is skipped")
def _():
  routes["/repos/alice/pushed"] = (200, {"full_name": "alice/pushed", "default_branch": "main",
                                         "owner": {"login": "alice", "id": 101}})
  make_plugin(projects / "pushed", "own.pushed", remote="https://github.com/alice/pushed")
  (plugins / "own.pushed").symlink_to(projects / "pushed")
  reason = skipped("own.pushed")
  return None if reason == "path" else f"reason: {reason}"


@case("a symlinked checkout whose remote now belongs to someone else is scanned")
def _():
  routes["/repos/alice/gone"] = (200, {"full_name": "carol/gone", "default_branch": "main",
                                       "owner": {"login": "carol", "id": 303}})
  make_plugin(projects / "gone", "own.gone", remote="https://github.com/alice/gone")
  (plugins / "own.gone").symlink_to(projects / "gone")
  reason = skipped("own.gone")
  return f"skipped ({reason})" if reason else None


@case("a plugin in a trusted folder that is itself inside someone else's clone is scanned")
def _():
  suite = elsewhere / "their-mono"
  (suite / "plugins").mkdir(parents=True)
  git(suite, "init", "-q")
  git(suite, "remote", "add", "origin", "https://github.com/bob/mono")
  make_plugin(suite / "plugins" / "one", "their.mono")
  guard("own", "add-path", str(suite / "plugins"))
  (plugins / "their.mono").symlink_to(suite / "plugins" / "one")
  try:
    reason = skipped("their.mono")
  finally:
    guard("own", "remove-path", str(suite / "plugins"))
  return f"skipped ({reason})" if reason else None


@case("a remote URL with a space is read whole, not as a GitHub URL")
def _():
  for n, url in enumerate(("https://github.com/alice/pushed /tmp/elsewhere", " https://github.com/alice/pushed")):
    make_plugin(projects / f"spacey{n}", f"own.spacey{n}", remote=url)
    (plugins / f"own.spacey{n}").symlink_to(projects / f"spacey{n}")
    reason = skipped(f"own.spacey{n}")
    if reason:
      return f"{url!r} skipped ({reason})"


@case("a plugin in a subfolder of someone else's clone is scanned")
def _():
  make_plugin(projects / "theirs-suite" / "plugin", "their.sub")
  git(projects / "theirs-suite", "init", "-q")
  git(projects / "theirs-suite", "remote", "add", "origin", "https://github.com/bob/suite")
  (plugins / "their.sub").symlink_to(projects / "theirs-suite" / "plugin")
  reason = skipped("their.sub")
  return f"skipped ({reason})" if reason else None


@case("someone else's clone symlinked from a trusted folder is scanned")
def _():
  make_plugin(projects / "theirs", "their.clone", remote="https://github.com/bob/theirs")
  (plugins / "their.clone").symlink_to(projects / "theirs")
  reason = skipped("their.clone")
  return f"skipped ({reason})" if reason else None


@case("a plugin symlinked from an untrusted folder is scanned")
def _():
  make_plugin(elsewhere / "away", "away.local")
  (plugins / "away.local").symlink_to(elsewhere / "away")
  reason = skipped("away.local")
  return f"skipped ({reason})" if reason else None


@case("a symlink to the trusted folder itself is scanned")
def _():
  shutil.copy(FIXTURE / "manifest.json", projects / "manifest.json")
  try:
    (plugins / "clean-clock-root").symlink_to(projects)
    reason = skipped("clean-clock-root")
  finally:
    (projects / "manifest.json").unlink()
    (plugins / "clean-clock-root").unlink()
  return f"skipped ({reason})" if reason else None


@case("a copied folder is scanned unless its id is listed")
def _():
  make_plugin(plugins / "copied.local", "copied.local")
  if skipped("copied.local"):
    return "skipped before it was listed"
  guard("own", "add-plugin", "copied.local")
  guard("own", "add-plugin", "copied.local")  # listing it again keeps its mark
  reason = skipped("copied.local")
  return None if reason == "listed" else f"listed: reason {reason}"


@case("own add-plugin refuses a git checkout with remotes")
def _():
  make_plugin(plugins / "listed.clone", "listed.clone", remote="https://github.com/bob/listed")
  r = guard("own", "add-plugin", "listed.clone", check=False)
  return "accepted" if r.returncode == 0 else None


@case("a listed plugin that later gains a remote is scanned")
def _():
  make_plugin(plugins / "listed.later", "listed.later")
  guard("own", "add-plugin", "listed.later")
  git(plugins / "listed.later", "init", "-q")
  git(plugins / "listed.later", "remote", "add", "origin", "https://github.com/bob/later")
  reason = skipped("listed.later")
  return f"skipped ({reason})" if reason else None


@case("own add-plugin refuses a symlink")
def _():
  r = guard("own", "add-plugin", "away.local", check=False)
  return "accepted" if r.returncode == 0 else None


@case("a folder that replaces a listed plugin is scanned")
def _():
  shutil.rmtree(plugins / "copied.local")
  make_plugin(plugins / "copied.local", "copied.local")
  reason = skipped("copied.local")
  return f"skipped ({reason})" if reason else None


@case("a trusted folder that is replaced by a symlink is no longer trusted")
def _():
  real = work / "projects-moved"
  projects.rename(real)
  projects.symlink_to(real)
  try:
    reason = skipped("own.local")
  finally:
    projects.unlink()
    real.rename(projects)
  if reason:
    return f"skipped ({reason})"
  return None if skipped("own.local") == "path" else "not skipped once restored"


@case("a recorded skip is checked again when the setting is off, the skip is old, or its trust is removed")
def _():
  basis = {"reason": "github", "account": "alice", "accountIds": [101]}
  fresh = {"skip": "own", "scannedAt": pg.now_iso(), "ownPlugin": basis}
  old = dict(fresh, scannedAt="2000-01-01T00:00:00+00:00")
  on = {"skipOwn": True, "trustedOwners": [{"login": "alice", "id": 101}]}
  wrong = [name for name, got, want in (
    ("fresh, on", pg.stale_own(fresh, on), False),
    ("fresh, off", pg.stale_own(fresh, dict(on, skipOwn=False)), True),
    ("old, on", pg.stale_own(old, on), True),
    ("owner removed", pg.stale_own(fresh, dict(on, trustedOwners=[])), True),
    ("same login, another id", pg.stale_own(fresh, dict(on, trustedOwners=[{"login": "alice", "id": 999}])), True),
    ("confirmation old", pg.stale_own(dict(fresh, ownPlugin=dict(basis, confirmedAt="2000-01-01T00:00:00+00:00")),
                                      on), True),
    ("path, its remote's owner removed", pg.stale_own(
      dict(fresh, ownPlugin={"reason": "path", "path": "/p/x", "accountIds": [101]}),
      dict(on, trustedPaths=["/p"], trustedOwners=[])), True),
    ("path removed", pg.stale_own(dict(fresh, ownPlugin={"reason": "path", "path": "/p/x"}),
                                  dict(on, trustedPaths=["/q"])), True),
    ("path kept", pg.stale_own(dict(fresh, ownPlugin={"reason": "path", "path": "/p/x"}),
                               dict(on, trustedPaths=["/p"])), False),
    ("scanned, off", pg.stale_own({"scannedAt": pg.now_iso()}, {"skipOwn": False}), False),
  ) if got != want]
  return f"wrong: {wrong}" if wrong else None


@case("own off scans every plugin again")
def _():
  guard("own", "off")
  reasons = {pid: skipped(pid) for pid in ("own.gh", "own.local", "copied.local")}
  guard("own", "on")
  hits = {k: v for k, v in reasons.items() if v}
  return f"still skipped: {hits}" if hits else None


@case("the report says the plugin is yours and was not scanned")
def _():
  r = guard("check", "own.local", "--no-model")
  return None if "your own plugin; not scanned" in r.stderr else f"output: {r.stderr[-400:]}"


server.shutdown()
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if failed else 0)
