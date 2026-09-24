#!/usr/bin/env python3
"""
动态 Cost 控制器（S5 基础版 / S6 完整版）。
宿主机运行，并行采样关键链路质量：
  Q = 0.40*RTT_norm + 0.35*loss_norm + 0.25*queue_norm，EWMA(alpha=0.3) 平滑。

Cost 规则（以静态初始 Cost 为地板，健康链路保持 10/20/30，不被拉平）：
  线性区  linear = clamp(max(init_cost, 10 + 90*Q_ewma), init_cost, 100)
  S5：直接用 linear（变化≥5、冷却6s）。无主动备用策略。
  S6：风险分级状态机；normal/warning 用 linear，**danger 用 DANGER_PENALTY=200
      高惩罚强制主路径开销超过备用路径完成主动避险**，退出 danger 回落；
      进入风险态用瞬时Q（响应灵敏），退出用EWMA（滞回防抖）；
      状态切换立即更新，其余按变化≥5、冷却6s。

说明：本拓扑主路径总Cost=40、备用=180，单链路线性抬到100仍不足以反转，
故 S6 用 danger 高惩罚实现"危险即切备用"，S5 线性区不强制切换，作为
"能感知质量但无主动备用策略"的对照。
日志带毫秒时间戳，便于与场景 events.csv 对齐。
"""
import argparse
import os
import re
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)

# (router_a, ip_a, router_b, ip_b, link_key, init_cost)
KEY_LINKS = [
    ('R3', '10.16.6.2', 'R5', '10.16.6.3', 'r3_r5', 10),
    ('R4', '10.16.8.2', 'R7', '10.16.8.3', 'r4_r7', 30),
    ('R5', '10.16.10.2', 'R7', '10.16.10.3', 'r5_r7', 20),
    ('R3', '10.16.5.2', 'R4', '10.16.5.3', 'r3_r4', 20),
    ('R9', '10.16.16.2', 'R10', '10.16.16.3', 'r9_r10', 20),
]

RTT_CAP = 50.0
LOSS_CAP = 5.0
QUEUE_CAP = 50000.0

ALPHA = 0.3                 # EWMA 平滑系数（计划书固定 0.3）
WARN_ENTER = 0.45
WARN_EXIT = 0.35
DANGER_ENTER = 0.70
DANGER_EXIT = 0.55
CONFIRM_WINDOW = 3
COOLDOWN = 6.0
COST_DELTA = 5
SAMPLE_INTERVAL = 2.0       # 目标采样周期；计时覆盖采样本身，硬故障快速反应
WARMUP_SECS = 6.0
PING_COUNT = 20             # 每链路20包，0.05s间隔约1s发完，loss分辨率5%
PING_INTERVAL = '0.05'
DANGER_PENALTY = 200        # S6 danger 饠Cost
DANGER_HOLD = 10.0          # danger 最短验略        # S6 danger 高惩罚Cost，强制反转主备

running = True


def stop(signum, frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def log(msg):
    print(f'[{int(time.time() * 1000)}][controller] {msg}', flush=True)


def compose_cmd():
    if (ROOT / '.env').exists():
        return ['docker', 'compose', '--env-file', '.env', '-f', 'docker-compose.yml']
    return ['docker', 'compose', '-f', 'docker-compose.yml']


# docker compose exec 每次都要加载compose插件、解析yaml和env，单次数秒；
# 改为按 compose label 反查容器ID后直接 docker exec，快一个数量级
_CID = {}


def build_cid_map():
    try:
        r = subprocess.run(['docker', 'ps', '--format',
                            '{{.ID}}\t{{index .Labels "com.docker.compose.service"}}'],
                           capture_output=True, text=True, timeout=15)
        m = {}
        for ln in r.stdout.splitlines():
            parts = ln.split('\t')
            if len(parts) == 2 and parts[0].strip():
                m[parts[1].strip().upper()] = parts[0].strip()
        if m:
            _CID.clear()
            _CID.update(m)
    except Exception as e:
        log(f'build_cid_map error: {e}')


def cid_of(node):
    c = _CID.get(node)
    if not c:
        build_cid_map()
        c = _CID.get(node)
    return c


def compose_exec(node, *args, timeout=20):
    cid = cid_of(node)
    if cid:
        cmd = ['docker', 'exec', '-T', cid] + list(args)
    else:
        # 反查不到容器ID时回退 compose exec 保底
        cmd = compose_cmd() + ['exec', '-T', '--interactive=false', node] + list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = r.stdout + r.stderr
        # 容器被重建导致缓存ID失效：清缓存并用新ID重试一次
        if cid and r.returncode != 0 and ('No such container' in out or 'not running' in out):
            _CID.pop(node, None)
            cid2 = cid_of(node)
            if cid2:
                r = subprocess.run(['docker', 'exec', '-T', cid2] + list(args),
                                   capture_output=True, text=True, timeout=timeout)
                out = r.stdout + r.stderr
        return out
    except Exception as e:
        return f'__ERROR__ {e}'


def load_interfaces():
    env = {}
    p = ROOT / 'state' / 'interfaces.env'
    if not p.exists():
        log(f'missing {p}')
        sys.exit(1)
    for line in p.read_text(encoding='utf-8').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    return env


def ping_sample(router, target_ip):
    """返回 (rtt_ms, loss%, stats_found)。兼容 iputils/busybox 汇总行。"""
    out = compose_exec(router, 'ping', '-c', str(PING_COUNT), '-i', PING_INTERVAL,
                       '-W', '1', target_ip)
    loss_m = re.search(r'([\d.]+)%\s*packet loss', out)
    stats_found = loss_m is not None
    loss = float(loss_m.group(1)) if loss_m else 100.0
    rtt_m = re.search(r'=\s*[\d.]+/([\d.]+)/', out)
    rtt = float(rtt_m.group(1)) if rtt_m else None
    return rtt, loss, stats_found, out


def queue_sample(router, iface):
    out = compose_exec(router, 'tc', '-s', 'qdisc', 'show', 'dev', iface)
    m = re.search(r'backlog\s+(\d+)b', out)
    return float(m.group(1)) if m else 0.0


def inst_q(rtt, loss, queue):
    rtt_norm = min((rtt or RTT_CAP) / RTT_CAP, 1.0)
    loss_norm = min(loss / LOSS_CAP, 1.0)
    queue_norm = min(queue / QUEUE_CAP, 1.0)
    return 0.40 * rtt_norm + 0.35 * loss_norm + 0.25 * queue_norm


def update_cost(router, iface, cost):
    compose_exec(router, 'vtysh', '-c', 'conf t', '-c', f'interface {iface}',
                 '-c', f'ip ospf cost {cost}', '-c', 'end', '-c', 'write memory')


def probe_one(router, target_ip, iface):
    """同一容器内一次 exec 同时完成 ping 探测与 tc 队列读取，把每链路 exec 数从2降到1。"""
    out = compose_exec(router, 'sh', '-c',
                       f'ping -c {PING_COUNT} -i {PING_INTERVAL} -W 1 {target_ip}; echo __TC__; tc -s qdisc show dev {iface}')
    ping_part, _, tc_part = out.partition('__TC__')
    loss_m = re.search(r'([\d.]+)%\s*packet loss', ping_part)
    stats_found = loss_m is not None
    loss = float(loss_m.group(1)) if loss_m else 100.0
    rtt_m = re.search(r'=\s*[\d.]+/([\d.]+)/', ping_part)
    rtt = float(rtt_m.group(1)) if rtt_m else None
    qm = re.search(r'backlog\s+(\d+)b', tc_part)
    queue = float(qm.group(1)) if qm else 0.0
    return rtt, loss, stats_found, queue, out


def sample_one(link, ifaces):
    ra, ipa, rb, ipb, key, init_cost = link
    ia = ifaces.get(f'{ra}__{key}')
    ib = ifaces.get(f'{rb}__{key}')
    if not ia or not ib:
        return {'key': key, 'ok': False, 'reason': 'iface-missing'}
    rtt, loss, stats_found, queue, raw = probe_one(ra, ipb, ia)
    if not stats_found:
        return {'key': key, 'ok': False, 'reason': 'sample-fail', 'raw': raw}
    if rtt is None and loss <= 0.0:
        return {'key': key, 'ok': False, 'reason': 'parse-anomaly'}
    return {'key': key, 'ok': True, 'ra': ra, 'rb': rb, 'ia': ia, 'ib': ib,
            'init': init_cost, 'rtt': rtt, 'loss': loss, 'queue': queue,
            'q': inst_q(rtt, loss, queue)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', choices=['s5', 's6'], required=True)
    args = ap.parse_args()
    mode = args.mode

    ifaces = load_interfaces()
    build_cid_map()
    log(f'cid map size={len(_CID)} (probe via docker exec)')
    start = time.time()
    log(f'mode={mode} started, links={len(KEY_LINKS)} ping_count={PING_COUNT} '
        f'alpha={ALPHA} warmup={WARMUP_SECS}s danger_penalty={DANGER_PENALTY}')

    # 启动自检（在 R3 上 ping 直连对端 R5，验证容器内 ping 汇总行可被正则解析）
    probe = compose_exec('R3', 'ping', '-c', '2', '-i', PING_INTERVAL, '-W', '1', '10.16.6.3')
    summ = [ln.strip() for ln in probe.splitlines() if 'packet loss' in ln or '=' in ln]
    log('selftest: ' + ' | '.join(summ)[:200])

    q_ewma = {lk[4]: 0.0 for lk in KEY_LINKS}
    last_update = {lk[4]: 0.0 for lk in KEY_LINKS}
    last_cost = {lk[4]: lk[5] for lk in KEY_LINKS}
    state = {lk[4]: 'normal' for lk in KEY_LINKS}
    confirm = {lk[4]: 0 for lk in KEY_LINKS}
    danger_enter_at = {lk[4]: 0.0 for lk in KEY_LINKS}
    pool = ThreadPoolExecutor(max_workers=len(KEY_LINKS))

    while running:
        loop_start = time.time()
        in_warmup = (loop_start - start) < WARMUP_SECS
        # 并行采样全部关键链路
        samples = list(pool.map(lambda l: sample_one(l, ifaces), KEY_LINKS))
        now = time.time()

        for s in samples:
            key = s['key']
            if not s['ok']:
                log(f'{key} SAMPLE_SKIP reason={s.get("reason")} '
                    f'raw={str(s.get("raw",""))[:100]!r}')
                continue

            # EWMA 平滑
            q_ewma[key] = ALPHA * s['q'] + (1 - ALPHA) * q_ewma[key]
            qe = q_ewma[key]
            init = s['init']
            linear = int(round(max(init, min(100.0, 10.0 + 90.0 * qe))))

            qi = s['q']  # 瞬时Q：用于"进入"风险态，保证恶化响应灵敏；退出用EWMA滞回防抖
            # 硬故障（100%全丢）快速判定，只确认1轮；软恶化仍需 CONFIRM_WINDOW 轮防抖
            need = 1 if s['loss'] >= 100.0 else CONFIRM_WINDOW
            state_changed = False
            if mode == 's6':
                st = state[key]
                if st == 'normal':
                    if qi >= DANGER_ENTER and s['loss'] >= 100.0:
                        # 跨级直达danger仅限硬故障(全丢,need=1快速反应)；软劣化走下方warning逐级，防中度采样波动误冲danger
                        confirm[key] += 1
                        if confirm[key] >= need:
                            state[key] = 'danger'; confirm[key] = 0; state_changed = True
                            danger_enter_at[key] = now
                            log(f'{key} STATE normal -> danger (q={qi:.3f} qewma={qe:.3f})')
                    elif qi >= WARN_ENTER or (s['rtt'] is not None and s['rtt'] >= 0.6 * RTT_CAP):
                        confirm[key] += 1
                        if confirm[key] >= need:
                            state[key] = 'warning'; confirm[key] = 0; state_changed = True
                            log(f'{key} STATE normal -> warning (q={qi:.3f} qewma={qe:.3f} rtt={s["rtt"]})')
                    else:
                        confirm[key] = 0
                elif st == 'warning':
                    rtt_cap = (s['rtt'] is None) or (s['rtt'] >= 0.9 * RTT_CAP)
                    if qi >= DANGER_ENTER or rtt_cap:
                        # 延迟触顶(确定性≈50ms,每轮可测)或瞬时Q达线都累计danger，不被随机0丢包轮次清零
                        confirm[key] += 1
                        if confirm[key] >= need:
                            state[key] = 'danger'; confirm[key] = 0; state_changed = True
                            danger_enter_at[key] = now
                            log(f'{key} STATE warning -> danger (q={qi:.3f} qewma={qe:.3f} rtt={s["rtt"]})')
                    elif qe < WARN_EXIT and not rtt_cap:
                        confirm[key] += 1
                        if confirm[key] >= CONFIRM_WINDOW:
                            state[key] = 'normal'; confirm[key] = 0; state_changed = True
                            log(f'{key} STATE warning -> normal (qewma={qe:.3f})')
                    else:
                        confirm[key] = 0
                elif st == 'danger':
                    # 延迟是确定性信号：RTT仍接近CAP(或全丢)说明损伤还在，不许退出；并要求超过最短驻留，防被随机0丢包轮次骗退
                    rtt_high = (s['rtt'] is None) or (s['rtt'] >= 0.9 * RTT_CAP)
                    held = (now - danger_enter_at[key]) >= DANGER_HOLD
                    if qe < DANGER_EXIT and (not rtt_high) and held:
                        confirm[key] += 1
                        if confirm[key] >= CONFIRM_WINDOW:
                            state[key] = 'warning'; confirm[key] = 0; state_changed = True
                            log(f'{key} STATE danger -> warning (qewma={qe:.3f} rtt={s["rtt"]})')
                    else:
                        confirm[key] = 0

            # 目标Cost：S6 danger 高惩罚，其余线性（静态init为地板）
            if mode == 's6' and state[key] == 'danger':
                target = DANGER_PENALTY
            else:
                target = linear

            rtt_str = f'{s["rtt"]:.2f}ms' if s['rtt'] is not None else 'N/A'
            wtag = ' [warmup]' if in_warmup else ''
            log(f'{key} q={s["q"]:.3f} qewma={qe:.3f} rtt={rtt_str} loss={s["loss"]:.1f}% '
                f'queue={s["queue"]:.0f}B target={target} state={state[key]}{wtag}')

            if in_warmup:
                continue

            should = False
            if mode == 's6':
                if state_changed:
                    should = True   # 状态切换立即生效（含danger跳变与恢复回落）
                elif abs(target - last_cost[key]) >= COST_DELTA and now - last_update[key] >= COOLDOWN:
                    should = True
            else:
                if abs(target - last_cost[key]) >= COST_DELTA and now - last_update[key] >= COOLDOWN:
                    should = True

            if should:
                fu_a = pool.submit(update_cost, s['ra'], s['ia'], target)
                fu_b = pool.submit(update_cost, s['rb'], s['ib'], target)
                fu_a.result(); fu_b.result()
                last_cost[key] = target
                last_update[key] = now
                log(f'{key} COST UPDATED -> {target} (state={state[key]})')

        # 补足到目标周期：计时覆盖采样(pool.map)本身，否则实际周期=采样耗时+sleep被拉长
        elapsed = time.time() - loop_start
        time.sleep(max(0.0, SAMPLE_INTERVAL - elapsed))

    pool.shutdown(wait=False)
    log('stopped by signal')


if __name__ == '__main__':
    main()
