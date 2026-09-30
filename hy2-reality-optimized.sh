#!/bin/bash
# ============================================================================
# hy2-reality-optimized.sh — Hysteria2 + Reality 二合一安装脚本 (优化版)
#
# 相对原版新增/改进:
#   - 系统级网络调优 (菜单单独执行，安装时不强制)
#   - HY2 多源测速；可选端口跳跃 (官方 listen: :start-end 内置范围)
#   - 防火墙 nftables/ufw/firewalld（跳跃时放行整段 UDP）
#   - Reality 指纹可选；双 shortId；重装复用 UUID/密钥/shortId
#   - HY2 重装复用密码；二维码；节点信息 /root/node-info.txt
#
# 用法:
#   bash hy2-reality-optimized.sh
#   bash hy2-reality-optimized.sh hy2
#   HY2_HOP=1 bash hy2-reality-optimized.sh hy2          # 端口跳跃
#   HY2_HOP=1 HY2_HOP_PORTS=20000-30000 bash ... hy2
#   bash hy2-reality-optimized.sh reality
#   bash hy2-reality-optimized.sh sysopt
#
# 可调选项:
#   HY2_PORT / HY2_HOP / HY2_HOP_PORTS / HY2_HOP_INTERVAL / HY2_MASQUERADE
#   REALITY_PORT / REALITY_SNI / REALITY_DEST / REALITY_UUID / REALITY_FP
#   XRAY_VERSION=""                # 非空则安装指定 Xray 版本 (如 v25.9.11)
# ============================================================================
(
export LANG=en_US.UTF-8

# ---------- 共享: 颜色与输出 ----------
re='\e[0m'; red='\e[1;91m'; green='\e[1;32m'; yellow='\e[1;33m'; skyblue='\e[1;96m'; cyan='\e[1;36m'
die()  { echo -e "${red}[错误] $*${re}" >&2; exit 1; }
info() { echo -e "${green}[信息] $*${re}"; }
warn() { echo -e "${yellow}[警告] $*${re}" >&2; }

# ---------- 可调选项 ----------
MODE="${MODE:-ask}"
HY2_PORT="${HY2_PORT:-8443}"
HY2_HOP="${HY2_HOP:-0}"
HY2_HOP_PORTS="${HY2_HOP_PORTS:-20000-50000}"
HY2_HOP_INTERVAL="${HY2_HOP_INTERVAL:-30}"
HY2_MASQUERADE="${HY2_MASQUERADE:-bing.com}"
SKIP_BANDWIDTH="${SKIP_BANDWIDTH:-0}"
MEASURE_ONLY="${MEASURE_ONLY:-0}"
RUNS=3
SAFETY="0.8"
MIN_MBPS=5
UP_TEST_MB=10
REALITY_PORT="${REALITY_PORT:-8880}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_UUID="${REALITY_UUID:-}"
REALITY_FP="${REALITY_FP:-chrome}"
XRAY_VERSION="${XRAY_VERSION:-}"

NODE_INFO_FILE="/root/node-info.txt"
BACKUP_DIR="/root/hy2-reality-backup"
XRAY_OWNED_MARK="/usr/local/etc/xray/.hy2-reality-owned"

[[ $EUID -ne 0 ]] && die "请在 root 用户下运行脚本"

# ============================================================================
# 公共函数
# ============================================================================
get_ip() {
  HOST_IP=""
  for url in "https://ipv4.ip.sb" "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    HOST_IP=$(curl -4 -fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
    [[ -n "$HOST_IP" && "$HOST_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    HOST_IP=""
  done
  # IPv6 兜底（与上面 IPv4 源区分，避免重复打同一地址）
  if [[ -z "$HOST_IP" ]]; then
    HOST_IP=$(curl -6 -fsS --max-time 4 https://ipv6.ip.sb 2>/dev/null | tr -d '[:space:]' || true)
  fi
  if [[ -z "$HOST_IP" ]] && command -v ip &>/dev/null; then
    HOST_IP=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1 || true)
  fi
  [[ -z "$HOST_IP" ]] && HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -z "$HOST_IP" ]] && { echo -e "${red}无法获取公网 IP${re}"; return 1; }
  return 0
}

# 保存节点信息到文件
save_node_info() {
  local content="$1"
  {
    echo "========== $(date '+%Y-%m-%d %H:%M:%S') =========="
    echo "$content"
    echo ""
  } >> "$NODE_INFO_FILE"
  info "节点信息已追加保存到 $NODE_INFO_FILE"
}

# ---------- 防火墙 (支持 ufw / firewalld / nftables；port 可为单端口或 start:end) ----------
open_firewall() {
  local port=$1 proto=$2   # proto = udp | tcp；port 支持 8443 或 20000:50000
  local ok=0
  local ufw_port="$port" fw_port="$port"
  # ufw/firewalld 范围用 start:end
  if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    ufw_port="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    fw_port="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  elif [[ "$port" =~ ^([0-9]+):([0-9]+)$ ]]; then
    ufw_port="$port"
    fw_port="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${ufw_port}/${proto}" >/dev/null 2>&1 && info "ufw 已放行 ${ufw_port}/$proto" && ok=1
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    if firewall-cmd --permanent --add-port="${fw_port}/${proto}" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
      info "firewalld 已放行 ${fw_port}/$proto"
      ok=1
    fi
  fi

  # nftables：单端口精确匹配；范围用 dport >= start and dport <= end
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'table'; then
    local p1 p2
    if [[ "$port" =~ ^([0-9]+)[:-]([0-9]+)$ ]]; then
      p1="${BASH_REMATCH[1]}"; p2="${BASH_REMATCH[2]}"
      if nft list chain inet filter input &>/dev/null; then
        nft add rule inet filter input "$proto" dport "{$p1-$p2}" accept 2>/dev/null \
          && info "nftables 已放行 ${p1}-${p2}/$proto" && ok=1
      elif nft list chain ip filter INPUT &>/dev/null; then
        nft add rule ip filter INPUT "$proto" dport "{$p1-$p2}" accept 2>/dev/null \
          && info "nftables 已放行 ${p1}-${p2}/$proto" && ok=1
      fi
    else
      if nft list chain inet filter input &>/dev/null; then
        if nft list chain inet filter input 2>/dev/null | grep -qE "dport[[:space:]]+$port[[:space:]]"; then
          info "nftables 已存在 $port/$proto 规则"; ok=1
        else
          nft add rule inet filter input "$proto" dport "$port" accept 2>/dev/null && info "nftables 已放行 $port/$proto" && ok=1
        fi
      elif nft list chain ip filter INPUT &>/dev/null; then
        if nft list chain ip filter INPUT 2>/dev/null | grep -qE "dport[[:space:]]+$port[[:space:]]"; then
          info "nftables 已存在 $port/$proto 规则"; ok=1
        else
          nft add rule ip filter INPUT "$proto" dport "$port" accept 2>/dev/null && info "nftables 已放行 $port/$proto" && ok=1
        fi
      fi
    fi
  fi

  if [[ "$ok" -eq 0 ]]; then
    warn "未检测到可自动配置的本机防火墙；云厂商安全组请手动放行 $proto $port"
  fi
}

clean_firewall_rule() {
  local port=$1 proto=$2
  [[ -n "$port" ]] || return 0
  local ufw_port="$port" fw_port="$port"
  if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    ufw_port="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    fw_port="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  elif [[ "$port" =~ ^([0-9]+):([0-9]+)$ ]]; then
    ufw_port="$port"
    fw_port="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "${ufw_port}/${proto}" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --remove-port="${fw_port}/${proto}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1; then
    local h
    if nft list chain inet filter input &>/dev/null; then
      for h in $(nft -a list chain inet filter input 2>/dev/null | grep -E "dport" | grep -E "$port|${port//-/:}" | grep -oE 'handle[[:space:]]+[0-9]+' | awk '{print $2}'); do
        nft delete rule inet filter input handle "$h" 2>/dev/null || true
      done
    elif nft list chain ip filter INPUT &>/dev/null; then
      for h in $(nft -a list chain ip filter INPUT 2>/dev/null | grep -E "dport" | grep -E "$port|${port//-/:}" | grep -oE 'handle[[:space:]]+[0-9]+' | awk '{print $2}'); do
        nft delete rule ip filter INPUT handle "$h" 2>/dev/null || true
      done
    fi
  fi
}

# ---------- 系统级网络调优 (BBR + fq + 缓冲区) ----------
sys_network_optimize() {
  info "开始系统网络调优..."

  # 加载模块
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true

  # 检查内核是否支持 BBR
  local has_bbr=0
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    has_bbr=1
  fi

  # 写入 sysctl 配置
  local conf="/etc/sysctl.d/99-hy2-reality-optimize.conf"
  cat > "$conf" <<'SYSCTL'
# hy2-reality optimized network settings
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
SYSCTL

  if [[ "$has_bbr" -eq 0 ]]; then
    # 无 BBR 时改用 cubic，仍保留其他优化
    sed -i 's/net.ipv4.tcp_congestion_control = bbr/net.ipv4.tcp_congestion_control = cubic/' "$conf"
    warn "当前内核不支持 BBR，已降级为 cubic，其余参数仍已优化"
  fi

  sysctl -p "$conf" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  local qdisc
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  info "网络调优完成: congestion=$cc  qdisc=$qdisc"
  info "配置已写入 $conf"
}

# ============================================================================
# HY2 部分
# ============================================================================
run_hy2() (
set -eo pipefail

install_deps() {
  local cmd
  for cmd in curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    warn "正在安装 $cmd ..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$cmd"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q "$cmd"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q "$cmd"
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "$cmd"
    else
      die "不支持的系统"
    fi
  done
  # 可选工具包（命令名与包名可能不同，失败忽略）
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gawk iproute2 coreutils qrencode 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q gawk iproute coreutils qrencode 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q gawk iproute coreutils qrencode 2>/dev/null || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache gawk iproute2 coreutils qrencode 2>/dev/null || true
  fi
}

median_bps() {
  local sorted n mid
  # 全部测速失败: 直接返回 0（避免空数组 printf 产生空行导致 n!=0）
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

to_mbps() {
  awk "BEGIN{printf \"%.1f\", $1*8/1000000}"
}

# 多源下载测速（小文件，降低流量；curl 失败不触发 set -e）
measure_down() {
  local speeds=() s i url
  local sources=(
    "http://cachefly.cachefly.net/10mb.test"
    "https://speed.cloudflare.com/__down?bytes=10000000"
    "http://speedtest.tele2.net/10MB.zip"
  )
  for i in $(seq 1 "$RUNS"); do
    s=""
    for url in "${sources[@]}"; do
      s=$(curl -4 -o /dev/null -s -w '%{speed_download}' --max-time 25 --connect-timeout 8 "$url" 2>/dev/null || true)
      s=${s%.*}
      if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 100000 ]; then
        break
      fi
      s=""
    done
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
      speeds+=("$s")
      echo -e "${skyblue}  下载测试 $i/$RUNS: $(to_mbps "$s") Mbps${re}" >&2
    else
      echo -e "${skyblue}  下载测试 $i/$RUNS: 失败${re}" >&2
    fi
  done
  median_bps "${speeds[@]}"
}

measure_up() {
  # 注意: 测速会把本机出口 IP + ${UP_TEST_MB}MB×${RUNS} 上传数据发给 speed.cloudflare.com 等第三方
  local speeds=() s i url
  local up_urls=(
    "https://speed.cloudflare.com/__up"
    "https://upload.cloudflare.com/"
  )
  dd if=/dev/urandom of=/tmp/hy2up_test bs=1M count="$UP_TEST_MB" 2>/dev/null || true
  for i in $(seq 1 "$RUNS"); do
    s=""
    for url in "${up_urls[@]}"; do
      s=$(curl -4 -s -o /dev/null -w '%{speed_upload}' --max-time 35 --connect-timeout 8 \
        -X POST --data-binary @/tmp/hy2up_test "$url" 2>/dev/null || true)
      s=${s%.*}
      if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
        break
      fi
      s=""
    done
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

decide_mbps() {
  local mbps
  mbps=$(awk -v b="${1:-0}" -v s="$SAFETY" 'BEGIN{v=b*8/1000000*s; if(v<0)v=0; printf "%d", v}')
  echo "$mbps"
}

do_measure() {
  echo -e "${yellow}正在多源测速 (下载/上传各 $RUNS 次, 取中位数 × $SAFETY 保守系数)...${re}"
  DOWN_BPS=$(measure_down)
  UP_BPS=$(measure_up)
  echo -e "${green}实测中位数: 下载 $(to_mbps "${DOWN_BPS:-0}") Mbps / 上传 $(to_mbps "${UP_BPS:-0}") Mbps${re}"
  if [ -z "$DOWN_BPS" ] || [ -z "$UP_BPS" ] || [ "$DOWN_BPS" -eq 0 ] || [ "$UP_BPS" -eq 0 ]; then
    echo -e "${red}测速失败, 无法决定带宽参数${re}"
    return 1
  fi
  CFG_UP_MBPS=$(decide_mbps "$UP_BPS")
  CFG_DOWN_MBPS=$(decide_mbps "$DOWN_BPS")
  # 过低硬写 Brutal 会高于真实带宽导致丢包，改为不写 bandwidth 走 BBR
  if [ "$CFG_UP_MBPS" -lt "$MIN_MBPS" ] || [ "$CFG_DOWN_MBPS" -lt "$MIN_MBPS" ]; then
    echo -e "${yellow}实测带宽低于 ${MIN_MBPS} Mbps, 不启用 Brutal(硬写会丢包), 改用 BBR${re}"
    CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
  else
    echo -e "${green}决定参数: bandwidth.up = ${CFG_UP_MBPS} mbps, bandwidth.down = ${CFG_DOWN_MBPS} mbps${re}"
  fi
  return 0
}

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

# 解析跳跃范围，校验格式；成功则设置 HOP_START/HOP_END
parse_hop_ports() {
  HOP_START=""; HOP_END=""
  [[ "$HY2_HOP_PORTS" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
  HOP_START="${BASH_REMATCH[1]}"
  HOP_END="${BASH_REMATCH[2]}"
  [[ "$HOP_START" -lt "$HOP_END" ]] || return 1
  [[ "$HOP_START" -ge 1024 && "$HOP_END" -le 65535 ]] || return 1
  return 0
}

pick_port() {
  # 端口跳跃：使用 HY2_HOP_PORTS 范围，listen 首端口为实际绑定端口
  if [[ "$HY2_HOP" == "1" ]]; then
    parse_hop_ports || die "HY2_HOP_PORTS 格式无效，应为 start-end，例如 20000-50000"
    if ! command -v iptables >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
      die "端口跳跃需要本机有 iptables 或 nftables（官方内置转发依赖它们）"
    fi
    # 首端口被非 hysteria 占用则失败，避免假成功
    if ss -ulpn 2>/dev/null | grep -qE "[:.]$HOP_START[[:space:]]"; then
      if ! ss -ulpn 2>/dev/null | grep -E "[:.]$HOP_START[[:space:]]" | grep -q hysteria; then
        die "端口跳跃首端口 $HOP_START 已被其他进程占用，请换 HY2_HOP_PORTS 或释放该端口"
      fi
    fi
    echo "$HOP_START"
    return 0
  fi
  local p="$HY2_PORT"
  if [[ -f /etc/hysteria/config.yaml ]]; then
    local old_p
    old_p=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)
    # 旧配置若是范围 listen: :20000-50000，取起始端口
    [[ -z "$old_p" ]] && old_p=$(sed -n 's/^listen: :\([0-9][0-9]*\)-[0-9][0-9]*.*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)
    [[ -n "$old_p" ]] && p="$old_p"
  fi
  if ss -ulpn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
    if ! ss -ulpn 2>/dev/null | grep -E "[:.]$p[[:space:]]" | grep -q hysteria; then
      local np
      np=$(shuf -i 20000-60000 -n 1)
      warn "端口 $p 被占用, 改用随机端口 $np" >&2
      p="$np"
    fi
  fi
  echo "$p"
}

install_hy2() {
  echo -e "${yellow}正在安装 Hysteria2 ...${re}"
  # 注意: 这是远程官方脚本 (get.hy2.sh), 本地不做校验; 介意请先手动审阅再执行
  bash <(curl -fsSL https://get.hy2.sh/) >/tmp/hy2install.log 2>&1 \
    && info "Hysteria2 安装成功" \
    || { echo -e "${red}安装失败, 日志:${re}"; tail -20 /tmp/hy2install.log; exit 1; }
}

gen_cert() {
  mkdir -p /etc/hysteria
  if [[ -f /etc/hysteria/server.crt && -f /etc/hysteria/server.key ]]; then
    info "复用已有证书"
    return 0
  fi
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=${HY2_MASQUERADE}" -days 36500 2>/dev/null \
    && info "自签证书已生成 (CN=${HY2_MASQUERADE})"
  chmod 600 /etc/hysteria/server.key
}

write_config() {
  local port=$1 passwd=$2
  if [[ -f /etc/hysteria/config.yaml ]]; then
    mkdir -p "$BACKUP_DIR"
    local bak="$BACKUP_DIR/hysteria-config.$(date +%Y%m%d%H%M%S).yaml"
    cp -a /etc/hysteria/config.yaml "$bak"
    info "已备份旧配置到 $bak"
  fi

  # 端口跳跃：官方 Linux 内置 listen 范围，由 hy2 自动用 iptables/nft 转发
  local listen_line=":$port"
  if [[ "$HY2_HOP" == "1" ]]; then
    parse_hop_ports || die "HY2_HOP_PORTS 无效"
    listen_line=":${HOP_START}-${HOP_END}"
    info "端口跳跃已启用: listen ${listen_line}（hy2 将自动配置内核转发）"
  fi

  {
    echo "listen: $listen_line"
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
    echo "    url: https://${HY2_MASQUERADE}"
    echo "    rewriteHost: true"
  } > /etc/hysteria/config.yaml
  chmod 600 /etc/hysteria/config.yaml
  id hysteria >/dev/null 2>&1 && chown -R hysteria:hysteria /etc/hysteria
  info "配置文件已写入"
}

# 端口跳跃需要 hy2 能改防火墙；给 systemd 单元补 CAP_NET_ADMIN
ensure_hy2_porthop_caps() {
  local drop_dir="/etc/systemd/system/hysteria-server.service.d"
  local drop_file="$drop_dir/99-porthop.conf"
  if [[ "$HY2_HOP" != "1" ]]; then
    # 非跳跃模式：不强制保留 drop-in（若存在也不删，避免误伤用户手改）
    return 0
  fi
  mkdir -p "$drop_dir"
  cat > "$drop_file" <<'EOF'
[Service]
# Hysteria2 官方端口范围依赖进程配置 iptables/nft 转发
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
EOF
  info "已为 hysteria-server 添加 CAP_NET_ADMIN（端口跳跃所需）"
}

start_service() {
  ensure_hy2_porthop_caps
  systemctl daemon-reload
  systemctl enable hysteria-server.service >/dev/null 2>&1
  systemctl restart hysteria-server.service
  sleep 3
  if [ "$(systemctl is-active hysteria-server.service)" = "active" ]; then
    info "服务运行中"
  else
    die "服务启动失败, 请检查: journalctl -u hysteria-server -n 50"
  fi
  # 跳跃模式：确认首端口在听，避免「active 但未监听」假成功
  if [[ "$HY2_HOP" == "1" ]]; then
    parse_hop_ports || true
    local i ok=0
    for i in 1 2 3 4 5; do
      if ss -ulpn 2>/dev/null | grep -qE "[:.]$HOP_START[[:space:]]"; then
        ok=1
        break
      fi
      sleep 1
    done
    if [[ "$ok" -ne 1 ]]; then
      die "端口跳跃已配置但未监听到 UDP $HOP_START，请检查: journalctl -u hysteria-server -n 50"
    fi
    info "已确认监听 UDP $HOP_START（范围 ${HOP_START}-${HOP_END} 由 hy2 内核转发）"
  fi
}

print_links() {
  local port=$1 passwd=$2
  local tag="HY2-${HOST_IP}"
  local url port_display sg_hint clash_ports clash_hop
  port_display="$port"
  sg_hint="UDP $port"
  clash_ports=""
  clash_hop=""
  if [[ "$HY2_HOP" == "1" ]]; then
    parse_hop_ports || true
    port_display="${HOP_START}-${HOP_END}"
    sg_hint="UDP ${HOP_START}-${HOP_END}"
    # 分享链接：主端口用范围首端口，mport 告知客户端可跳跃范围
    url="hysteria2://$passwd@$HOST_IP:${HOP_START}/?sni=${HY2_MASQUERADE}&alpn=h3&insecure=1&mport=${HOP_START}-${HOP_END}#$tag"
    clash_ports="  ports: ${HOP_START}-${HOP_END}"
    clash_hop="  hop-interval: ${HY2_HOP_INTERVAL}"
  else
    url="hysteria2://$passwd@$HOST_IP:$port/?sni=${HY2_MASQUERADE}&alpn=h3&insecure=1#$tag"
  fi

  local out=""
  out+="========== HY2 节点信息 ==========
端口: $port_display  密码: $passwd
"
  if [[ "$HY2_HOP" == "1" ]]; then
    out+="端口跳跃: 已启用 (listen :${HOP_START}-${HOP_END}, hop-interval 建议 ${HY2_HOP_INTERVAL}s)
"
  fi
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    out+="带宽: up ${CFG_UP_MBPS} Mbps / down ${CFG_DOWN_MBPS} Mbps (Brutal 已启用)
"
  else
    out+="未设置带宽参数, 当前为 BBR 模式
"
  fi
  out+="
--- V2rayN / Nekobox / Streisand ---
$url

--- Clash / Mihomo ---
- name: $tag
  type: hysteria2
  server: $HOST_IP
  port: $port
  password: $passwd
"
  [[ -n "$clash_ports" ]] && out+="$clash_ports
$clash_hop
"
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    out+="  up: \"${CFG_UP_MBPS} Mbps\"
  down: \"${CFG_DOWN_MBPS} Mbps\"
"
  fi
  out+="  sni: ${HY2_MASQUERADE}
  alpn:
    - h3
  skip-cert-verify: true

注意: 云厂商安全组需手动放行 $sg_hint
"

  echo ""
  echo -e "${green}========== HY2 节点信息 ==========${re}"
  echo -e "端口: ${skyblue}$port_display${re}  密码: ${skyblue}$passwd${re}"
  if [[ "$HY2_HOP" == "1" ]]; then
    echo -e "端口跳跃: ${skyblue}已启用${re} (官方 listen :${HOP_START}-${HOP_END})"
    echo -e "客户端 hop-interval 建议: ${skyblue}${HY2_HOP_INTERVAL}s${re}"
  fi
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    # 注: 服务端单边 bandwidth 主要约束发出方向; 客户端可在 Clash 节点加 up/down
    echo -e "带宽: up ${CFG_UP_MBPS} Mbps / down ${CFG_DOWN_MBPS} Mbps (Brutal 已启用)"
  else
    echo -e "${yellow}未设置带宽参数, 当前为 BBR 模式${re}"
  fi
  echo ""
  echo -e "${yellow}--- V2rayN / Nekobox / Streisand ---${re}"
  echo -e "${cyan}${url}${re}"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" 2>/dev/null || true
    echo ""
  fi
  echo -e "${yellow}--- Clash / Mihomo ---${re}"
  echo "- name: $tag"
  echo "  type: hysteria2"
  echo "  server: $HOST_IP"
  echo "  port: $port"
  echo "  password: $passwd"
  if [[ "$HY2_HOP" == "1" ]]; then
    echo "  ports: ${HOP_START}-${HOP_END}"
    echo "  hop-interval: ${HY2_HOP_INTERVAL}"
  fi
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo "  up: \"${CFG_UP_MBPS} Mbps\""
    echo "  down: \"${CFG_DOWN_MBPS} Mbps\""
  fi
  echo "  sni: ${HY2_MASQUERADE}"
  echo "  alpn:"
  echo "    - h3"
  echo "  skip-cert-verify: true"
  echo ""
  echo -e "${red}注意: 云厂商安全组需手动放行 $sg_hint${re}"

  save_node_info "$out"
}

# ---- HY2 主流程 ----
for arg in "$@"; do
  case "$arg" in
    --measure-only) MEASURE_ONLY=1 ;;
    --no-bandwidth) SKIP_BANDWIDTH=1 ;;
  esac
done

install_deps

if [[ "$MEASURE_ONLY" == "1" ]]; then
  do_measure || true
  exit 0
fi

echo -e "${yellow}=== 第 1 步: 测速并决定带宽参数 ===${re}"
if [[ "$SKIP_BANDWIDTH" == "1" ]]; then
  echo -e "${yellow}已跳过测速与带宽参数, 使用 BBR 模式安装${re}"
  CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
else
  while true; do
    if do_measure; then
      echo -e "${green}将启用 Brutal 拥塞控制${re}"
      break
    fi
    ask_on_measure_fail
    ret=$?
    if [[ $ret -eq 1 ]]; then
      echo -e "${yellow}降级为 BBR 模式继续安装${re}"
      CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
      break
    fi
    # ret=2 重新测速
  done
fi

PORT=$(pick_port)
# 重装时复用旧密码，避免老客户端失效
PASSWD=""
if [[ -f /etc/hysteria/config.yaml ]]; then
  PASSWD=$(sed -n 's/^  password: "\(.*\)"$/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)
  [[ -n "$PASSWD" ]] && info "复用已有 Hysteria2 密码"
fi
if [[ -z "$PASSWD" ]]; then
  PASSWD=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
fi

install_hy2
gen_cert
write_config "$PORT" "$PASSWD"
start_service
if [[ "$HY2_HOP" == "1" ]]; then
  parse_hop_ports || die "HY2_HOP_PORTS 无效"
  open_firewall "${HOP_START}-${HOP_END}" udp
  warn "云厂商安全组请手动放行 UDP ${HOP_START}-${HOP_END}"
else
  open_firewall "$PORT" udp
fi

get_ip || die "无法获取公网 IP"
print_links "$PORT" "$PASSWD"
)

# ============================================================================
# Reality 部分
# ============================================================================
run_reality() (
set -eo pipefail

XRAY_BIN="/usr/local/bin/xray"
CONFIG_FILE="/usr/local/etc/xray/config.json"
PORT="$REALITY_PORT"
SNI="$REALITY_SNI"
DEST="${REALITY_DEST:-${SNI}:443}"
UUID="$REALITY_UUID"
FP="$REALITY_FP"

install_deps() {
  local missing=""
  for cmd in curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  [[ -z "$missing" ]] && return 0
  warn "正在安装依赖:$missing"
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq $missing || die "依赖安装失败:$missing"
  elif command -v dnf &>/dev/null; then
    dnf install -y -q $missing || die "依赖安装失败:$missing"
  elif command -v yum &>/dev/null; then
    yum install -y -q $missing || die "依赖安装失败:$missing"
  elif command -v apk &>/dev/null; then
    apk add $missing || die "依赖安装失败:$missing"
  else
    die "暂不支持的系统"
  fi
  if ! command -v qrencode >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y -qq qrencode 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q qrencode 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then yum install -y -q qrencode 2>/dev/null || true
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache qrencode 2>/dev/null || true
    fi
  fi
}

install_xray() {
  if [[ -x "$XRAY_BIN" ]]; then
    if [[ -f "$XRAY_OWNED_MARK" ]]; then
      info "检测到本脚本安装的 Xray，跳过安装步骤"
    else
      info "检测到 Xray 已安装(非本脚本安装), 跳过; 卸载时不会删除该二进制"
    fi
    return 0
  fi
  info "正在安装 Xray..."
  # 注意: 执行 GitHub 下载的官方安装脚本, 本地不做内容校验
  local installer
  installer="$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
    || die "下载 Xray 安装脚本失败"
  if [[ -n "${XRAY_VERSION:-}" ]]; then
    bash -c "$installer" @ install --version "$XRAY_VERSION" || die "Xray 安装失败"
  else
    bash -c "$installer" @ install || die "Xray 安装失败"
  fi
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装后仍找不到二进制文件: $XRAY_BIN"
  mkdir -p "$(dirname "$XRAY_OWNED_MARK")"
  touch "$XRAY_OWNED_MARK"
  info "已标记 Xray 为本脚本安装 ($XRAY_OWNED_MARK)"
}

# 重装时复用旧配置端口，保证老客户端链接中的 port 仍有效
resolve_port() {
  if [[ -f "$CONFIG_FILE" ]]; then
    local old_port
    old_port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    if [[ -n "$old_port" ]]; then
      PORT="$old_port"
      info "复用已有 Reality 端口 $PORT"
      return 0
    fi
  fi
}

check_port() {
  # 已有配置则端口已在 resolve_port 中复用，不再随机改掉
  [[ -f "$CONFIG_FILE" ]] && return 0
  if ss -tlnp 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
    warn "端口 $PORT 已被占用，改用随机端口"
    PORT="$(shuf -i 20000-60000 -n 1)"
    info "新端口: $PORT"
  fi
}

resolve_uuid() {
  if [[ -z "$UUID" && -f "$CONFIG_FILE" ]]; then
    UUID="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    [[ -n "$UUID" ]] && info "复用旧配置中的 UUID，老客户端不受影响"
  fi
  if [[ -z "$UUID" ]]; then
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')"
  fi
  [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "无法获得合法的 UUID"
}

gen_keys() {
  local out keys
  # 重装时复用旧 privateKey / shortIds，保证老客户端 pbk/sid 不变
  if [[ -f "$CONFIG_FILE" ]]; then
    RE_PRIVATE_KEY="$(grep -oE '"privateKey"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'"' -f4 || true)"
    SHORT_ID1="$(grep -oE '"shortIds"[[:space:]]*:[[:space:]]*\[[^]]+\]' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -oE '[0-9a-fA-F]{2,16}' | head -1 || true)"
    SHORT_ID2="$(grep -oE '"shortIds"[[:space:]]*:[[:space:]]*\[[^]]+\]' "$CONFIG_FILE" 2>/dev/null | head -1 | grep -oE '[0-9a-fA-F]{2,16}' | sed -n '2p' || true)"
    if [[ -n "$RE_PRIVATE_KEY" ]]; then
      RE_PUBLIC_KEY="$("$XRAY_BIN" x25519 -i "$RE_PRIVATE_KEY" 2>/dev/null | awk -F': *' 'tolower($1)~/pub/ || tolower($1)~/password/ {print $2; exit}' | awk '{print $1}' || true)"
      [[ -z "$RE_PUBLIC_KEY" ]] && RE_PUBLIC_KEY="$("$XRAY_BIN" x25519 -i "$RE_PRIVATE_KEY" 2>/dev/null | grep -oE '[A-Za-z0-9_-]{43}' | head -1 || true)"
    fi
    if [[ -n "$RE_PRIVATE_KEY" && -n "$RE_PUBLIC_KEY" ]]; then
      [[ -z "$SHORT_ID1" ]] && SHORT_ID1="$(openssl rand -hex 8)"
      [[ -z "$SHORT_ID2" ]] && SHORT_ID2="$(openssl rand -hex 8)"
      SHORT_ID="$SHORT_ID1"
      info "复用旧 Reality 密钥与 shortId, 老客户端不需要更新"
      return 0
    fi
  fi
  out="$("$XRAY_BIN" x25519 | tr -d '\r')" || die "执行 xray x25519 失败"
  RE_PRIVATE_KEY="$(awk -F': *' 'tolower($1)~/private/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
  RE_PUBLIC_KEY="$(awk -F': *' 'tolower($1)~/pub/ || tolower($1)~/password/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
  if [[ -z "$RE_PRIVATE_KEY" || -z "$RE_PUBLIC_KEY" ]]; then
    # 兜底: x25519 常见输出为 43 位 base64url，私钥在前、公钥在后
    keys=$(grep -oE '[A-Za-z0-9_-]{43}' <<<"$out" || true)
    RE_PRIVATE_KEY="$(sed -n '1p' <<<"$keys")"
    RE_PUBLIC_KEY="$(sed -n '2p' <<<"$keys")"
  fi
  [[ -n "$RE_PRIVATE_KEY" && -n "$RE_PUBLIC_KEY" ]] || die "密钥解析失败，xray 输出异常: $out"
  SHORT_ID1="$(openssl rand -hex 8)"
  SHORT_ID2="$(openssl rand -hex 8)"
  SHORT_ID="$SHORT_ID1"
}

write_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    mkdir -p "$BACKUP_DIR"
    local bak="$BACKUP_DIR/xray-config.$(date +%Y%m%d%H%M%S).json"
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
                    "shortIds": ["$SHORT_ID1", "$SHORT_ID2"]
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

get_ip_local() {
  local ip
  for url in "https://ipv4.ip.sb" "https://api.ipify.org" "https://ifconfig.me/ip"; do
    ip=$(curl -4 -fsS --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
  done
  ip=$(curl -fsS --max-time 3 https://ipv6.ip.sb 2>/dev/null | tr -d '[:space:]')
  [[ -n "$ip" ]] && { echo "[$ip]"; return 0; }
  if command -v ip &>/dev/null; then
    ip=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  fi
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  return 1
}

get_tag() {
  local json tag=""
  json="$(curl -fsS --max-time 3 "https://api.ip.sb/geoip" 2>/dev/null)" || json=""
  if [[ -n "$json" ]]; then
    tag="$(awk -F'"' '{for(i=1;i<NF;i++){if($i=="country_code")c=$(i+2);if($i=="isp")s=$(i+2)}} END{if(c&&s)print c"-"s}' <<<"$json")"
  fi
  [[ -z "$tag" ]] && tag="reality"
  tag="$(sed 's/ /_/g' <<<"$tag" | tr -cd '[:alnum:]_.-')"
  [[ -z "$tag" ]] && tag="reality"
  echo "$tag"
}

print_link() {
  local ip tag url
  ip="$(get_ip_local)" || die "无法获取服务器公网 IP"
  if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    warn "检测到内网 IP ($ip)，疑似 NAT 机器：下方链接不可直接使用，请把链接中的 IP 手动替换为公网 IP"
  fi
  tag="$(get_tag)"
  url="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FP}&pbk=${RE_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${tag}"

  local out=""
  out+="========== Reality 节点信息 ==========
链接: $url
端口: $PORT
UUID: $UUID
SNI: $SNI
Fingerprint: $FP
PublicKey: $RE_PUBLIC_KEY
ShortId: $SHORT_ID1 / $SHORT_ID2

--- Clash / Mihomo ---
- name: ${tag}
  type: vless
  server: ${ip}
  port: ${PORT}
  uuid: ${UUID}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${SNI}
  client-fingerprint: ${FP}
  reality-opts:
    public-key: ${RE_PUBLIC_KEY}
    short-id: ${SHORT_ID}
"

  echo ""
  info "Reality 安装成功，客户端导入链接："
  echo -e "${cyan}${url}${re}"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" 2>/dev/null || warn "二维码生成失败"
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
  echo "  client-fingerprint: ${FP}"
  echo "  reality-opts:"
  echo "    public-key: ${RE_PUBLIC_KEY}"
  echo "    short-id: ${SHORT_ID}"
  echo ""
  echo -e "Fingerprint: ${skyblue}${FP}${re}  ShortIds: ${skyblue}${SHORT_ID1}, ${SHORT_ID2}${re}"
  echo ""

  save_node_info "$out"
}

# ---- Reality 主流程 ----
install_deps
install_xray
resolve_port
check_port
resolve_uuid
gen_keys
write_config
start_service
open_firewall "$PORT" tcp
print_link
)

# ============================================================================
# 安装状态探测与卸载
# ============================================================================
HY2_CONF="/etc/hysteria/config.yaml"
XRAY_CONF="/usr/local/etc/xray/config.json"

detect_status() {
  HY2_STATE="未安装"; HY2_DETAIL=""
  if [[ -f "$HY2_CONF" ]]; then
    local p
    p=$(sed -n 's/^listen: :\([0-9][0-9]*-[0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
    [[ -z "$p" ]] && p=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
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
    p=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    RE_STATE="已安装"; RE_DETAIL="TCP ${p:-未知端口}"
    if systemctl is-active --quiet xray.service 2>/dev/null; then
      RE_DETAIL="$RE_DETAIL, 运行中"
    else
      RE_DETAIL="$RE_DETAIL, 未运行"
    fi
  fi
}

uninstall_hy2() {
  if [[ ! -f "$HY2_CONF" ]]; then
    echo -e "${yellow}Hysteria2 未安装, 无需卸载${re}"
    return 0
  fi
  local port range_p
  range_p=$(sed -n 's/^listen: :\([0-9][0-9]*-[0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  echo -e "${yellow}将卸载 Hysteria2 (停止服务, 删除本脚本生成的配置/证书/程序)${re}"
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  systemctl stop hysteria-server.service 2>/dev/null || true
  systemctl disable hysteria-server.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-server.service
  rm -rf /etc/systemd/system/hysteria-server.service.d
  mkdir -p "$BACKUP_DIR"
  tar -czf "$BACKUP_DIR/hysteria-$(date +%Y%m%d%H%M%S).tar.gz" -C / etc/hysteria 2>/dev/null \
    || warn "备份 /etc/hysteria 失败, 继续删除"
  rm -f /usr/local/bin/hysteria
  # 只删脚本生成的文件，目录非空则保留（避免误删用户自有文件）
  rm -f /etc/hysteria/config.yaml /etc/hysteria/server.crt /etc/hysteria/server.key
  rmdir /etc/hysteria 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  if [[ -n "$range_p" ]]; then
    clean_firewall_rule "$range_p" udp
    echo -e "${green}Hysteria2 已卸载${re}"
    echo -e "${yellow}提示: 云安全组中 UDP $range_p 如不再需要请手动删除; 备份在 $BACKUP_DIR${re}"
  else
    clean_firewall_rule "$port" udp
    echo -e "${green}Hysteria2 已卸载${re}"
    [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 UDP $port 如不再需要请手动删除; 备份在 $BACKUP_DIR${re}"
  fi
}

uninstall_reality() {
  if [[ ! -f "$XRAY_CONF" ]]; then
    echo -e "${yellow}Reality 未安装, 无需卸载${re}"
    return 0
  fi
  local port owned=0
  port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
  [[ -f "$XRAY_OWNED_MARK" ]] && owned=1
  echo -e "${yellow}将卸载 Reality 配置与服务${re}"
  if [[ "$owned" -eq 1 ]]; then
    echo -e "${yellow}(检测到本脚本安装标记，将同时移除 Xray 二进制)${re}"
  else
    echo -e "${yellow}(无本脚本安装标记，保留系统上的 Xray 二进制与目录)${re}"
  fi
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop xray.service 2>/dev/null || true
    systemctl disable xray.service 2>/dev/null || true
    # 仅在本脚本安装时移除 unit（避免动别人的 xray.service）
    if [[ "$owned" -eq 1 ]]; then
      rm -f /etc/systemd/system/xray.service
      systemctl daemon-reload 2>/dev/null || true
    fi
  fi
  pkill -f "[x]ray run" 2>/dev/null || true
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$XRAY_CONF" ]]; then
    cp -a "$XRAY_CONF" "$BACKUP_DIR/xray-config-uninstall.$(date +%Y%m%d%H%M%S).json" 2>/dev/null || true
  fi
  if [[ "$owned" -eq 1 ]]; then
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
  else
    # 非本脚本安装：只删配置文件，不动二进制
    rm -f "$XRAY_CONF"
    rm -f "$XRAY_OWNED_MARK" 2>/dev/null || true
  fi
  rm -f /var/log/xray-reality.log
  clean_firewall_rule "$port" tcp
  echo -e "${green}Reality 已卸载${re}"
  [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 TCP $port 如不再需要请手动删除; 备份在 $BACKUP_DIR${re}"
}

show_hy2_info() {
  [[ -f "$HY2_CONF" ]] || return 0
  local port passwd range_p hop_on=0
  range_p=$(sed -n 's/^listen: :\([0-9][0-9]*-[0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  if [[ -n "$range_p" ]]; then
    hop_on=1
    port="${range_p%%-*}"
  fi
  passwd=$(sed -n 's/^  password: "\(.*\)"$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_UP_MBPS=$(sed -n 's/^  up: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_DOWN_MBPS=$(sed -n 's/^  down: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  if [[ -z "$port" || -z "$passwd" ]]; then
    echo -e "${red}Hysteria2 配置解析失败${re}"
    return 0
  fi
  get_ip || return 0
  local tag="HY2-${HOST_IP}"
  local sni url
  sni=$(sed -n 's/.*url: https:\/\/\(.*\)/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  sni="${sni:-bing.com}"
  if [[ "$hop_on" == "1" ]]; then
    url="hysteria2://$passwd@$HOST_IP:$port/?sni=${sni}&alpn=h3&insecure=1&mport=${range_p}#$tag"
  else
    url="hysteria2://$passwd@$HOST_IP:$port/?sni=${sni}&alpn=h3&insecure=1#$tag"
  fi
  echo ""
  echo -e "${green}========== HY2 节点信息 ==========${re}"
  if [[ "$hop_on" == "1" ]]; then
    echo -e "端口: ${skyblue}${range_p}${re} (跳跃)  密码: ${skyblue}$passwd${re}"
  else
    echo -e "端口: ${skyblue}$port${re}  密码: ${skyblue}$passwd${re}"
  fi
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo -e "带宽: up ${CFG_UP_MBPS} Mbps / down ${CFG_DOWN_MBPS} Mbps (Brutal)"
  else
    echo -e "${yellow}BBR 模式 (无 bandwidth 参数)${re}"
  fi
  echo ""
  echo -e "${cyan}${url}${re}"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" 2>/dev/null || true
    echo ""
  fi
  echo -e "${yellow}--- Clash / Mihomo ---${re}"
  echo "- name: $tag"
  echo "  type: hysteria2"
  echo "  server: $HOST_IP"
  echo "  port: $port"
  echo "  password: $passwd"
  if [[ "$hop_on" == "1" ]]; then
    echo "  ports: $range_p"
    echo "  hop-interval: ${HY2_HOP_INTERVAL:-30}"
  fi
  [ -n "${CFG_UP_MBPS:-}" ] && echo "  up: \"${CFG_UP_MBPS} Mbps\"" && echo "  down: \"${CFG_DOWN_MBPS} Mbps\""
  echo "  sni: $sni"
  echo "  alpn:"
  echo "    - h3"
  echo "  skip-cert-verify: true"
  echo ""
}

show_reality_info() {
  [[ -f "$XRAY_CONF" ]] || return 0
  local xray_bin="/usr/local/bin/xray"
  if [[ ! -x "$xray_bin" ]]; then
    echo -e "${red}xray 程序缺失, 无法显示 Reality 节点信息${re}"
    return 0
  fi
  local port uuid sni privkey shortid pubkey fp
  port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
  uuid=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  sni=$(grep -oE '"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '"[^"]+"' | tail -1 | tr -d '"' || true)
  privkey=$(grep -oE '"privateKey"[[:space:]]*:[[:space:]]*"[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  shortid=$(grep -oE '"shortIds": \["[^"]+"' "$XRAY_CONF" 2>/dev/null | head -1 | grep -oE '[0-9a-fA-F]{8,16}' | head -1 || true)
  fp="${REALITY_FP:-chrome}"
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
  get_ip || return 0
  local ip="$HOST_IP" tag="Reality-${HOST_IP}"
  if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    echo -e "${yellow}检测到内网 IP ($ip), 疑似 NAT 机器: 下方链接请把 IP 手动替换为公网 IP${re}"
  fi
  local url="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=${fp}&pbk=${pubkey}&sid=${shortid}&type=tcp&headerType=none#${tag}"
  echo ""
  echo -e "${green}========== Reality 节点信息 ==========${re}"
  echo -e "${cyan}${url}${re}"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" 2>/dev/null || true
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
  echo "  client-fingerprint: ${fp}"
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
  if [[ -f "$NODE_INFO_FILE" ]]; then
    echo -e "${skyblue}历史节点信息文件: $NODE_INFO_FILE${re}"
  fi
}

# ============================================================================
# 菜单与分发
# ============================================================================
INSTALL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    hy2|reality|uninstall-hy2|uninstall-reality|show|sysopt) MODE="$arg" ;;
    *) INSTALL_ARGS+=("$arg") ;;
  esac
done

INTERACTIVE=0
[[ "$MODE" == "ask" ]] && INTERACTIVE=1

while true; do
if [[ "$MODE" == "ask" ]]; then
  detect_status
  echo ""
  echo -e "${green}======== HY2 / Reality 管理 (优化版) ========${re}"
  echo -e "  Hysteria2: ${skyblue}${HY2_STATE}${HY2_DETAIL:+ ($HY2_DETAIL)}${re}"
  echo -e "  Reality:   ${skyblue}${RE_STATE}${RE_DETAIL:+ ($RE_DETAIL)}${re}"
  echo ""
  echo "  1) 安装 Hysteria2  (多源测速 + Brutal；HY2_HOP=1 可开端口跳跃)"
  echo "  2) 安装 Reality    (VLESS + Reality + 多 shortId + 可选指纹)"
  echo "  3) 查看已安装节点信息"
  echo "  4) 卸载 Hysteria2"
  echo "  5) 卸载 Reality"
  echo "  6) 仅优化系统网络 (BBR + fq + 缓冲区，可选)"
  echo "  0) 退出"
  echo -e "${green}============================================${re}"
  read -r -p "输入序号 [1/2/3/4/5/6/0]: " _c </dev/tty
  case "$_c" in
    1) MODE=hy2 ;;
    2) MODE=reality ;;
    3) MODE=show ;;
    4) MODE=uninstall-hy2 ;;
    5) MODE=uninstall-reality ;;
    6) MODE=sysopt ;;
    0) echo "已退出"; exit 0 ;;
    *) die "无效选择" ;;
  esac
fi

case "$MODE" in
  hy2)
    if ! run_hy2 "${INSTALL_ARGS[@]}"; then
      [[ "$INTERACTIVE" == "1" ]] || exit 1
    fi
    ;;
  reality)
    if ! run_reality; then
      [[ "$INTERACTIVE" == "1" ]] || exit 1
    fi
    ;;
  uninstall-hy2)     uninstall_hy2 ;;
  uninstall-reality) uninstall_reality ;;
  show)              show_node_info ;;
  sysopt)            sys_network_optimize ;;
  *)                 die "MODE 非法: $MODE" ;;
esac

[[ "$INTERACTIVE" == "1" ]] || break
echo ""
read -n1 -s -r -p "按任意键返回主菜单... " _dummy </dev/tty
echo ""
MODE=ask
done
)
