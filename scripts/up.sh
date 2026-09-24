#!/usr/bin/env bash
set -Eeuo pipefail #Eeuo: -E: 函数内部也能捕获错误信号，保证深层调用的子脚本出错也能触发终止，-e: 遇到错误立即退出，-u: 未定义变量报错，-o pipefail: 管道中任意命令失败则返回失败
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
[[ -f .env ]] || cp .env.example .env
python3 scripts/topology_validate.py
set -a
source .env
set +a
if [[ "${PULL_IMAGES:-0}" == 1 ]]; then
  docker pull "$FRR_IMAGE"
  docker pull "$HOST_IMAGE"
fi
for image in "$FRR_IMAGE" "$HOST_IMAGE"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "本地找不到镜像: $image" >&2
    echo "请先执行 docker images 查看实际标签，然后修改 .env 中的 FRR_IMAGE 或 HOST_IMAGE。" >&2
    exit 1
  fi
done
"${COMPOSE[@]}" config >/dev/null
COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-4}" "${COMPOSE[@]}" up -d #以并发上限 4，按 .env 和 docker-compose.yml 后台拉起拓扑里所有容器（FRR 路由器 + 主机）。
echo "topology started; run ./scripts/status.sh" #echo:`echo` 是 bash shell 最基础命令：**打印输出文本到终端屏幕**。 输出提示信息，告诉用户拓扑已经启动，可以运行 status.sh 查看状态

#"${COMPOSE[@]}"
#这是数组展开。COMPOSE 在 common.sh:8 里定义为数组：
#COMPOSE=(docker compose --env-file .env -f docker-compose.yml)
#[@] 表示展开数组的所有元素。
#加了双引号 "${COMPOSE[@]}" 是关键：每个元素被当作独立的、带引号的参数展开（不会被空格二次拆分、也不会被通配符展开）。
#于是 "${COMPOSE[@]}" 展开后就是三个独立的单词：
#docker  compose  --env-file .env  -f docker-compose.yml
#这样写的好处：脚本里统一用 "${COMPOSE[@]}" 引用，改 compose 命令/参数只需改 common.sh 一处，比如没有 .env 文件时就换成 docker compose -f docker-compose.yml。