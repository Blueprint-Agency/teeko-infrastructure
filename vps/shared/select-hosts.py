#!/usr/bin/env python3
"""Map a list of changed paths to the hosts in vps/hosts.json that own them.

Used by .github/workflows/deploy-infra.yml to turn a push diff into the matrix
input. Lives in a file rather than inline in the workflow because YAML block
scalars cannot hold a column-0 Python body, and because it is worth testing.

Usage: select-hosts.py <file-of-changed-paths> [hosts.json]
Prints a compact JSON array of matching host objects ([] if none).
"""
import json
import sys

diff_file = sys.argv[1]
hosts_file = sys.argv[2] if len(sys.argv) > 2 else "vps/hosts.json"

hosts = json.load(open(hosts_file))
changed = {line.strip() for line in open(diff_file) if line.strip()}

# Trailing slash matters: without it "vps/bpvps1" would also match "vps/bpvps10".
selected = [h for h in hosts if any(c.startswith(h["dir"] + "/") for c in changed)]

print(json.dumps(selected, separators=(",", ":")))
