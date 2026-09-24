# ospf-recovery-16

当前阶段只完成 16 节点 Docker 拓扑，不包含 OSPF、动态 Cost 或故障实验。

## 镜像说明

本项目默认只使用本地镜像，不会自动拉取。`docker-compose.yml` 中的 `pull_policy: never` 会禁止 Compose 联网拉取；`up.sh` 会先检查 `.env` 中的镜像标签。

如果当前 VM 没有镜像，可以明确允许本次拉取：

```bash
PULL_IMAGES=1 ./scripts/up.sh
```

先查看本机镜像：

```bash
docker images
```

如果本地 FRR 镜像不是 `quay.io/frrouting/frr:10.4.1`，把 `.env` 改成实际的 `REPOSITORY:TAG`，例如：

```env
FRR_IMAGE=frrouting/frr:10.4.1
HOST_IMAGE=nicolaka/netshoot:latest
```

镜像名和标签必须完全一致；`frrouting/frr:10.4.1` 与 `quay.io/frrouting/frr:10.4.1` 会被 Docker 视为两个不同镜像名。

## 首次运行

```bash
cp .env.example .env
chmod +x scripts/*.sh
./scripts/up.sh
./scripts/status.sh
```

如果 `.env` 已经存在，请执行下面命令更新 FRR 标签；`cp .env.example .env` 只会在 `.env` 不存在时执行，不会覆盖旧配置：

```bash
sed -i 's#^FRR_IMAGE=.*#FRR_IMAGE=quay.io/frrouting/frr:10.4.1#' .env
```

`up.sh` 会先校验拓扑，再启动 12 个 FRR 路由器和 4 个业务主机。当前拓扑使用 Docker bridge 网络：19 条路由器点到点链路、4 个业务 LAN 和 1 个管理网。

如果某些容器长时间停在 `Starting`，先按 `Ctrl+C` 停止当前命令，然后诊断：

```bash
docker compose ps -a
docker inspect $(docker compose ps -q R5) --format '{{.State.Status}} {{.State.Error}}'
docker compose logs --tail=100 R5
docker info
```

确认诊断后清理并重新启动：

```bash
./scripts/reset.sh
./scripts/up.sh
```

本项目不再覆盖 FRR 10.4.1 镜像自带的启动入口；如果仍有单个路由器卡住，优先查看该路由器的 `docker compose logs`，不要连续重复执行 `up.sh`。

## 停止和清理

```bash
./scripts/down.sh
```

`down.sh` 默认删除容器和网络，不删除配置文件。

如果要从干净状态重新开始：

```bash
./scripts/reset.sh
```

这会删除本项目的容器、Compose 网络、`frr/generated/` 和运行时状态，但保留历史结果。连结果和日志也删除时：

```bash
PURGE_RESULTS=1 ./scripts/reset.sh
```

## 节点清单

- 路由器：R1-R12
- 业务主机：H1-H4
- 业务入口：R1/H1、R2/H2、R11/H3、R12/H4

## 地址和 OSPF 阶段

foundation 启动成功后，在 VM1 执行：

```bash
./scripts/run.sh addresses
./scripts/run.sh configs
./scripts/run.sh ospf
./scripts/run.sh check
```

## 16 节点 E1 稳定 OSPF 基线

基础检查通过后，执行一次稳定拓扑基线采集：

```bash
./scripts/run.sh e1
```

E1 不注入链路损伤、链路断开或节点故障，只记录当前标准 OSPF 的基线数据。结果保存在带时间戳的目录：

```text
results/e1/YYYYMMDD-HHMMSS/
```

其中包括：

- `compose-ps.txt`：容器状态；
- `interfaces/`：R1-R12、H1-H4 的 IPv4 接口快照；
- `neighbors/`：R1-R12 的 OSPF 邻居表；
- `routes/`：R1-R12 的 OSPF 路由表；
- `H1-H3-ping-100.txt`：H1 到 H3 的 100 包 Ping；
- `H2-H4-ping-100.txt`：H2 到 H4 的 100 包 Ping；
- `summary.txt`：本次采集说明。

查看最近一次结果：

```bash
ls -td results/e1/* | head -n 1
```

E1 完成后再进入 E2。不要在 E1 期间执行 `tc qdisc`、停止容器或修改 OSPF cost。

## 16 节点 E2 链路恶化基线

E1 完成后，先测固定 cost OSPF 在链路恶化下的表现：

```bash
./scripts/run.sh e2
```

脚本默认在 H2-H4 业务路径上的 R2-R4 链路两端注入 `50ms` 延迟、`10ms` 抖动和 `10%` 丢包，持续 60 秒；实验结束会自动删除 `tc netem` 损伤。结果保存在：

```text
results/e2/fixed-cost-YYYYMMDD-HHMMSS/
```

可通过环境变量调整参数，例如：

```bash
E2_DURATION=60 E2_DELAY=80ms E2_JITTER=20ms E2_LOSS=15% ./scripts/run.sh e2
```

E2 固定 cost 基线只用于记录受损链路下的标准 OSPF 表现，不启动动态 cost 控制器。结果目录包含 `events.csv`、`parameters.txt`、`H2-H4-ping.txt`、路由快照和 qdisc 统计。完成这一组后，再运行动态 cost 版本，使用相同的损伤参数进行对比。

执行顺序不能跳过 `configure_addresses.sh`：Compose 已为每个链路端点配置固定规划 IP，地址脚本通过容器内 `ip -o -4 addr show` 按本端规划 IP 反查实际接口，然后设置 Loopback、链路和业务 LAN 地址。接口名不保证是 `eth1`、`eth2`，不要手工假定接口编号。发现阶段会显示 `version=local-ip-v3`，并在临时文件中解析命令输出，避免长拓扑下 Bash 命令替换卡住。

如果要重新开始地址/OSPF 阶段：

```bash
./scripts/reset.sh
./scripts/up.sh
./scripts/configure_addresses.sh
./scripts/apply_ospf.sh
```
