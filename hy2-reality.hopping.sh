#!/bin/bash
# ============================================================================
# hy2-reality.sh — Hysteria2 + Reality 二合一安装脚本 (带选项)
#
# 用法:
#   整段粘贴到 root 终端回车, 按菜单安装 / 卸载
#   bash hy2-reality.sh hy2                # 直接装 HY2, 跳过菜单
#   bash hy2-reality.sh reality            # 直接装 Reality, 跳过菜单
#   bash hy2-reality.sh uninstall-hy2      # 卸载 HY2, 跳过菜单
#   bash hy2-reality.sh uninstall-reality  # 卸载 Reality, 跳过菜单
#   bash hy2-reality.sh show               # 查看已安装节点信息, 跳过菜单
#   bash hy2-reality.sh hy2 --measure-only # 只测速不安装
#   bash hy2-reality.sh hy2 --no-bandwidth # HY2 跳过测速, BBR 模式安装
#
# 可调选项 (粘贴前改这里):
#   MODE="ask"   # ask=菜单 / hy2 / reality / uninstall-hy2 / uninstall-reality
#   HY2_PORT="8443"                # HY2 UDP 端口 (被占用则随机)
#   HY2_PORT_RANGE=""              # HY2 端口跳跃范围, 如 20000-50000; 留空=单端口模式
#   SKIP_BANDWIDTH=0               # 1=跳过测速与带宽参数, BBR 模式装 HY2
#   MEASURE_ONLY=0                 # 1=只测速不安装
#   REALITY_PORT="8880"            # Reality TCP 端口 (被占用则随机)
#   REALITY_SNI="www.microsoft.com"# Reality 伪装域名 (dest 自动跟随)
#   REALITY_DEST=""                # 留空则自动为 $REALITY_SNI:443
#   REALITY_UUID=""                # 留空则随机生成 (重装时复用旧 UUID)
#   XRAY_VERSION=""                # 留空装最新版; 填 v1.8.4 之类可锁版本
#
# 说明:
#   HY2 部分: 自动测速 (各 3 次取中位数 × 0.8) 决定带宽参数, 启用 Brutal;
#             测速失败时可重测 / 降级 BBR / 退出
#   Reality 部分: VLESS + TCP + Reality, 伪装站与 SNI 一致, 自动放行防火墙,
#             输出 vless 链接 + 二维码 + Clash 配置片段
#   菜单开机先显示已安装状态; 操作完成后按任意键返回主菜单;
#   卸载会删除服务、配置、证书/密钥与二进制, 并清理本机防火墙规则
# ============================================================================
(
export LANG=en_US.UTF-8

# ---------- 共享: 颜色与输出 ----------
re='\e[0m'; red='\e[1;91m'; green='\e[1;32m'; yellow='\e[1;33m'; skyblue='\e[1;96m'
die()  { echo -e "${red}[错误] $*${re}" >&2; exit 1; }
info() { echo -e "${green}[信息] $*${re}"; }
warn() { echo -e "${yellow}[警告] $*${re}" >&2; }

# ---------- 可调选项 ----------
MODE="${MODE:-ask}"                  # ask / hy2 / reality / uninstall-hy2 / uninstall-reality / show
HY2_PORT="${HY2_PORT:-8443}"
# 端口跳跃: 留空 = 只用 HY2_PORT 单端口; 填 "起始-结束" = 服务端监听整段, 客户端在段内跳
# 注意: 段内端口全部要能被客户端访问 (本机防火墙 + 云安全组), 否则跳过去直接被丢包
HY2_PORT_RANGE="${HY2_PORT_RANGE:-}"
HY2_HOP_MAX_PORTS="${HY2_HOP_MAX_PORTS:-1000}"   # 段宽上限, 防止误填 1-65535 拖死机器
SKIP_BANDWIDTH="${SKIP_BANDWIDTH:-0}"
MEASURE_ONLY="${MEASURE_ONLY:-0}"
RUNS=3
SAFETY="0.8"
MIN_MBPS=5
# 注意: 每次测速的流量成本 = 下载 10MB×RUNS + 上传 UP_TEST_MB×RUNS, 按流量计费的机器请酌情
UP_TEST_MB=10
REALITY_PORT="${REALITY_PORT:-8880}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_UUID="${REALITY_UUID:-}"
XRAY_VERSION="${XRAY_VERSION:-}"           # 留空=装最新版; 填如 v1.8.4 可锁版本, 便于复现

[[ $EUID -ne 0 ]] && die "请在 root 用户下运行脚本"

# ---------- 公共函数 (顶层定义, 各子 shell 均可继承) ----------
get_ip() {
  HOST_IP=$(curl -4 -s --max-time 5 ipv4.ip.sb)
  # 第二次兜底原来又打同一个 IPv4 站, 等于没兜底; 改成 IPv6 站才真有意义
  [ -z "$HOST_IP" ] && HOST_IP=$(curl -s --max-time 5 ipv6.ip.sb)
  [ -z "$HOST_IP" ] && { echo -e "${red}无法获取公网 IP${re}"; exit 1; }
  # 上面最后一个判断为假时整条命令状态为 1, 在 set -e 下会误退出, 必须显式返回 0
  return 0
}

print_links() {
  local port=$1 passwd=$2
  local tag="HY2-${HOST_IP}"
  echo ""
  echo -e "${green}========== 节点信息 ==========${re}"
  if [[ "$port" == *-* ]]; then
    echo -e "端口跳跃: ${skyblue}$port${re} (UDP)  密码: ${skyblue}$passwd${re}"
  else
    echo -e "端口: ${skyblue}$port${re}  密码: ${skyblue}$passwd${re}"
  fi
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo -e "带宽: up ${CFG_UP_MBPS} Mbps / down ${CFG_DOWN_MBPS} Mbps (Brutal 已启用)"
  else
    echo -e "${yellow}未设置带宽参数, 当前为 BBR 模式${re}"
  fi
  # 免得用户以为 up 写大点上行就快了: Brutal 只压下行, 上行还是被本机上传带宽卡死
  echo -e "${yellow}提示: Brutal 只对 '服务端→客户端(下行)' 生效, 上行仍受本机上传带宽限制${re}"
  if [[ "$port" == *-* ]]; then
    echo -e "${yellow}提示: 端口跳跃已启用, 客户端会在 ${port} 内随机选端口; 该段每个 UDP 口都要通${re}"
  fi
  echo ""
  echo -e "${yellow}--- V2rayN / Nekobox / Streisand ---${re}"
  # 跳跃模式: 冒号后仍要写一个具体端口, 实际端口段用 mport 参数带
  if [[ "$port" == *-* ]]; then
    local hop_first="${port%%-*}"
    echo "hysteria2://$passwd@$HOST_IP:${hop_first}/?sni=www.bing.com&alpn=h3&insecure=1&mport=${port}#$tag"
  else
    echo "hysteria2://$passwd@$HOST_IP:$port/?sni=www.bing.com&alpn=h3&insecure=1#$tag"
  fi
  echo ""
  echo -e "${yellow}--- Clash / Mihomo ---${re}"
  echo "- name: $tag"
  echo "  type: hysteria2"
  echo "  server: $HOST_IP"
  if [[ "$port" == *-* ]]; then
    # mihomo 用 ports 字段表达端口跳跃, 不是 port
    echo "  ports: \"$port\""
  else
    echo "  port: $port"
  fi
  echo "  password: $passwd"
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo "  up: \"${CFG_UP_MBPS} Mbps\""
    echo "  down: \"${CFG_DOWN_MBPS} Mbps\""
  fi
  echo "  sni: www.bing.com"
  echo "  alpn:"
  echo "    - h3"
  echo "  skip-cert-verify: true"
  echo ""
  echo -e "${red}注意: 云厂商安全组 (如 AWS) 需手动放行 UDP $port, 脚本够不着控制台${re}"
}

# ============================================================================
# HY2 部分 (独立子 shell, 与 Reality 部分零冲突)
# ============================================================================
run_hy2() (
set -eo pipefail
# ---------------- 依赖 ----------------
install_deps() {
  # 按"命令"而不是"包名"检查: iproute2/coreutils 是包名, ss/shuf 才是命令名
  local missing=""
  need() { command -v "$1" >/dev/null 2>&1 || missing="$missing $2"; return 0; }
  need curl curl; need openssl openssl; need awk gawk; need ss iproute2; need shuf coreutils
  if [ -z "$missing" ]; then
    echo -e "${green}依赖已齐全, 跳过安装${re}"
    return 0
  fi
  echo -e "${yellow}正在安装缺失依赖:$missing${re}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || warn "apt-get update 失败, 继续尝试安装"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing || die "依赖安装失败:$missing"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $missing || die "依赖安装失败:$missing"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q $missing || die "依赖安装失败:$missing"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $missing || die "依赖安装失败:$missing"
  else
    die "不支持的系统"
  fi
}

# ---------------- 测速 ----------------
# 中位数: 输入一组字节/秒, 输出中位数
median_bps() {
  local sorted n mid
  # 修复: 空数组时 printf '%s\n' "${arr[@]}" 会吐一行空串, n 永远不为 0, 下面兜底形同虚设
  [ $# -eq 0 ] && { echo 0; return; }
  sorted=($(printf '%s\n' "$@" | sort -n))
  n=${#sorted[@]}
  [ "$n" -eq 0 ] && { echo 0; return; }
  mid=$((n / 2))
  if [ $((n % 2)) -eq 1 ]; then
    echo "${sorted[$mid]}"
  else
    echo $(( (sorted[mid-1] + sorted[mid]) / 2 ))
  fi
}

# 字节/秒 -> Mbps 显示 (1 位小数)
to_mbps() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b*8/1000000}'
}

# 测下载, 输出中位数 (字节/秒)
measure_down() {
  local speeds=() s i
  for i in $(seq 1 "$RUNS"); do
    s=$(curl -4 -o /dev/null -s -w '%{speed_download}' --max-time 20 \
      http://cachefly.cachefly.net/10mb.test 2>/dev/null || true)
    s=${s%.*}
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
      speeds+=("$s")
      echo -e "${skyblue}  下载测试 $i/$RUNS: $(to_mbps "$s") Mbps${re}" >&2
    else
      echo -e "${skyblue}  下载测试 $i/$RUNS: 失败${re}" >&2
    fi
  done
  median_bps "${speeds[@]}"
}

# 测上传, 输出中位数 (字节/秒)
measure_up() {
  local speeds=() s i
  # 注意: 测速会把本机出口 IP 与 UP_TEST_MB×RUNS 的上传数据发给 speed.cloudflare.com
  dd if=/dev/urandom of=/tmp/hy2up_test bs=1M count="$UP_TEST_MB" 2>/dev/null || true
  for i in $(seq 1 "$RUNS"); do
    s=$(curl -4 -s -o /dev/null -w '%{speed_upload}' --max-time 30 \
      -X POST --data-binary @/tmp/hy2up_test https://speed.cloudflare.com/__up 2>/dev/null || true)
    s=${s%.*}
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
      speeds+=("$s")
      echo -e "${skyblue}  上传测试 $i/$RUNS: $(to_mbps "$s") Mbps${re}" >&2
    else
      echo -e "${skyblue}  上传测试 $i/$RUNS: 失败${re}" >&2
    fi
  done
  rm -f /tmp/hy2up_test
  median_bps "${speeds[@]}"
}

# 决策: 字节/秒 -> 保守 Mbps 整数 (中位数 × 安全系数, 向下取整, 最低 1)
# 不在此处保底 MIN_MBPS: Brutal 写高于真实带宽反而丢包, 阈值判断交给 do_measure
decide_mbps() {
  local mbps
  mbps=$(awk -v b="${1:-0}" -v s="$SAFETY" 'BEGIN{v=b*8/1000000*s; if(v<1)v=1; printf "%d", v}')
  echo "$mbps"
}

# 测速 + 决策, 成功返回 0, 并设置 CFG_UP_MBPS / CFG_DOWN_MBPS
do_measure() {
  echo -e "${yellow}正在测速 (下载/上传各 $RUNS 次, 取中位数 × $SAFETY 保守系数)...${re}"
  DOWN_BPS=$(measure_down)
  UP_BPS=$(measure_up)
  echo -e "${green}实测中位数: 下载 $(to_mbps "$DOWN_BPS") Mbps / 上传 $(to_mbps "$UP_BPS") Mbps${re}"
  if [ -z "$DOWN_BPS" ] || [ -z "$UP_BPS" ] || [ "$DOWN_BPS" -eq 0 ] || [ "$UP_BPS" -eq 0 ]; then
    echo -e "${red}测速失败, 无法决定带宽参数${re}"
    return 1
  fi
  # 注意方向: 服务端 up = 服务端上传 = 本机上传 ; 服务端 down = 本机下载
  # cachefly/cloudflare 测的是"本机↔第三方", 只能近似"用户↔本机"的可用带宽, 仅作参考
  CFG_UP_MBPS=$(decide_mbps "$UP_BPS")
  CFG_DOWN_MBPS=$(decide_mbps "$DOWN_BPS")
  if [ "$CFG_UP_MBPS" -lt "$MIN_MBPS" ] || [ "$CFG_DOWN_MBPS" -lt "$MIN_MBPS" ]; then
    echo -e "${yellow}实测低于 ${MIN_MBPS} Mbps, 硬写进 Brutal 反而丢包, 本次不启用 Brutal, 走 BBR${re}"
    CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
  else
    echo -e "${green}决定参数: bandwidth.up = ${CFG_UP_MBPS} mbps, bandwidth.down = ${CFG_DOWN_MBPS} mbps${re}"
  fi
  return 0
}

# 测速失败时询问用户: 返回 2=重测, 1=降级 BBR (选择 3 则直接退出)
# 用 /dev/tty 读取, 粘贴运行时也不会误吞脚本自身的输入
ask_on_measure_fail() {
  local choice=""
  echo -e "${yellow}测速失败, 请选择:${re}"
  echo "  1) 重新测速"
  echo "  2) 降级为 BBR 模式继续安装 (不写 bandwidth 参数)"
  echo "  3) 退出安装"
  read -r -p "请输入 1/2/3 [默认 2]: " choice < /dev/tty 2>/dev/null || choice="2"
  echo ""
  case "$choice" in
    1) return 2 ;;
    3) echo -e "${yellow}已退出安装${re}"; exit 1 ;;
    *) return 1 ;;
  esac
}

# ---------------- 安装 ----------------
pick_port() {
  local p="$HY2_PORT"
  # ---- 端口跳跃模式 ----
  if [ -n "$HY2_PORT_RANGE" ]; then
    local rng lo hi width
    rng="$HY2_PORT_RANGE"
    if ! [[ "$rng" =~ ^[0-9]+-[0-9]+$ ]]; then
      echo -e "${red}HY2_PORT_RANGE 格式错误: '$rng' (应为 起始-结束, 如 20000-50000)${re}" >&2
      return 1
    fi
    lo="${rng%%-*}"; hi="${rng##*-}"
    if [ "$lo" -lt 1 ] || [ "$hi" -gt 65535 ] || [ "$lo" -ge "$hi" ]; then
      echo -e "${red}HY2_PORT_RANGE 越界或首尾颠倒: '$rng' (需 1 <= 起始 < 结束 <= 65535)${re}" >&2
      return 1
    fi
    width=$((hi - lo + 1))
    if [ "$width" -gt "$HY2_HOP_MAX_PORTS" ]; then
      echo -e "${red}HY2_PORT_RANGE 段宽 $width 超过上限 $HY2_HOP_MAX_PORTS, 请缩小范围或调大 HY2_HOP_MAX_PORTS${re}" >&2
      return 1
    fi
    # 只提示占用情况, 不像单端口那样换端口: 换段就等于换了一组防火墙/安全组放行规则
    if ss -ulpn 2>/dev/null | grep -qE "[:.]${lo}[[:space:]]"; then
      echo -e "${yellow}端口跳跃段起点 $lo 已被占用, 该端口会被跳过, 其余端口仍可用${re}" >&2
    fi
    echo "$rng"
    return 0
  fi
  # ---- 单端口模式 ----
  if ss -ulpn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
    # shuf 缺失或失败时兜底一个随机端口, 免得在 set -e 下直接崩掉
    p=$(shuf -i 20000-60000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
    echo -e "${yellow}端口 $HY2_PORT 被占用, 改用随机端口 $p${re}" >&2
  fi
  echo "$p"
}

install_hy2() {
  echo -e "${yellow}正在安装 Hysteria2 ...${re}"
  # 注意: get.hy2.sh 是一段远程脚本, 官方不提供签名校验, 这里以 root 身份管道执行;
  # 无法验证内容, 介意供应链风险就别用, 或自行改成手动下载校验。
  bash <(curl -fsSL https://get.hy2.sh/) >/tmp/hy2install.log 2>&1 \
    && echo -e "${green}Hysteria2 安装成功${re}" \
    || { echo -e "${red}安装失败, 日志:${re}"; tail -20 /tmp/hy2install.log; exit 1; }
}

gen_cert() {
  mkdir -p /etc/hysteria
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" -days 36500 2>/dev/null \
    || { echo -e "${red}证书生成失败, 请检查 openssl 是否可用${re}"; exit 1; }
  echo -e "${green}自签证书已生成${re}"
  chmod 600 /etc/hysteria/server.key
}

write_config() {
  local port=$1 passwd=$2
  {
    # Hysteria2 原生支持 listen 写端口段 (如 :20000-50000), 单端口和跳跃模式同一行写法
    echo "listen: :$port"
    echo ""
    echo "tls:"
    echo "  cert: /etc/hysteria/server.crt"
    echo "  key: /etc/hysteria/server.key"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: \"$passwd\""
    echo ""
    if [ -n "${CFG_UP_MBPS:-}" ]; then
      echo "bandwidth:"
      echo "  up: ${CFG_UP_MBPS} mbps"
      echo "  down: ${CFG_DOWN_MBPS} mbps"
      echo ""
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://bing.com"
    echo "    rewriteHost: true"
  } > /etc/hysteria/config.yaml
  id hysteria >/dev/null 2>&1 && chown -R hysteria:hysteria /etc/hysteria
  # 配置里是明文密码, 非 hysteria 用户也要锁掉读取权限
  chmod 600 /etc/hysteria/config.yaml
  echo -e "${green}配置文件已写入${re}"
}

start_service() {
  systemctl daemon-reload
  # enable 失败不影响运行(可能没有 systemd 预设单元), 重启失败才致命,
  # 所以 enable 不加 set -e 的连带退出
  systemctl enable hysteria-server.service >/dev/null 2>&1 \
    || echo -e "${yellow}开机自启设置失败, 不影响本次运行${re}" >&2
  systemctl restart hysteria-server.service \
    || { echo -e "${red}服务重启失败, 请检查: journalctl -u hysteria-server${re}"; exit 1; }
  sleep 3
  if [ "$(systemctl is-active hysteria-server.service)" = "active" ]; then
    echo -e "${green}服务运行中${re}"
  else
    echo -e "${red}服务启动失败, 请检查: journalctl -u hysteria-server${re}"
    exit 1
  fi
}

open_firewall() {
  local port=$1
  # 跳跃模式: 整段一起放行, 写法跟单端口不一样
  #   ufw        用 起始:结束/udp
  #   firewalld  用 起始-结束/udp
  if [[ "$port" == *-* ]]; then
    local rlo="${port%%-*}" rhi="${port##*-}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "$rlo:$rhi"/udp >/dev/null \
        && echo -e "${green}ufw 已放行 $rlo:$rhi/udp${re}" \
        || echo -e "${red}ufw 放行 $rlo:$rhi/udp 失败, 请手动放行${re}" >&2
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
      firewall-cmd --permanent --add-port="$rlo-$rhi"/udp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
        && echo -e "${green}firewalld 已放行 $rlo-$rhi/udp${re}" \
        || echo -e "${red}firewalld 放行 $rlo-$rhi/udp 失败, 请手动放行${re}" >&2
    else
      echo -e "${yellow}未检测到启用的本机防火墙 (云厂商安全组请手动放行 UDP $rlo-$rhi)${re}"
    fi
    echo -e "${red}注意: 云厂商安全组要放行整段 UDP $rlo-$rhi, 只放一个口跳跃会全部失败${re}"
    return 0
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port"/udp >/dev/null && echo -e "${green}ufw 已放行 $port/udp${re}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port="$port"/udp >/dev/null && firewall-cmd --reload >/dev/null \
      && echo -e "${green}firewalld 已放行 $port/udp${re}"
  else
    echo -e "${yellow}未检测到启用的本机防火墙 (云厂商安全组请手动放行 UDP $port)${re}"
  fi
}

# ---------------- 主流程 ----------------
for arg in "$@"; do
  case "$arg" in
    --measure-only) MEASURE_ONLY=1 ;;
    --no-bandwidth) SKIP_BANDWIDTH=1 ;;
  esac
done

if [ "$MEASURE_ONLY" = "1" ]; then
  install_deps
  if do_measure; then
    echo ""
    echo -e "${green}建议配置:${re}"
    echo "bandwidth:"
    if [ -n "${CFG_UP_MBPS:-}" ]; then
      echo "  up: ${CFG_UP_MBPS} mbps    # 服务端上传 = 本机上传"
      echo "  down: ${CFG_DOWN_MBPS} mbps  # 服务端下载 = 本机下载"
    else
      echo -e "${yellow}  实测带宽过低, 已判定不启用 Brutal; 保持空值即为 BBR 模式${re}"
    fi
    exit 0
  fi
  # 测速失败不该返回成功码, 否则调用方会以为测过了
  echo -e "${red}测速失败${re}"
  exit 1
fi

install_deps

echo -e "${yellow}=== 第 1 步: 测速并决定带宽参数 ===${re}"
if [ "$SKIP_BANDWIDTH" = "1" ]; then
  echo -e "${yellow}已跳过测速与带宽参数, 使用 BBR 模式安装${re}"
  CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
else
  while true; do
    if do_measure; then
      if [ -n "${CFG_UP_MBPS:-}" ]; then
        echo -e "${green}将启用 Brutal 拥塞控制${re}"
      else
        echo -e "${yellow}实测带宽不足, 本次按 BBR 模式安装 (不写 bandwidth)${re}"
      fi
      break
    fi
    # set -e 下裸调用一个可能返回非 0 的函数会直接终止脚本, 必须吞掉返回码
    _rc=0
    ask_on_measure_fail || _rc=$?
    if [ "$_rc" -eq 1 ]; then
      echo -e "${yellow}降级为 BBR 模式继续安装${re}"
      CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
      break
    fi
    # 返回 2: 循环回去重新测速
  done
fi

echo -e "${yellow}=== 第 2 步: 安装 Hysteria2 ===${re}"
install_hy2

echo -e "${yellow}=== 第 3 步: 生成证书与配置 ===${re}"
PORT=$(pick_port)
# 重装复用旧密码: 换密码等于让所有老客户端全部失效, 没必要的破坏
PASSWD=""
if [ -f /etc/hysteria/config.yaml ]; then
  PASSWD=$(sed -n 's/^  password: "\(.*\)"$/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)
  [ -n "$PASSWD" ] && echo -e "${green}复用旧配置中的密码, 老客户端不受影响${re}"
fi
[ -n "$PASSWD" ] || PASSWD=$(cat /proc/sys/kernel/random/uuid)
gen_cert
write_config "$PORT" "$PASSWD"

echo -e "${yellow}=== 第 4 步: 启动服务 ===${re}"
start_service
open_firewall "$PORT"

echo -e "${yellow}=== 第 5 步: 输出节点信息 ===${re}"
get_ip
print_links "$PORT" "$PASSWD"
)

# ============================================================================
# Reality 部分 (独立子 shell, 与 HY2 部分零冲突)
# ============================================================================
run_reality() (
set -euo pipefail

# 变量映射: 顶部 REALITY_* 选项 -> 内部变量名
PORT="$REALITY_PORT"
UUID="$REALITY_UUID"
SNI="$REALITY_SNI"
DEST="${REALITY_DEST:-$REALITY_SNI:443}"

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
# 归属标记: 只有本脚本装出来的 Xray 才允许被卸载时整目录删除
XRAY_OWNED_MARK="/usr/local/etc/xray/.hy2-reality-owned"
# 备份目录刻意放在 /usr/local/etc/xray 之外, 否则卸载时会跟配置一起被删
BACKUP_DIR="/root/hy2-reality-backup"

RE_PRIVATE_KEY=""
RE_PUBLIC_KEY=""
SHORT_ID=""

# ---------- 安装依赖（缺啥装啥） ----------
install_deps() {
    local pkgs="gawk curl openssl qrencode" pkg missing=""
    for pkg in $pkgs; do
        command -v "$pkg" &>/dev/null || missing="$missing $pkg"
    done
    if [[ -z "$missing" ]]; then
        info "系统依赖已齐全，跳过安装"
        return 0
    fi
    info "正在安装缺失依赖:$missing"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing || die "依赖安装失败:$missing"
    elif command -v dnf &>/dev/null; then
        # shellcheck disable=SC2086
        dnf install -y $missing || die "依赖安装失败:$missing"
    elif command -v yum &>/dev/null; then
        # shellcheck disable=SC2086
        yum install -y $missing || die "依赖安装失败:$missing"
    elif command -v apk &>/dev/null; then
        # shellcheck disable=SC2086
        apk add $missing || die "依赖安装失败:$missing"
    else
        die "暂不支持的系统"
    fi
}

# ---------- 安装 Xray（已安装则跳过） ----------
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        info "检测到 Xray 已安装，跳过安装步骤"
        if [[ ! -f "$XRAY_OWNED_MARK" ]]; then
            warn "该 Xray 可能是你手动或用别的脚本装的, 卸载时本脚本只会删配置, 不会删程序"
        fi
        return 0
    fi
    info "正在安装 Xray..."
    local installer
    # 注意: 远程安装脚本没有签名校验, 且默认拉最新 tag, 跨版本行为会漂;
    # 需要可复现就把 XRAY_VERSION 设成具体版本号
    installer="$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        || die "下载 Xray 安装脚本失败"
    if [[ -n "${XRAY_VERSION:-}" ]]; then
        bash -c "$installer" @ install --version "$XRAY_VERSION" || die "Xray 安装失败"
    else
        bash -c "$installer" @ install || die "Xray 安装失败"
    fi
    [[ -x "$XRAY_BIN" ]] || die "Xray 安装后仍找不到二进制文件: $XRAY_BIN"
    mkdir -p "$(dirname "$XRAY_OWNED_MARK")"
    date -u +%FT%TZ > "$XRAY_OWNED_MARK" 2>/dev/null || true
    info "已标记该 Xray 由本脚本安装"
}

# ---------- 端口预检（全新安装时被占则换随机端口） ----------
check_port() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    if ss -tlnp 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
        warn "端口 $PORT 已被占用，改用随机端口"
        PORT="$(shuf -i 20000-60000 -n 1)"
        info "新端口: $PORT"
    fi
}

# ---------- UUID：优先复用旧配置 ----------
resolve_uuid() {
    if [[ -z "$UUID" && -f "$CONFIG_FILE" ]]; then
        # pipefail 下 grep 无命中返回 1 会顺着管道传出去, 这里必须显式兜住
        UUID="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)"
        [[ -n "$UUID" ]] && info "复用旧配置中的 UUID，老客户端不受影响"
    fi
    if [[ -z "$UUID" ]]; then
        UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')"
    fi
    [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "无法获得合法的 UUID"
}

# ---------- 生成密钥对（兼容多种输出格式，解析失败直接报错） ----------
gen_keys() {
    # 重装优先复用旧密钥对和 shortId: 换了密钥, 所有已导入链接的客户端立刻全部失效
    local old_priv="" old_sid=""
    if [[ -f "$CONFIG_FILE" ]]; then
        old_priv="$(grep -oE '"privateKey"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)"
        old_sid="$(grep -oE '"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4 || true)"
    fi
    if [[ -n "$old_priv" && -x "$XRAY_BIN" ]]; then
        local derived
        derived="$("$XRAY_BIN" x25519 -i "$old_priv" 2>/dev/null | tr -d '\r' || true)"
        RE_PUBLIC_KEY="$(awk -F': *' 'tolower($0)~/public/ && tolower($0)~/key/ {print $2; exit}' <<<"$derived" | awk '{print $1}')"
        # 部分版本只吐裸 token, 没有 "PublicKey:" 前缀, 用 43 位 base64url 兜底
        [[ -z "$RE_PUBLIC_KEY" ]] && RE_PUBLIC_KEY="$(awk '{print $NF}' <<<"$derived" | grep -oE '^[A-Za-z0-9_-]{43}$' || true)"
        if [[ -n "$RE_PUBLIC_KEY" ]]; then
            RE_PRIVATE_KEY="$old_priv"
            SHORT_ID="${old_sid:-$(openssl rand -hex 8)}"
            info "已复用旧 Reality 密钥与 shortId, 老客户端不受影响"
            return 0
        fi
        warn "旧私钥无法推导出公钥, 将重新生成密钥 (老客户端会失效)"
    fi
    local out
    out="$("$XRAY_BIN" x25519 | tr -d '\r')" || die "执行 xray x25519 失败"
    RE_PRIVATE_KEY="$(awk -F': *' 'tolower($0) ~ /private/ && tolower($0) ~ /key/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
    RE_PUBLIC_KEY="$(awk -F': *' 'tolower($0) ~ /public/ && tolower($0) ~ /key/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
    # 兜底: 没有 "PublicKey:" 前缀时, 取最后一个 43 位 base64url token
    [[ -z "$RE_PUBLIC_KEY" ]] && RE_PUBLIC_KEY="$(grep -oE '[A-Za-z0-9_-]{43}' <<<"$out" | tail -1 || true)"
    [[ -n "$RE_PRIVATE_KEY" && -n "$RE_PUBLIC_KEY" ]] || die "密钥解析失败，xray 输出异常: $out"
    SHORT_ID="$(openssl rand -hex 8)" || die "shortId 生成失败"
}

# ---------- 写配置（先备份，权限 600，写完校验） ----------
write_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # 备份不能放在 /usr/local/etc/xray 里, 卸载会连整个目录删掉
        local bak
        mkdir -p "$BACKUP_DIR" || die "创建备份目录失败: $BACKUP_DIR"
        bak="${BACKUP_DIR}/xray-config.json.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" || die "备份旧配置失败"
        info "已备份旧配置到 $bak"
    else
        mkdir -p "$(dirname "$CONFIG_FILE")"
    fi
    cat > "$CONFIG_FILE" <<EOF
{
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$DEST",
                    "xver": 0,
                    "serverNames": ["$SNI"],
                    "privateKey": "$RE_PRIVATE_KEY",
                    "shortIds": ["$SHORT_ID"]
                }
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "blocked"}
    ]
}
EOF
    chmod 600 "$CONFIG_FILE" || die "设置配置文件权限失败"
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" &>/dev/null || die "生成的配置文件未通过 Xray 校验"
    info "配置文件已写入并通过校验: $CONFIG_FILE"
}

# ---------- 启动服务（兼容无 systemd 环境） ----------
start_service() {
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl enable xray.service || die "设置 xray 开机自启失败"
        systemctl restart xray.service || die "xray 服务启动失败"
        systemctl is-active --quiet xray.service || die "xray 服务未能保持运行，查看日志: journalctl -u xray -n 50"
        info "xray 服务已启动并设为开机自启"
    else
        warn "未检测到 systemd，改用后台进程方式启动"
        pkill -f "[x]ray run" 2>/dev/null || true
        nohup "$XRAY_BIN" run -config "$CONFIG_FILE" >/var/log/xray-reality.log 2>&1 &
        sleep 2
        pgrep -f "[x]ray run" >/dev/null || die "xray 后台启动失败，查看日志: /var/log/xray-reality.log"
        info "xray 已在后台运行（日志: /var/log/xray-reality.log）"
    fi
}

# ---------- 防火墙 ----------
open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1 \
            && info "ufw 已放行 $PORT/tcp" \
            || warn "ufw 放行失败，请手动放行 TCP $PORT"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        if firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            info "firewalld 已放行 $PORT/tcp"
        else
            warn "firewalld 放行失败，请手动放行 TCP $PORT"
        fi
    else
        warn "未检测到启用的本机防火墙；云厂商安全组 (如 AWS) 请手动放行 TCP $PORT"
    fi
}

# ---------- 获取服务器 IP ----------
get_ip() {
    local ip
    ip="$(curl -fsS --max-time 3 https://ipv4.ip.sb 2>/dev/null)" || ip=""
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    ip="$(curl -fsS --max-time 3 https://ipv6.ip.sb 2>/dev/null)" || ip=""
    if [[ -n "$ip" ]]; then echo "[$ip]"; return 0; fi
    if command -v ip &>/dev/null; then
        ip="$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]][[:space:]]*\([0-9.]*\).*/\1/p' | head -1)"
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    fi
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    return 1
}

# ---------- 生成备注名 ----------
get_tag() {
    local json tag=""
    json="$(curl -fsS --max-time 3 "https://api.ip.sb/geoip" 2>/dev/null)" || json=""
    if [[ -n "$json" ]]; then
        tag="$(awk -F'"' '{for(i=1;i<NF;i++){if($i=="country_code")c=$(i+2);if($i=="isp")s=$(i+2)}} END{if(c&&s)print c"-"s}' <<<"$json")"
    fi
    if [[ -z "$tag" ]]; then
        json="$(curl -fsS --max-time 3 "https://ip.api.skk.moe/cf-geoip" 2>/dev/null)" || json=""
        if [[ -n "$json" ]]; then
            tag="$(awk -F'"' '{for(i=1;i<NF;i++){if($i=="country")c=$(i+2);if($i=="asOrg")s=$(i+2)}} END{if(c&&s)print c"-"s}' <<<"$json")"
        fi
    fi
    [[ -z "$tag" ]] && tag="reality"
    tag="$(sed 's/ /_/g' <<<"$tag" | tr -cd '[:alnum:]_.-')"
    [[ -z "$tag" ]] && tag="reality"
    echo "$tag"
}

# ---------- 输出分享链接 + 二维码 + Clash 片段 ----------
print_link() {
    local ip tag url
    ip="$(get_ip)" || die "无法获取服务器公网 IP"
    if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
        warn "检测到内网 IP ($ip)，疑似 NAT 机器：下方链接不可直接使用，请把链接中的 IP 手动替换为公网 IP"
    fi
    tag="$(get_tag)"
    url="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${RE_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${tag}"
    echo ""
    info "Reality 安装成功，客户端导入链接："
    echo -e "\e[1;36m${url}\e[0m"
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 -m 2 -o - "$url" || warn "二维码生成失败"
        echo ""
    fi
    echo "--- Clash / Mihomo 配置片段 ---"
    echo "- name: ${tag}"
    echo "  type: vless"
    echo "  server: ${ip}"
    echo "  port: ${PORT}"
    echo "  uuid: ${UUID}"
    echo "  network: tcp"
    echo "  tls: true"
    echo "  udp: true"
    echo "  flow: xtls-rprx-vision"
    echo "  servername: ${SNI}"
    echo "  client-fingerprint: chrome"
    echo "  reality-opts:"
    echo "    public-key: ${RE_PUBLIC_KEY}"
    echo "    short-id: ${SHORT_ID}"
    echo ""
}

# ---------- 主流程 ----------
install_deps
install_xray
check_port
resolve_uuid
gen_keys
write_config
start_service
open_firewall
print_link
)

# ============================================================================
# 安装状态探测与卸载
# ============================================================================
HY2_CONF="/etc/hysteria/config.yaml"
XRAY_CONF="/usr/local/etc/xray/config.json"
# 与 Reality 子 shell 里的定义保持一致; 备份统一落到这个目录, 不放进会被删的安装目录
BACKUP_DIR="/root/hy2-reality-backup"
XRAY_OWNED_MARK="/usr/local/etc/xray/.hy2-reality-owned"

detect_status() {
  HY2_STATE="未安装"; HY2_DETAIL=""
  if [[ -f "$HY2_CONF" ]]; then
    local p
    # listen 可能是单端口也可能是端口段 (20000-50000), 这里两种都要能读出来
    p=$(sed -n 's/^listen: :\([0-9][0-9]*\(-[0-9][0-9]*\)\{0,1\}\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
    HY2_STATE="已安装"; HY2_DETAIL="UDP ${p:-未知端口}"
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
      HY2_DETAIL="$HY2_DETAIL, 运行中"
    else
      HY2_DETAIL="$HY2_DETAIL, 未运行"
    fi
  fi
  RE_STATE="未安装"; RE_DETAIL=""
  if [[ -f "$XRAY_CONF" ]]; then
    local p
    # 兼容 "port":123 / "port" : 123 之类空格写法, 别把 JSON 格式差异当成没装
    p=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    RE_STATE="已安装"; RE_DETAIL="TCP ${p:-未知端口}"
    if systemctl is-active --quiet xray.service 2>/dev/null; then
      RE_DETAIL="$RE_DETAIL, 运行中"
    else
      RE_DETAIL="$RE_DETAIL, 未运行"
    fi
  fi
}

clean_firewall_rule() {  # $1=端口 $2=udp|tcp, 尽力清理本机防火墙规则
  local port=$1 proto=$2
  [[ -n "$port" ]] || return 0
  # 跳跃段删除时语法跟单端口不同, 否则规则留在防火墙里
  local fport="$port"
  if [[ "$port" == *-* ]]; then
    fport="${port%%-*}:${port##*-}"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$fport"/"$proto" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --remove-port="$port"/"$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

uninstall_hy2() {
  if [[ ! -f "$HY2_CONF" ]]; then
    echo -e "${yellow}Hysteria2 未安装, 无需卸载${re}"
    return 0
  fi
  local port
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\(-[0-9][0-9]*\)\{0,1\}\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  echo -e "${yellow}将卸载 Hysteria2 (停止服务, 删除配置、证书与程序)${re}"
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  # 先备份: 密码在配置里明文, 换机重装时省得重新发一遍给客户端
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  local _ts; _ts="$(date +%Y%m%d%H%M%S)"
  [[ -f "$HY2_CONF" ]] && cp -a "$HY2_CONF" "$BACKUP_DIR/hysteria-config.yaml.$_ts" 2>/dev/null \
    && echo -e "${green}已备份配置到 $BACKUP_DIR/hysteria-config.yaml.$_ts${re}"
  systemctl stop hysteria-server.service 2>/dev/null || true
  systemctl disable hysteria-server.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /usr/local/bin/hysteria
  # 原来 rm -rf 整个 /etc/hysteria, 会连用户自己放进去的东西一起抹掉;
  # 改成只删本脚本装的那三样, 目录非空就留着
  rm -f /etc/hysteria/config.yaml /etc/hysteria/server.key /etc/hysteria/server.crt
  rmdir /etc/hysteria 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  clean_firewall_rule "$port" udp
  echo -e "${green}Hysteria2 已卸载${re}"
  [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 UDP $port 的放行规则如不再需要, 请手动删除${re}"
}

uninstall_reality() {
  if [[ ! -f "$XRAY_CONF" ]]; then
    echo -e "${yellow}Reality 未安装, 无需卸载${re}"
    return 0
  fi
  local port
  port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
  echo -e "${yellow}将卸载 Reality (停止服务, 删除配置、密钥与程序)${re}"
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  # 先备份: Reality 密钥丢了, 所有已导入的客户端都得重配
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  local _ts; _ts="$(date +%Y%m%d%H%M%S)"
  [[ -f "$XRAY_CONF" ]] && cp -a "$XRAY_CONF" "$BACKUP_DIR/xray-config.json.$_ts" 2>/dev/null \
    && echo -e "${green}已备份配置到 $BACKUP_DIR/xray-config.json.$_ts${re}"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop xray.service 2>/dev/null || true
    systemctl disable xray.service 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  # 归属判断必须提前做: 下面 owned 分支会把 /usr/local/etc/xray 整个删掉,
  # 标记文件随之消失, 事后再判断就会误判成"外部安装"
  local owned=0
  [[ -f "$XRAY_OWNED_MARK" ]] && owned=1
  if [[ "$owned" == "1" ]]; then
    pkill -f "[x]ray run" 2>/dev/null || true
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -f /var/log/xray-reality.log
  else
    # 没标记 = 这份 Xray 不是本脚本装的, 很可能你还拿它跑着别的协议;
    # 这时只动配置和防火墙, 不碰二进制和共享目录
    echo -e "${yellow}未检测到本脚本的安装标记, 判定 Xray 为外部安装${re}"
    echo -e "${yellow}将只删除 Reality 配置: $XRAY_CONF, 保留 xray 程序与 /usr/local/share/xray${re}"
    rm -f "$XRAY_CONF"
    rm -f "${XRAY_CONF}.bak."* 2>/dev/null || true
    rmdir /usr/local/etc/xray 2>/dev/null || true
  fi
  clean_firewall_rule "$port" tcp
  if [[ "$owned" == "1" ]]; then
    echo -e "${green}Reality 已卸载${re}"
  else
    echo -e "${green}Reality 配置已移除 (xray 程序保留)${re}"
  fi
  [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 TCP $port 的放行规则如不再需要, 请手动删除${re}"
}

show_hy2_info() {
  [[ -f "$HY2_CONF" ]] || return 0
  local port passwd
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\(-[0-9][0-9]*\)\{0,1\}\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  passwd=$(sed -n 's/^  password: "\(.*\)"$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_UP_MBPS=$(sed -n 's/^  up: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_DOWN_MBPS=$(sed -n 's/^  down: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  if [[ -z "$port" || -z "$passwd" ]]; then
    echo -e "${red}Hysteria2 配置解析失败${re}"
    return 0
  fi
  get_ip
  print_links "$port" "$passwd"
}

show_reality_info() {
  [[ -f "$XRAY_CONF" ]] || return 0
  local xray_bin="/usr/local/bin/xray"
  if [[ ! -x "$xray_bin" ]]; then
    echo -e "${red}xray 程序缺失, 无法显示 Reality 节点信息${re}"
    return 0
  fi
  local port uuid sni privkey shortid pubkey
  # 下面几条统一用 [[:space:]] 容错, 手工改过 JSON 空格就还能读出来
  port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
  uuid=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  sni=$(grep -oE '"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  privkey=$(grep -oE '"privateKey"[[:space:]]*:[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  shortid=$(grep -oE '"shortIds"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  if [[ -z "$port" || -z "$uuid" || -z "$privkey" ]]; then
    echo -e "${red}Reality 配置解析失败${re}"
    return 0
  fi
  pubkey=$("$xray_bin" x25519 -i "$privkey" 2>/dev/null | awk -F': *' 'tolower($0)~/public/{print $2; exit}' | awk '{print $1}')
  [[ -z "$pubkey" ]] && pubkey=$("$xray_bin" x25519 -i "$privkey" 2>/dev/null | tr -d '\r' | awk '{print $NF}')
  if [[ -z "$pubkey" ]]; then
    echo -e "${red}从私钥推导公钥失败${re}"
    return 0
  fi
  get_ip
  local ip="$HOST_IP" tag="Reality-${HOST_IP}"
  if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    echo -e "${yellow}检测到内网 IP ($ip), 疑似 NAT 机器: 下方链接请把 IP 手动替换为公网 IP${re}"
  fi
  local url="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&headerType=none#${tag}"
  echo ""
  echo -e "${green}========== Reality 节点信息 ==========${re}"
  echo -e "\e[1;36m${url}\e[0m"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" || true
    echo ""
  fi
  echo "--- Clash / Mihomo 配置片段 ---"
  echo "- name: ${tag}"
  echo "  type: vless"
  echo "  server: ${ip}"
  echo "  port: ${port}"
  echo "  uuid: ${uuid}"
  echo "  network: tcp"
  echo "  tls: true"
  echo "  udp: true"
  echo "  flow: xtls-rprx-vision"
  echo "  servername: ${sni}"
  echo "  client-fingerprint: chrome"
  echo "  reality-opts:"
  echo "    public-key: ${pubkey}"
  echo "    short-id: ${shortid}"
  echo ""
}

show_node_info() {
  local found=0
  if [[ -f "$HY2_CONF" ]]; then found=1; show_hy2_info; fi
  if [[ -f "$XRAY_CONF" ]]; then found=1; show_reality_info; fi
  [[ "$found" == "1" ]] || echo -e "${yellow}尚未安装任何协议${re}"
}

# ============================================================================
# 菜单与分发
# ============================================================================
INSTALL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    hy2|reality|uninstall-hy2|uninstall-reality|show) MODE="$arg" ;;
    *) INSTALL_ARGS+=("$arg") ;;
  esac
done

INTERACTIVE=0
[[ "$MODE" == "ask" ]] && INTERACTIVE=1

while true; do
if [[ "$MODE" == "ask" ]]; then
  detect_status
  echo ""
  echo -e "${green}======== HY2 / Reality 管理 (总统开发) ========${re}"
  echo -e "  Hysteria2: ${skyblue}${HY2_STATE}${HY2_DETAIL:+ ($HY2_DETAIL)}${re}"
  echo -e "  Reality:   ${skyblue}${RE_STATE}${RE_DETAIL:+ ($RE_DETAIL)}${re}"
  echo ""
  echo "  1) 安装 Hysteria2  (自动测速调优) [重装会覆盖已有安装]"
  echo "  2) 安装 Reality    (VLESS + Reality) [重装会覆盖已有安装]"
  echo "  3) 查看已安装节点信息"
  echo "  4) 卸载 Hysteria2"
  echo "  5) 卸载 Reality"
  echo "  0) 退出"
  echo -e "${green}====================================${re}"
  echo -e "  ${yellow}提示：按 README 设置快捷命令后，下次直接输入 hy2 即可进入本菜单${re}"
  read -r -p "输入序号 [1/2/3/4/5/0]: " _c </dev/tty
  case "$_c" in
    1) MODE=hy2 ;;
    2) MODE=reality ;;
    3) MODE=show ;;
    4) MODE=uninstall-hy2 ;;
    5) MODE=uninstall-reality ;;
    0) echo "已退出"; exit 0 ;;
    *) die "无效选择" ;;
  esac
fi

case "$MODE" in
  hy2)               run_hy2 "${INSTALL_ARGS[@]}" ;;
  reality)           run_reality ;;
  uninstall-hy2)     uninstall_hy2 ;;
  uninstall-reality) uninstall_reality ;;
  show)              show_node_info ;;
  *)                 die "MODE 非法: $MODE (可选 ask/hy2/reality/uninstall-hy2/uninstall-reality/show)" ;;
esac

[[ "$INTERACTIVE" == "1" ]] || break
echo ""
read -n1 -s -r -p "按任意键返回主菜单... " _dummy </dev/tty
echo ""
MODE=ask
done
)
