#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(__file__).resolve().parents[1]
compose = (root / "docker-compose.yml").read_text(encoding="utf-8")
links = (root / "configs" / "links.yaml").read_text(encoding="utf-8")
routers = set(re.findall(r'^  R(\d+):', compose, re.M))
hosts = set(re.findall(r'^  H(\d+):', compose, re.M))
networks = set(re.findall(r'^  (r\d+-r\d+): \{ipam:', compose, re.M))
yaml_links = set(re.findall(r'name: (r\d+-r\d+)', links))
errors = []
if routers != {str(i) for i in range(1, 13)}: errors.append(f"routers={sorted(routers)}")
if hosts != {str(i) for i in range(1, 5)}: errors.append(f"hosts={sorted(hosts)}")
if len(networks) != 19: errors.append(f"compose link networks={len(networks)}")
if networks != yaml_links: errors.append("links.yaml and compose networks differ")
if errors:
    print("topology validation failed:", "; ".join(errors), file=sys.stderr); sys.exit(1)
print("topology validation passed: 12 routers, 4 hosts, 19 point-to-point links")
