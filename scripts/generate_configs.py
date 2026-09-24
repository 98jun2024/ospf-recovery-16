#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
links_text = (ROOT / 'configs' / 'links.yaml').read_text(encoding='utf-8')
rows = []
for line in links_text.splitlines():
    m = re.search(r'name:\s*(\S+),\s*subnet:\s*(\S+),\s*a:\s*(R\d+),\s*ip_a:\s*(\S+),\s*b:\s*(R\d+),\s*ip_b:\s*(\S+),\s*cost:\s*(\d+)', line)
    if m:
        rows.append(dict(name=m[1], subnet=m[2], a=m[3], ip_a=m[4], b=m[5], ip_b=m[6], cost=m[7]))
if len(rows) != 19:
    raise SystemExit(f'expected 19 links, found {len(rows)}')
out = ROOT / 'frr' / 'generated'
out.mkdir(parents=True, exist_ok=True)
for n in range(1, 13):
    text = '\n'.join(['configure terminal', f'hostname R{n}', 'router ospf', f' router-id 10.255.0.{n}', ' network 10.16.0.0/16 area 0', ' network 172.16.0.0/16 area 0', ' passive-interface default', ' maximum-paths 1', ' exit', 'end']) + '\n'
    (out / f'r{n}.conf').write_text(text, encoding='utf-8')
print(f'generated {len(rows)} link records and 12 FRR configs')
