#!/usr/bin/env python3
"""Expand a list of repo stack names into concrete deploy targets on a host.

Most hosts map a stack 1:1 onto /root/stacks/<stack> and inherit the host's
env_name. bpvps2 is the exception: one repo stack (`booking`) is deployed twice,
and each destination needs its OWN env_name -- writing the host's env_name into
both would make booking-staging resolve to booking-prod's containers, volume and
network.

Reads:
  argv[1..]  stack names to expand
  $FANOUT    JSON object from vps/hosts.json, or 'null'
             {"booking": [{"dir": "booking-staging", "env_name": "staging"}, ...]}
  $ENV_NAME  the host's default env_name

Prints one target per line: <dir>|<env_name>|<stack>
"""
import json
import os
import sys

fanout = json.loads(os.environ.get("FANOUT") or "null") or {}
default_env = os.environ.get("ENV_NAME", "")

for stack in sys.argv[1:]:
    for dest in fanout.get(stack, [{"dir": stack, "env_name": default_env}]):
        print(f"{dest['dir']}|{dest.get('env_name') or default_env}|{stack}")
