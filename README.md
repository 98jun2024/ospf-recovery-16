# ospf-recovery-16

基于 Docker 与 FRRouting 的 **16 节点 OSPF 链路质量感知与动态 Cost 选路**实验平台。平台用 12 台 FRR 路由器和 4 台业务主机复现三层 IP 承载网，通过一个常驻控制器主动探测链路质量（时延 / 丢包 / 队列），动态改写 OSPF 接口 Cost，驱动协议在链路**尚未断开、但质量劣化**时提前主动避险；并以快定时器、BFD 等快速检测方案作为硬故障对照。

本仓库已完成拓扑搭建、五种方案（S2–S6）部署、动态 Cost 控制器与 E1–E5 全部实验及离线分析脚本。

## 核心特性



* **容器化高保真仿真**：12 路由器 + 4 主机共 16 个容器，FRR 镜像运行真实 OSPF 协议栈；19 条路由器点到点链路（独立 /29 网络）+ 4 个业务 LAN + 1 个管理网。

* **链路质量感知闭环**：主动 ping 探测 RTT / 丢包、tc 读取队列积压，加权质量分 Q 经 EWMA 平滑后驱动风险状态机，自动修改 OSPF Cost。

* **与协议解耦的切换**：控制器只改 Cost，真正泛洪 LSA、重跑 SPF、更换下一跳的仍是 OSPF，机制可解释、可回退。

* **五方案 × 五场景对照**：默认 OSPF、快定时器、BFD、线性动态 Cost、状态机动态 Cost 五种机制，在基线 / 软劣化 / 硬断链 / 节点失效 / 随机波动五类场景下自动化对比。

* **一键复现**：`run.sh` 统一封装启动、编址、方案部署、实验执行、结果分析与清理。

## 背景与目标

实验将 5G 用户面进入 IP 承载网后的部分抽象建模：手机应用、空口、基站 / UPF 作为背景，Docker/FRR 网络模拟其后的三层承载网，研究 OSPF 选路、链路质量感知与故障恢复。

标准 OSPF 的 Cost 是静态值，**只看链路通断、不看质量**：链路没断时，即使时延升高、丢包加重、队列拥塞仍继续使用；而链路真断后又要等待 Dead 定时器（默认 40s）才感知。本项目针对这两类问题：



* 以**软劣化（链路不断、质量变差）的主动避险为核心**，由动态 Cost 方案 S5/S6 解决；

* 以**硬故障（链路 / 节点明确失效）的快速恢复为对照**，由快定时器 S3、BFD 方案 S4 解决；

* 统一的 "动态 Cost + BFD" 混合恢复机制（S7）列为未来工作，本版不实现。

## 技术栈与环境



| 类别       | 选型                                                            |
| -------- | ------------------------------------------------------------- |
| 容器 / 编排  | Docker、Docker Compose（v2）                                     |
| 路由协议     | FRRouting（FRR）`quay.io/frrouting/frr:10.4.1`                  |
| 业务主机     | `nicolaka/netshoot:latest`（ping / iperf3 / tcpdump）           |
| 故障注入     | Linux `tc netem`（时延 / 丢包）、`tc tbf`（限速造队列）、`docker stop`（节点失效） |
| 控制器 / 脚本 | Python 3、Bash、vtysh                                           |
| 运行平台     | 一台装有 Docker 的 Linux 主机 / 虚拟机（建议 ≥2 vCPU、≥4 GB 内存）             |

## 目录结构



```
ospf-recovery-16/

├── docker-compose.yml          # 16 容器与 19 链路网络、4 LAN、管理网定义

├── .env.example                # 镜像标签模板（复制为 .env）

├── analyze\_results.py          # 结果汇总辅助脚本

├── TOPOLOGY.md                 # 链路 / 网段速查表

├── configs/                    # 拓扑与业务流的声明式配置

│   ├── topology.yaml           #   整体拓扑（节点、链路、cost）

│   ├── nodes.yaml              #   节点定义

│   ├── links.yaml              #   路由器链路定义

│   ├── paths.yaml / services.yaml  # 业务流路径与服务定义

├── frr/

│   ├── daemons                 # FRR 守护进程开关

│   ├── templates/router.conf.template  # 路由器配置模板

│   └── generated/              # generate\_configs.py 生成的配置（运行时）

├── scripts/

│   ├── run.sh                  # ★ 统一命令入口

│   ├── common.sh               # 封装 docker compose 与公共变量

│   ├── up.sh / down.sh         # 启动 / 停止

│   ├── reset.sh / status.sh    # 重置 / 状态查看

│   ├── topology\_validate.py    # 拓扑校验

│   ├── discover\_interfaces.sh  # 发现容器实际接口名

│   ├── configure\_addresses.sh  # 配置 Loopback 与链路地址

│   ├── generate\_configs.py     # 由模板生成 FRR 配置

│   ├── apply\_ospf.sh           # 下发 OSPF（文件方式）

│   ├── apply\_scheme.sh         # ★ 部署 S2–S6 方案（含 OSPF 下发、控制器启停）

│   ├── dynamic\_cost\_controller.py  # ★ 动态 Cost 控制器（S5/S6）

│   ├── e1\_baseline.sh ... e5\_random\_disturbance.sh      # 五类场景单次执行

│   ├── run\_e1\_all.sh ... run\_e5\_all.sh                  # 各场景批量跑方案矩阵

│   ├── analyze\_e1.sh ... analyze\_e5.sh                  # 离线分析

│   ├── check\_ospf.sh / check\_connectivity.sh            # 邻居与连通性检查

├── state/                      # 运行时状态（接口映射、控制器 pid、日志）

└── results/                    # 实验结果 results/eN/\<scheme>-<时间戳>/
```

## 拓扑概览



* **节点**：路由器 R1–R12，业务主机 H1–H4；主机接入点为 R1/H1、R2/H2、R11/H3、R12/H4。

* **地址规划**：


  * 路由器点到点链路：`10.16.1.0/29` \~ `10.16.19.0/29`，`.1` 为 Docker 网关，两端路由器用 `.2` / `.3`；

  * Loopback：`10.255.0.1/32` \~ `10.255.0.12/32`，作为 OSPF Router-ID；

  * 业务 LAN：`172.16.1.0/24` \~ `172.16.4.0/24`，`.1` 为网关、`.2` 为接入路由器、`.10` 为主机；

  * 管理网：`192.168.100.0/24`，仅供脚本 / 控制器 / 日志采集，不参与 OSPF 与业务转发。

* **业务流与主备路径**（flows 只定源宿，实际路径由 OSPF 按 Cost 选择）：



| 业务流         | 主路径（端到端 Cost）                       | 候选备用路径（Cost）                                  |
| ----------- | ----------------------------------- | --------------------------------------------- |
| H1→H3（主分析流） | H1-R1-R3-R5-R9-R11-H3（40）           | H1-R1-R3-R4-R8-R10-R9-R11-H3（100，R3 分叉、R9 汇合） |
| H2→H4（对照流）  | H2-R2-R6-R8-R10-R12-H4（90，OSPF 最短路） | H2-R2-R4-R7-R10-R12-H4（120）                   |

完整链路 / 网段对照见 [TOPOLOGY.md](TOPOLOGY.md)。

## 五种方案（S2–S6）



| 方案 | 定义                 | 关键配置                                   | 用途           |
| -- | ------------------ | -------------------------------------- | ------------ |
| S2 | 默认参数 OSPF          | Cost 固定；Hello 10s / Dead 40s           | 标准动态路由基线     |
| S3 | 调优定时器 OSPF         | Cost 固定；Hello 1s / Dead 3s             | 较快检测对照       |
| S4 | OSPF + BFD         | BFD tx/rx 50ms × 3（约 150ms 检测）         | 断链 / 节点快速检测  |
| S5 | OSPF + 线性动态 Cost   | `Cost=clamp(10+90·qewma,10,100)`，不强制切换 | 验证 "感知 — 反映" |
| S6 | 动态 Cost + 状态机 + 滞回 | 风险分级、EWMA、确认窗口，danger 时 Cost 打到 200    | 完整提议方案       |

所有互联链路均配置 `ip ospf network point-to-point`（避免 DR/BDR 语义），业务 LAN 用 passive-interface，`maximum-paths 1` 关闭 ECMP；初始 Cost 按主路径 10、备用 / 普通冗余 20、长绕行 30 设置，保证切换就近发生在 R3。

## 实验原理速览

**控制闭环（每 2s 一轮）**：链路探测 → Q 计算 → EWMA 平滑 → 风险状态判断 → 修改 OSPF Cost → OSPF 路由切换 → 业务指标反馈。



1. **探测**：进入受控链路一端容器，发 20 个、间隔 0.05s 的短 ping（约 1s 发完）得到 RTT 与丢包，同时 `tc -s qdisc` 读队列积压。

2. **质量分 Q**：三类指标按上限归一（RTT 50ms、丢包 5%、队列 50KB，队列分量 = min (backlog/50KB,1)），加权合成

   `Q = 0.40·RTT归一 + 0.35·丢包归一 + 0.25·队列归一`，Q 越接近 1 越差。

3. **EWMA 平滑**：`qewma = 0.3·本轮Q + 0.7·历史qewma`（α=0.3），抑制瞬时尖峰。

4. **状态机（S6）**：normal /warning/danger 三级；qewma ≥0.45 进 warning、≥0.70 进 danger，退出阈值分别为 0.35 / 0.55（滞回防抖）；需连续 3 个样本确认、切换后冷却 6s、Cost 变化 <5 不下发。

5. **切换的数学条件**：控制器只通过 vtysh 改接口 Cost。以 H1→H3 为例，R3 视角主路径 Cost = c (r3\_r5)+10+10 = c+20，备用路径固定 90；当 **c(r3\_r5) > 70** 时主备反转，OSPF 自动把 R3 去 H3 的下一跳从经 R5 的 `10.16.6.3` 改为经 R4 的 `10.16.5.3`。

* S5 线性 Cost 上限 100、逐步爬升，在 E2 仅时延 / 丢包档位最高仅 66（主总 86 < 备 90），故只更新不反转；

* S6 进入 danger 时直接把 Cost 惩罚到 200（主总 220 > 备 90），可靠完成切换，恢复后 Cost 回落、自动切回；

* normal/warning 阶段若线性 Cost 已自然越过 70，OSPF 同样会切换（E5 中 S6 未进 danger 也发生切换即源于此）。

1. **快速检测**：S3 收紧 Hello/Dead 到 1s/3s；S4 用 BFD 独立快速探活并通知 OSPF 拆邻接。二者面向硬故障，且全网统一加快使去程、回程同时绕行。

控制器只监测 **5 条关键链路**：`r3_r5`、`r3_r4`、`r4_r7`、`r5_r7`、`r9_r10`，不做全网巡检以降低串行探测开销。

## 快速开始（完整复现流程）

### 0. 镜像准备

项目默认使用本地镜像、不自动联网拉取。先查看本机镜像：



```
docker images
```

若镜像标签与 `.env` 不一致，复制并修改 `.env`（镜像名与标签必须完全一致，`frrouting/frr:10.4.1` 与 `quay.io/frrouting/frr:10.4.1` 是两个镜像名）：



```
cp .env.example .env

\# 按需把 FRR\_IMAGE / HOST\_IMAGE 改成本机实际 REPOSITORY:TAG
```

若明确允许本次联网拉取镜像：



```
PULL\_IMAGES=1 ./scripts/run.sh up
```

### 1. 启动拓扑



```
chmod +x scripts/\*.sh

./scripts/run.sh up

./scripts/status.sh
```

`up` 会先校验拓扑、检查镜像，再后台启动 12 台路由器和 4 台主机。

### 2. 配置地址（仅容器不重启时无需重复；重建后必须执行）



```
./scripts/run.sh addresses
```

该步骤先发现容器实际接口名（接口编号不保证是 eth1/eth2，**不要手工假定**），生成 `state/interfaces.env`（46 行），再配置 Loopback 与各链路地址。

### 3. 部署一个方案



```
./scripts/run.sh scheme s6      # 可选 s2 / s3 / s4 / s5 / s6

./scripts/run.sh check          # 查看 OSPF 邻居与连通性
```

`scheme` 会重新下发基础 OSPF 与逐接口 Cost / 网络类型 / 定时器，S4 配置 BFD，S5/S6 启动动态 Cost 控制器，并等待收敛。**每次跑实验前，先确保已部署对应方案。**

### 4. 运行场景并分析



```
./scripts/run.sh e2             # 在当前方案下跑一次 E2 场景

./scripts/run.sh analyze-e2     # 离线统计丢包 / RTT / 下一跳 / 控制器事件
```

结果保存在 `results/e2/<scheme>-<时间戳>/`。

### 5. 一键批量跑某场景的方案矩阵



```
./scripts/run.sh e2-all         # 自动依次 部署方案→跑场景，遍历该场景矩阵

./scripts/run.sh analyze-e2
```

各场景的方案矩阵：E1 = S2–S6；E2 / E5 = S2、S5、S6；E3 / E4 = S2、S3、S4、S6。

> 另一种基于文件的 OSPF 下发方式：
>
> `run.sh configs`
>
> （生成配置）→ 
>
> `run.sh ospf`
>
> （下发）。主流程的 
>
> `scheme`
>
>  已集成 OSPF 下发，一般无需单独执行这两步。

## E1–E5 实验说明与实测结论



| 场景（故障类型）            | S2 默认 OSPF                | S3 快定时器        | S4 BFD            | S5 线性 Cost              | S6 状态机                                     |
| ------------------- | ------------------------- | -------------- | ----------------- | ----------------------- | ------------------------------------------ |
| E1 无故障基线            | 0 丢包、RTT 亚毫秒              | 0 丢包           | 0 丢包              | 0 丢包                    | 0 丢包、无误动作                                  |
| E2 软劣化渐变（单向时延 + 丢包） | 硬扛，重度 RTT 约 50ms、丢包约 2.1% | —              | —                 | Cost 最高 66 不反转、丢包约 2.7% | danger 打 200，约 60s 切备 / 76s 回主，丢包 1.47% 最低 |
| E3 单链路硬断（loss 100%） | 中断约 20s                   | 约 0.6s         | 约 0.2s，最快         | —                       | 约 5.2s                                     |
| E4 节点整机失效（停 R5 20s） | 26.4s / 丢 21.44%          | 1.2s / 丢 1.92% | 约 0s / 丢 0.32%，最优 | —                       | 26.2s / 丢 21.92%，回程黑洞                      |
| E5 随机波动（扰动 60s）     | 扰动段 P95 约 403ms、丢 5 个     | —              | —                 | P95 0.36ms、0 丢、切 4 次    | P95 50.3ms、丢 1 个、切 4 次、danger 0 次          |



* **E1 基线**：无故障下五方案全程 0 丢包、亚毫秒 RTT、无切换，证明各机制正常时不引入额外损伤或误动作。

* **E2 软劣化渐变**：对 R3–R5 单向施加 正常 / 10ms / 30ms / 50ms 并伴随丢包（链路不断）。S2 不感知硬扛；S5 Cost 最高 66 不反转，验证 "能感知、不强制切"；S6 进入 danger、Cost 打到 200，约 60s 切备、76s 回主，总丢包 1.47% 最低，证明可提前主动避险。

* **E3 单链路硬断**：对主路径链路施加 100% 丢包（链路断、节点在）。中断时长 S4 ≈0.2s < S3 ≈0.6s < S6 ≈5.2s < S2 ≈20s，说明硬故障下专用快速检测最快。

* **E4 节点整机失效**：`docker stop R5` 20s。受损流中断 S4 ≈0s（丢 0.32%）< S3 ≈1.2s < S6 ≈26.2s ≈ S2 ≈26.4s；对照流 H2→H4 四方案均 0 丢包、下一跳恒定，验证故障隔离。


  * **回程黑洞（重要现象）**：去程分叉点 R3 被控制器抬开走备，但回程分叉点在 R9，R9–R5 不在受控链路集合，且 20s 停机短于默认 Dead 40s，R9 邻接未超时、仍把回程指向已停机的 R5，直到邻接重建（约 26s）。这说明软劣化导向的 S6 在整机硬故障下存在去回程不同步。

* **E5 随机波动**：固定种子（SEED=20260908），60s 内随机扰动主路径 R3–R5 或旁路 R4–R7 / R5–R7（3–12s，含 tbf 排队档位）。扰动打在主路径时 S5/S6 切备避让，P95 由 S2 约 403ms 降到 S5 0.36ms / S6 50.3ms；打在旁路时主路径零误切。S5/S6 的切换来自排队下线性 Cost 短暂越过 70 的自然反转，故 S6 全程 danger 0 次与发生切换并不矛盾。

## 停止、清理与重置



```
./scripts/run.sh down      # 删除容器和网络，保留配置与结果

./scripts/run.sh reset     # 额外清理 frr/generated 与运行时状态，保留历史结果

PURGE\_RESULTS=1 ./scripts/reset.sh   # 连结果、日志一并删除
```

## 常见问题与排障



* **容器长时间停在 Starting**：`Ctrl+C` 后执行 `docker compose ps -a`、`docker inspect $(docker compose ps -q R5) --format '{{.State.Status}} {{.State.Error}}'`、`docker compose logs --tail=100 R5`、`docker info`，确认问题后 `reset` 再 `up`；不要连续重复执行 `up`。

* `docker exec`**&#x20;很慢、OSPF 90s 不收敛**：多为宿主机负载过高（`cat /proc/loadavg`）。停掉无关后台进程（如 k3s、update-manager /packagekit、apt-check 等），保证 load 与 CPU 核数匹配后再部署。

* **接口名对不上**：接口编号由 Docker 分配，务必通过 `run.sh addresses` 反查生成 `state/interfaces.env`，不要在脚本里写死 eth1/eth2。

* **E2 时延翻倍**：netem 单向时延应只在链路一端施加；若两端都施加全额时延，RTT 增幅会翻倍。

* **BFD 会话未建立**：S4 部署后用 `vtysh -c 'show bfd peers'` 确认状态为 up。

## 研究边界与未来工作（S7）

本版核心贡献是 "链路未断开时的质量感知与主动避险"：S5 验证质量可量化并反映到 Cost，S6 用三级状态机实现 "该切才切、噪声不误切、非全丢不进 danger"。硬故障以 S3/S4 为对照，E3/E4 表明专用快速检测可把中断压到亚秒至秒级，而 S6 主动探测为秒级且在整机失效下存在回程黑洞。因此本版证明的是 "动态 Cost 与快速检测各自擅长不同故障"，尚未实现统一机制。

未来工作 S7"动态 Cost + BFD 混合方案"：以 BFD 为底座在全部相邻链路（含 R9–R5 等回程方向）双向逐跳部署，负责硬故障、去回程同时切换以补齐回程黑洞；在邻接 Full、BFD 不告警时由动态 Cost 状态机负责软劣化；仲裁上硬故障优先、恢复时平滑收回 Cost。预期在 E2/E5 保持 S6 的避险效果、在 E3/E4 达到 S4 的亚秒级收敛且无黑洞。

## 交付物清单

16 节点 Docker/FRR 环境、拓扑图与地址表、S2–S6 方案部署脚本、动态 Cost 控制器、E1–E5 执行与分析脚本、原始日志、结果数据（`results/`）、对比图、风险分级算法说明（本 README）与最终实验计划书 / 报告。