# -*- coding: utf-8 -*-
"""分析 ospf-recovery-16 results 目录的核心实验指标"""
import re, os, glob

BASE = r'E:\实习项目\基于OSPF的链路质量感知与快速故障恢复机制研究\ospf-recovery-16(1)\results'

def parse_ping(path):
    ts, seq = [], []
    pat = re.compile(r'\[([0-9.]+)\].*icmp_seq=(\d+)')
    for line in open(path, encoding='utf-8', errors='ignore'):
        m = pat.search(line)
        if m:
            ts.append(float(m.group(1))); seq.append(int(m.group(2)))
    return ts, seq

def parse_route_watch(path):
    rows = []
    pat = re.compile(r'via (\S+)')
    for line in open(path, encoding='utf-8', errors='ignore'):
        line = line.strip()
        if not line or line.startswith('timestamp') or line.startswith('ts,'):
            continue
        parts = line.split(',', 1)
        if len(parts) < 2:
            continue
        try:
            t = float(parts[0])
        except ValueError:
            continue
        m = pat.search(parts[1])
        nh = m.group(1) if m else 'NONE'
        rows.append((t, nh))
    return rows

def parse_events(path):
    ev = []
    for line in open(path, encoding='utf-8', errors='ignore'):
        line = line.strip()
        if not line or line.startswith('timestamp'):
            continue
        p = line.split(',', 2)
        if len(p) >= 2:
            try:
                ev.append((float(p[0]), p[1], p[2] if len(p) > 2 else ''))
            except ValueError:
                pass
    return ev

def parse_watch_csv(path):
    """E4 的 watch.csv: timestamp,nh_to_H3_at_R3,nh_to_H4_at_R2,r5_adj_at_R3"""
    rows = []
    for line in open(path, encoding='utf-8', errors='ignore'):
        line = line.strip()
        if not line or line.startswith('timestamp'):
            continue
        p = line.split(',')
        if len(p) < 4:
            continue
        try:
            t = float(p[0])
        except ValueError:
            continue
        rows.append((t, p[1], p[2], p[3]))
    return rows

def ping_outage(ts_list, gap_thresh=0.6):
    if not ts_list:
        return []
    ts_list = sorted(ts_list)
    outages = []
    start = None
    prev = ts_list[0]
    for t in ts_list[1:]:
        if t - prev > gap_thresh:
            if start is None:
                start = prev
            outages.append((start, t))
            start = None
        prev = t
    return outages

def find_switches(rows):
    """找下一跳变化点, 返回 [(time, nh)]"""
    changes = []
    prev = None
    for t, nh in rows:
        if nh != prev:
            changes.append((t, nh))
            prev = nh
    return changes

print('=' * 78)
print('E3: 单链路硬故障 (R3-R5 双向 loss100%, 60s故障/80s恢复)')
print('=' * 78)
for d in sorted(glob.glob(os.path.join(BASE, 'e3', 's*'))):
    scheme = os.path.basename(d).split('-')[0]
    ev = parse_events(os.path.join(d, 'events.csv'))
    evd = {e[1]: e[0] for e in ev}
    rw = parse_route_watch(os.path.join(d, 'route_watch.csv'))
    pf = os.path.join(d, 'H1-H3-ping.txt')
    print(f'--- {scheme} ({os.path.basename(d)}) ---')
    if evd:
        print(f'  fault_on={evd.get("fault_on",0)/1000:.2f}s  fault_off={evd.get("fault_off",0)/1000:.2f}s')
    if rw:
        sw = find_switches(rw)
        fon = evd.get('fault_on', 0)
        for t, nh in sw:
            rel = (t - fon) / 1000 if fon else 0
            print(f'  route switch @{t/1000:.2f}s (rel fault_on {rel:+.2f}s) -> nh={nh}')
    if os.path.exists(pf):
        ts, seq = parse_ping(pf)
        outages = ping_outage(ts)
        tot = sum(b - a for a, b in outages)
        print(f'  ping: {len(ts)} replies, outage={[(round(a,2),round(b,2),round(b-a,2)) for a,b in outages]} total={tot:.2f}s')

print()
print('=' * 78)
print('E4: 节点整机故障 (docker stop R5 20s)')
print('=' * 78)
for d in sorted(glob.glob(os.path.join(BASE, 'e4', 's*'))):
    scheme = os.path.basename(d).split('-')[0]
    ev = parse_events(os.path.join(d, 'events.csv'))
    evd = {e[1]: e[0] for e in ev}
    print(f'--- {scheme} ({os.path.basename(d)}) ---')
    if evd:
        print(f'  node_stop={evd.get("node_stop",0)/1000:.2f}s node_start={evd.get("node_start",0)/1000:.2f}s')
    # watch.csv: 受损流(H1->H3 @R3) 对照流(H2->H4 @R2)
    wf = os.path.join(d, 'watch.csv')
    if os.path.exists(wf):
        rows = parse_watch_csv(wf)
        # 找受损流下一跳变化
        swA = find_switches([(t, a) for t, a, b, s in rows])
        fon = evd.get('node_stop', 0)
        for t, nh in swA:
            rel = (t - fon) / 1000 if fon else 0
            print(f'  [damaged A] R3->H3 nh switch @{t/1000:.2f}s (rel {rel:+.2f}s) -> {nh}')
        swB = find_switches([(t, b) for t, a, b, s in rows])
        for t, nh in swB:
            rel = (t - fon) / 1000 if fon else 0
            print(f'  [control B] R2->H4 nh switch @{t/1000:.2f}s (rel {rel:+.2f}s) -> {nh}')
        # R5 邻居状态变化
        states = [(t, s) for t, a, b, s in rows]
        prev = None
        for t, s in states:
            if s != prev:
                rel = (t - fon) / 1000 if fon else 0
                print(f'  [adj] R5 neighbor -> {s} @{t/1000:.2f}s (rel {rel:+.2f}s)')
                prev = s
    pf = os.path.join(d, 'H1-H3-ping.txt')
    if os.path.exists(pf):
        ts, seq = parse_ping(pf)
        outages = ping_outage(ts)
        tot = sum(b - a for a, b in outages)
        print(f'  [damaged H1->H3] ping {len(ts)} replies, outage total={tot:.2f}s')
    pf2 = os.path.join(d, 'H2-H4-ping.txt')
    if os.path.exists(pf2):
        ts, seq = parse_ping(pf2)
        outages = ping_outage(ts)
        tot = sum(b - a for a, b in outages)
        print(f'  [control H2->H4] ping {len(ts)} replies, outage total={tot:.2f}s')

print()
print('=' * 78)
print('E5: 随机扰动 (normal20/churn60/tail20)')
print('=' * 78)
for d in sorted(glob.glob(os.path.join(BASE, 'e5', 's*'))):
    scheme = os.path.basename(d).split('-')[0]
    ev = parse_events(os.path.join(d, 'events.csv'))
    print(f'--- {scheme} ({os.path.basename(d)}) ---')
    # 扰动事件明细
    for t, name, det in ev:
        if name == 'disturb':
            print(f'  disturb @{t/1000:.2f}s: {det}')
    # 路由切换
    rw = parse_route_watch(os.path.join(d, 'route_watch.csv'))
    if rw:
        sw = find_switches(rw)
        if len(sw) > 1:
            for t, nh in sw:
                print(f'  route switch @{t/1000:.2f}s -> {nh}')
        else:
            print(f'  路由无切换 (始终 {sw[0][1] if sw else "NONE"})')
    pf = os.path.join(d, 'H1-H3-ping.txt')
    if os.path.exists(pf):
        ts, seq = parse_ping(pf)
        outages = ping_outage(ts)
        tot = sum(b - a for a, b in outages)
        print(f'  ping {len(ts)} replies, outage total={tot:.2f}s')
