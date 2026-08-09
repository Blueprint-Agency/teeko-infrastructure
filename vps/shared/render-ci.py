#!/usr/bin/env python3
"""Render a stack's ci/ templates into a directory ready to rsync onto the host.

Every file under <stack>/ci/ is copied to <out>/ with @@VAR@@ markers replaced by
the environment variable VAR. The path under ci/ IS the destination path relative
to /root/stacks/<dir>/ -- ci/.env.n8n lands as .env.n8n, and
ci/credentials/sa-key.json lands as credentials/sa-key.json.

This replaces the `case $stack in` block that used to live in deploy-infra.yml,
where every stack's secret files were re-typed as printf strings and base64'd
through a quoted remote shell. That coupling is what kept stalwart out of CI:
onboarding a stack meant editing the workflow. Now it means adding a file next
to the compose that uses it.

Two names under ci/ are special and handled by the workflow, not here:
  env.ci        extra CI-owned lines merged into the stack's .env (the stack's
                own compose interpolates them, e.g. gsc's ${GSC_MCP_PATH_TOKEN})
  post-sync.sh  run on the host in the stack dir after the files land and before
                `docker compose up`, for the few stacks needing mkdir/chown/chmod

An unset or empty marker is FATAL. A blank secret is not a smaller failure than
a missing file -- it is a Dex with no admin password that starts happily and
serves 401s forever, or a Postgres that initialises a brand new empty database.
Fail on the runner, where the diff is still on screen.

Usage: render-ci.py <stack-dir> <out-dir>
Exits 0 having written nothing if the stack has no ci/ directory.
"""
import os
import pathlib
import re
import sys

MARKER = re.compile(r"@@([A-Z_][A-Z0-9_]*)@@")

stack_dir, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ci_dir = stack_dir / "ci"
if not ci_dir.is_dir():
    sys.exit(0)

missing = {}
for src in sorted(p for p in ci_dir.rglob("*") if p.is_file()):
    rel = src.relative_to(ci_dir)
    text = src.read_text(encoding="utf-8")

    def sub(m):
        val = os.environ.get(m.group(1), "")
        if not val:
            missing.setdefault(m.group(1), []).append(str(rel))
        return val

    rendered = MARKER.sub(sub, text)
    dest = out_dir / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(rendered, encoding="utf-8")
    print(f"    rendered {rel}")

if missing:
    for var, files in sorted(missing.items()):
        print(f"MISSING SECRET: {var} (used by {', '.join(files)})", file=sys.stderr)
    print(
        f"\nAdd these to the GitHub Environment for this host, or to org-level "
        f"variables/secrets. Refusing to deploy {stack_dir.name} with blanks.",
        file=sys.stderr,
    )
    sys.exit(1)
