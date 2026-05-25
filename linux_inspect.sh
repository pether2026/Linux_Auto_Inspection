#!/bin/bash
###############################################################################
# Linux 服务器巡检脚本
# 功能：一键采集系统关键指标，生成 HTML 巡检报告
# 适用：CentOS 7/8, RHEL, Ubuntu, Debian, Kylin, SUSE 等主流发行版
# 用法：chmod +x linux_inspect.sh && ./linux_inspect.sh [-v|-q|-o FILE|-f html|json|-h]
###############################################################################

set -euo pipefail

START_TIME=$(date +%s)
SCRIPT_VERSION="v2.5"
SCRIPT_NAME="$(basename "$0")"

# ======================== Bash 版本检查 ========================
# 脚本使用 here-string (<<<)、关联数组等 Bash 4+ 特性
if (( BASH_VERSINFO[0] < 4 )); then
    echo "错误: 需要 Bash 4.0 或以上版本（当前: ${BASH_VERSION}）" >&2
    exit 2
fi

# ======================== 错误捕获 ========================
on_error() {
    local exit_code=$? line_no=$1
    echo "[ERROR] 脚本第 ${line_no} 行执行失败 (exit ${exit_code})" >&2
}
trap 'on_error $LINENO' ERR

# ======================== v2.5 跨发行版兼容 helper ========================
# 设计原则: 优先现代命令, 失败时优雅降级, 三态 active/inactive/notfound 统一

# 是否有 systemd
has_systemd() {
    command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]
}

# 多源 OS 检测: 设置全局 OS_ID / OS_FAMILY / OS_PRETTY / OS_VER_MAJOR
# OS_FAMILY 归一为: rhel | debian | suse | kylin | uos | arch | alpine | gentoo | other
detect_os() {
    local id="" id_like="" ver="" pretty=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release 2>/dev/null || true
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
        ver="${VERSION_ID:-}"
        pretty="${PRETTY_NAME:-}"
    fi
    [[ -z "$id" && -f /etc/kylin-release  ]] && { id="kylin";   pretty=$(head -1 /etc/kylin-release  2>/dev/null); }
    [[ -z "$id" && -f /etc/centos-release ]] && { id="centos";  pretty=$(head -1 /etc/centos-release 2>/dev/null); }
    [[ -z "$id" && -f /etc/redhat-release ]] && { id="rhel";    pretty=$(head -1 /etc/redhat-release 2>/dev/null); }
    [[ -z "$id" && -f /etc/SuSE-release   ]] && { id="suse";    pretty=$(head -1 /etc/SuSE-release   2>/dev/null); }
    [[ -z "$id" && -f /etc/debian_version ]] && { id="debian";  pretty="Debian $(cat /etc/debian_version 2>/dev/null)"; }
    [[ -z "$id" && -f /etc/alpine-release ]] && { id="alpine";  pretty="Alpine $(cat /etc/alpine-release 2>/dev/null)"; }
    [[ -z "$id" && -f /etc/arch-release   ]] && { id="arch";    pretty="Arch Linux"; }
    [[ -z "$id" && -f /etc/gentoo-release ]] && { id="gentoo";  pretty=$(head -1 /etc/gentoo-release 2>/dev/null); }
    [[ -z "$id" && -f /etc/system-release ]] && { id="rhel";    pretty=$(head -1 /etc/system-release 2>/dev/null); }
    [[ -z "$id" ]] && { id="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"; pretty="$(uname -srvm 2>/dev/null)"; }

    case "$id $id_like" in
        *kylin*|*neokylin*)                                                    OS_FAMILY="kylin" ;;
        *uos*|*deepin*)                                                        OS_FAMILY="uos" ;;
        *rhel*|*centos*|*rocky*|*almalinux*|*ol*|*oracle*|*fedora*|*amzn*|*amazon*|*scientific*|*euleros*|*openeuler*|*anolis*|*tencentos*|*alinux*)
                                                                               OS_FAMILY="rhel" ;;
        *debian*|*ubuntu*|*kali*|*mint*|*pop*|*raspbian*|*elementary*)         OS_FAMILY="debian" ;;
        *suse*|*sles*|*opensuse*)                                              OS_FAMILY="suse" ;;
        *arch*|*manjaro*|*endeavour*|*garuda*)                                 OS_FAMILY="arch" ;;
        *alpine*)                                                              OS_FAMILY="alpine" ;;
        *gentoo*)                                                              OS_FAMILY="gentoo" ;;
        *)                                                                     OS_FAMILY="other" ;;
    esac
    OS_ID="${id// /}"
    OS_PRETTY="${pretty:-$(uname -srvm)}"
    OS_VER_MAJOR="${ver%%.*}"
}

# 服务状态: systemctl → service → chkconfig 三轨, 统一输出 active|inactive|notfound
safe_service_status() {
    local svc="$1" s=""
    if has_systemd; then
        s=$(systemctl is-active "$svc" 2>/dev/null || true)
        if [[ "$s" == "active" ]]; then echo "active"; return; fi
        # 检查 unit 是否存在 (区分 inactive / notfound)
        if printf '%s\n' "${ALL_UNITS:-}" | grep -qw "${svc}.service" 2>/dev/null; then
            echo "inactive"; return
        fi
        # 实时再查一次
        if systemctl list-unit-files "${svc}.service" --no-pager --no-legend 2>/dev/null | grep -qw "${svc}.service"; then
            echo "inactive"; return
        fi
        echo "notfound"
        return
    fi
    # sysvinit 路径
    if command -v service &>/dev/null && service "$svc" status &>/dev/null; then
        echo "active"; return
    fi
    if command -v chkconfig &>/dev/null && chkconfig --list 2>/dev/null | grep -qw "$svc"; then
        echo "inactive"; return
    fi
    if [[ -x "/etc/init.d/$svc" ]]; then
        "/etc/init.d/$svc" status &>/dev/null && echo "active" || echo "inactive"
        return
    fi
    echo "notfound"
}

# 服务是否开机启用 (best-effort)
safe_service_enabled() {
    local svc="$1"
    if has_systemd; then
        systemctl is-enabled "$svc" 2>/dev/null || echo "unknown"
    elif command -v chkconfig &>/dev/null; then
        chkconfig --list "$svc" 2>/dev/null | awk '{for(i=2;i<=NF;i++) if($i~/:on/){print "enabled"; exit}} END{if(!found)print "disabled"}' \
            || echo "unknown"
    else
        echo "unknown"
    fi
}

# 内核日志: dmesg 失败 fallback journalctl -k (5.0+ kernel.dmesg_restrict=1 + 非 root)
safe_dmesg() {
    local out
    out=$(dmesg 2>/dev/null || true)
    if [[ -z "$out" ]] && command -v journalctl &>/dev/null; then
        out=$(journalctl -k --no-pager 2>/dev/null | tail -3000 || true)
    fi
    printf '%s' "$out"
}

# 容器 cmd: 优先 docker, 否则 podman (RHEL 8+ / Fedora 31+ 默认)
container_cmd() {
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        echo "docker"; return
    fi
    if command -v podman &>/dev/null && podman info &>/dev/null; then
        echo "podman"; return
    fi
    echo ""
}

# 时区检测多源
detect_timezone() {
    local tz=""
    if command -v timedatectl &>/dev/null; then
        tz=$(timedatectl 2>/dev/null | awk -F': *' '/Time zone/{print $2; exit}' | awk '{print $1}')
    fi
    [[ -z "$tz" && -r /etc/timezone     ]] && tz=$(head -1 /etc/timezone 2>/dev/null)
    [[ -z "$tz" && -L /etc/localtime    ]] && tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [[ -z "$tz" && -r /etc/sysconfig/clock ]] && tz=$(awk -F'"' '/^ZONE=/{print $2; exit}' /etc/sysconfig/clock 2>/dev/null)
    [[ -z "$tz" ]] && tz="N/A"
    printf '%s' "$tz"
}

# ======================== 配置区 ========================
# 输出
REPORT_DIR="${INSPECT_REPORT_DIR:-/tmp/inspect_report}"
REPORT_FILE=""              # 由 -o 或自动生成
OUTPUT_FORMAT="html"        # html | json
VERBOSE=0
QUIET=0
SKIP_LARGE_FILE_SCAN=0
SKIP_UPDATE_CHECK=0
SKIP_SSL_CHECK=0

# 阈值
CPU_WARN=80                 # CPU 使用率告警阈值(%)
MEM_WARN=85                 # 内存使用率告警阈值(%)
DISK_WARN=85                # 磁盘使用率告警阈值(%)
INODE_WARN=85               # Inode 使用率告警阈值(%)
SWAP_WARN=50                # Swap 使用率告警阈值(%)
LOAD_WARN_FACTOR=2          # 负载告警倍数(相对于CPU核数)
ZOMBIE_WARN=0               # 僵尸进程告警阈值
FD_WARN=80                  # 文件描述符使用率告警阈值(%)
CRIT_OFFSET=10              # 严重阈值 = 警告阈值 + 此偏移
CONN_CLOSE_WAIT_THRESHOLD=50  # CLOSE_WAIT 连接告警阈值
WARN_BADGE_THRESHOLD=3      # summary 卡片警告着色阈值

# 列表数量
TOP_N=10                    # ps/file 等 TOP 列表条数
FD_TOP_N=5                  # 文件描述符 TOP 条数
LOG_LINES=20                # 日志检查行数

# 大文件
LARGE_FILE_SIZE="+100M"     # 大文件阈值
RECENT_FILE_DAYS=7          # 最近修改天数
RECENT_FILE_SIZE="+50M"     # 最近修改大文件阈值
LARGE_FILE_SEARCH_PATHS="/var /home /opt /usr/local"

# SSL 证书
SSL_CERT_DAYS_WARN=30       # 证书剩余天数告警阈值

# ======================== 帮助信息 ========================
show_help() {
    cat <<HELP
${SCRIPT_NAME} ${SCRIPT_VERSION} - Linux 服务器巡检

用法: ${SCRIPT_NAME} [选项]

选项:
  -o FILE          指定报告输出路径
  -f FORMAT        输出格式: html (默认) | json
  -v, --verbose    详细日志（含 debug 信息）
  -q, --quiet      静默模式（仅错误输出）
  --no-large-file-scan  跳过大文件扫描
  --skip-update-check   跳过包管理器联网检查（最慢的单步）
  --skip-ssl-check      跳过 SSL 证书扫描
  --fast                快速模式 = 上面三个 skip 全开
  -h, --help       显示此帮助

退出码:
  0  - 正常（无警告 / 无严重）
  1  - 有警告
  2  - 有严重告警 / 脚本错误

环境变量:
  INSPECT_REPORT_DIR  自定义报告目录（默认 /tmp/inspect_report）

示例:
  ${SCRIPT_NAME}                              # 默认 HTML 报告（完整）
  ${SCRIPT_NAME} --fast                       # 快速模式（推荐日常巡检）
  ${SCRIPT_NAME} -f json -o /tmp/r.json       # 输出 JSON
  ${SCRIPT_NAME} -v --skip-update-check       # 详细日志 + 不查更新
HELP
}

# ======================== 参数解析 ========================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)               REPORT_FILE="$2"; shift 2 ;;
        -f)               OUTPUT_FORMAT="$2"; shift 2 ;;
        -v|--verbose)     VERBOSE=1; shift ;;
        -q|--quiet)       QUIET=1; shift ;;
        --no-large-file-scan) SKIP_LARGE_FILE_SCAN=1; shift ;;
        --skip-update-check)  SKIP_UPDATE_CHECK=1; shift ;;
        --skip-ssl-check)     SKIP_SSL_CHECK=1; shift ;;
        --fast)
            SKIP_LARGE_FILE_SCAN=1
            SKIP_UPDATE_CHECK=1
            SKIP_SSL_CHECK=1
            shift ;;
        -h|--help)        show_help; exit 0 ;;
        *) echo "未知参数: $1" >&2; show_help; exit 2 ;;
    esac
done

if [[ "$OUTPUT_FORMAT" != "html" && "$OUTPUT_FORMAT" != "json" ]]; then
    echo "错误: -f 仅支持 html | json" >&2; exit 2
fi

# ======================== 依赖检查 ========================
check_dependencies() {
    local tools=("awk" "grep" "sed" "cat" "date" "hostname" "uname" "head" "tail" "wc" "cut" "xargs")
    local missing=""
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing="${missing}${tool} "
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "错误: 缺少必要工具: $missing" >&2
        exit 2
    fi
}
check_dependencies

# 报告路径
if [[ -z "$REPORT_FILE" ]]; then
    ext="html"
    [[ "$OUTPUT_FORMAT" == "json" ]] && ext="json"
    REPORT_FILE="${REPORT_DIR}/inspect_$(hostname)_$(date +%Y%m%d_%H%M%S).${ext}"
fi

if ! mkdir -p "$REPORT_DIR" 2>/dev/null; then
    echo "错误: 无法创建报告目录 ${REPORT_DIR}" >&2
    exit 2
fi
if ! : > "$REPORT_FILE" 2>/dev/null; then
    echo "错误: 无法写入报告文件 ${REPORT_FILE}" >&2
    exit 2
fi

# JSON 模式下临时把 HTML 写入丢弃，最后再写 JSON
REPORT_FILE_FINAL="$REPORT_FILE"
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    REPORT_FILE="/dev/null"
fi

# 颜色定义(终端输出用)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 计数器
WARN_COUNT=0
CRITICAL_COUNT=0

# 巡检步骤进度
TOTAL_STEPS=19
CURRENT_STEP=0

# ======================== 工具函数 ========================
log_info()  { (( QUIET == 1 )) && return 0; echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { (( QUIET == 1 )) || echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN_COUNT++)) || true; }
log_error() { echo -e "${RED}[CRITICAL]${NC} $1" >&2; ((CRITICAL_COUNT++)) || true; }
log_debug() { (( VERBOSE == 1 )) && echo -e "[DEBUG] $1" >&2; return 0; }

# 步骤进度日志：[N/M] (xx%) 描述
log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    (( QUIET == 1 )) && return 0
    local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    printf "${GREEN}[%2d/%-2d]${NC} (%3d%%) %s\n" "$CURRENT_STEP" "$TOTAL_STEPS" "$pct" "$1"
}

# 巡检开头横幅
print_banner() {
    (( QUIET == 1 )) && return 0
    local host_line="Host: $(hostname)"
    local time_line="Time: $(date '+%Y-%m-%d %H:%M:%S')"
    local mode_line="Format: ${OUTPUT_FORMAT}  |  Verbose: $([ "$VERBOSE" -eq 1 ] && echo on || echo off)"
    cat <<BANNER
==============================================
  Linux Inspection ${SCRIPT_VERSION}
  ${host_line}
  ${time_line}
  ${mode_line}
  Steps: ${TOTAL_STEPS}
==============================================
BANNER
}

status_badge() {
    local val=${1:-0} warn=${2:-80}
    local critical=$((warn + CRIT_OFFSET))
    if (( val >= critical )); then
        echo '<span class="badge critical">严重</span>'
    elif (( val >= warn )); then
        echo '<span class="badge warning">警告</span>'
    else
        echo '<span class="badge ok">正常</span>'
    fi
}

get_color_class() {
    local val=${1:-0} warn=${2:-80}
    if (( val >= warn + CRIT_OFFSET )); then echo "red"
    elif (( val >= warn )); then echo "orange"
    else echo "green"
    fi
}

# ps aux 排序结果转 HTML 表格行（去重 CPU_TOP / MEM_TOP）
# 用法: ps_top_to_html <sort_key>  例: ps_top_to_html -%cpu / ps_top_to_html -%mem
ps_top_to_html() {
    local sort_key="${1:-%cpu}"
    local n=$((TOP_N + 1))
    ps aux --sort="$sort_key" 2>/dev/null | head -"$n" | awk 'NR>1{
        printf "<tr><td>%s</td><td>%s</td><td>%s%%</td><td>%s%%</td><td>", $1, $2, $3, $4;
        for(i=11;i<=NF;i++) printf "%s ", $i;
        print "</td></tr>"
    }'
}

# 包装一段输出到 <pre> 块（自动 html_escape，处理空值）
pre_block() {
    local content="${1:-}" empty_text="${2:-无}"
    if [[ -z "$content" ]]; then
        echo "<pre>${empty_text}</pre>"
    else
        echo "<pre>$(html_escape "$content")</pre>"
    fi
}

# 字节转可读
human_bytes() {
    local bytes=${1:-0}
    if (( bytes >= 1073741824 )); then
        awk "BEGIN{printf \"%.1fG\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN{printf \"%.1fM\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN{printf \"%.1fK\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

# HTML 转义
html_escape() {
    local str="${1:-}"
    str="${str//&/&amp;}"
    str="${str//</&lt;}"
    str="${str//>/&gt;}"
    str="${str//\"/&quot;}"
    echo "$str"
}

# ======================== 显示巡检横幅 ========================
print_banner

# ======================== HTML 报告头 ========================
cat > "$REPORT_FILE" <<'HEADER'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Linux 服务器巡检报告</title>
<style>
  /* ============= Linux Inspection Report — Token Insight 风 ============= */
  :root {
    --c-primary: #1976d2;
    --c-primary-2: #1565c0;
    --c-primary-dark: #0d47a1;
    --c-primary-soft: #e8f1fc;
    --c-primary-soft-2: #f0f6ff;

    --c-text: #1f2937;
    --c-text-2: #4b5563;
    --c-muted: #6b7280;
    --c-bg: #f3f5f9;
    --c-card: #ffffff;
    --c-border: #d9dee7;
    --c-border-light: #eaedf3;
    --c-stripe: #fafbfd;

    --c-ok: #16a34a;
    --c-ok-soft: #e9f8ee;
    --c-ok-bg: #f0fdf4;
    --c-warn: #d97706;
    --c-warn-soft: #fff4e0;
    --c-warn-bg: #fffbeb;
    --c-crit: #dc2626;
    --c-crit-soft: #fde8e8;
    --c-crit-bg: #fef2f2;
    --c-info: #1976d2;
    --c-info-soft: #e8f1fc;

    --c-side-bg: #0f172a;
    --c-side-text: #cbd5e1;
    --c-side-muted: #64748b;
    --c-side-active: rgba(25,118,210,0.18);

    --shadow-sm: 0 1px 2px rgba(15,23,42,0.05);
    --shadow-md: 0 2px 8px rgba(15,23,42,0.06), 0 1px 3px rgba(15,23,42,0.05);
    --shadow-lg: 0 8px 24px rgba(15,23,42,0.10);

    --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", "Helvetica Neue", Arial, sans-serif;
    --font-mono: ui-monospace, "SFMono-Regular", "Cascadia Code", "JetBrains Mono", Consolas, "Liberation Mono", "Menlo", "Courier New", monospace;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body { font-family: var(--font-sans); font-size: 14px; background: var(--c-bg); color: var(--c-text); line-height: 1.55; -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; }

  /* ===== TOC: 深色侧栏 ===== */
  .toc { position: fixed; left: 0; top: 0; bottom: 0; width: 220px; background: var(--c-side-bg); padding: 22px 0 16px; overflow-y: auto; z-index: 10; }
  .toc-brand { padding: 0 22px 16px; border-bottom: 1px solid rgba(255,255,255,0.08); margin-bottom: 12px; display: flex; align-items: center; gap: 10px; }
  .toc-brand .logo { width: 28px; height: 28px; background: var(--c-primary); border-radius: 6px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .toc-brand .logo svg { width: 16px; height: 16px; fill: #fff; }
  .toc-brand .meta .name { font-size: 13px; font-weight: 600; color: #fff; letter-spacing: 0.2px; }
  .toc-brand .meta .ver { font-size: 11px; color: var(--c-side-muted); font-family: var(--font-mono); margin-top: 1px; }
  .toc h3 { display: none; }
  .toc a { display: flex; align-items: center; gap: 10px; padding: 9px 22px; color: var(--c-side-text); font-size: 13px; text-decoration: none; border-left: 3px solid transparent; transition: background 0.12s, color 0.12s, border-color 0.12s; }
  .toc a:hover { background: rgba(255,255,255,0.05); color: #fff; }
  .toc a.active { background: var(--c-side-active); border-left-color: var(--c-primary); color: #fff; font-weight: 500; }
  .toc a svg { width: 14px; height: 14px; flex-shrink: 0; opacity: 0.7; }
  .toc a.active svg { opacity: 1; }
  .toc-sec { padding: 14px 22px 6px; font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 1.2px; color: var(--c-side-muted); }

  /* ===== Layout ===== */
  .container { max-width: 1280px; margin: 24px auto 24px 240px; padding: 0 28px; }

  /* ===== Header: 蓝色 banner ===== */
  .header { background: linear-gradient(135deg, var(--c-primary) 0%, var(--c-primary-dark) 100%); color: #fff; padding: 22px 28px 18px; border-radius: 10px; margin-bottom: 18px; box-shadow: var(--shadow-md); position: relative; overflow: hidden; }
  .header::after { content: ""; position: absolute; right: -40px; top: -40px; width: 240px; height: 240px; background: radial-gradient(circle, rgba(255,255,255,0.10) 0%, transparent 70%); pointer-events: none; }
  .header-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; position: relative; z-index: 1; }
  .header h1 { font-size: 20px; font-weight: 700; letter-spacing: -0.2px; }
  .header h1 .tag { display: inline-block; background: rgba(255,255,255,0.20); color: #fff; font-size: 11px; padding: 3px 9px; border-radius: 4px; margin-right: 8px; vertical-align: middle; font-weight: 600; }
  .header-action { display: inline-flex; align-items: center; gap: 6px; background: rgba(255,255,255,0.15); color: #fff; padding: 7px 14px; border-radius: 6px; font-size: 12px; border: 1px solid rgba(255,255,255,0.25); cursor: default; }
  .header-action svg { width: 13px; height: 13px; fill: currentColor; }
  .header-meta { display: flex; flex-wrap: wrap; gap: 22px 32px; position: relative; z-index: 1; }
  .header-meta .field { font-size: 12.5px; }
  .header-meta .field .k { color: rgba(255,255,255,0.7); margin-right: 6px; }
  .header-meta .field .v { color: #fff; font-weight: 500; font-family: var(--font-mono); }

  /* ===== Summary cards: 图标 + 数字 ===== */
  .summary { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; margin-bottom: 18px; }
  .summary-card { background: var(--c-card); border-radius: 8px; padding: 14px 14px; box-shadow: var(--shadow-sm); border: 1px solid var(--c-border-light); display: flex; align-items: center; gap: 12px; }
  .summary-card .ico { width: 38px; height: 38px; border-radius: 8px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .summary-card .ico svg { width: 18px; height: 18px; fill: #fff; }
  .summary-card.s-ok   .ico { background: var(--c-ok); }
  .summary-card.s-warn .ico { background: var(--c-warn); }
  .summary-card.s-crit .ico { background: var(--c-crit); }
  .summary-card.s-info .ico { background: var(--c-primary); }
  .summary-card.s-purple .ico { background: #8b5cf6; }
  .summary-card.s-orange .ico { background: #f59e0b; }
  .summary-card .body { flex: 1; min-width: 0; }
  .summary-card .num { font-family: var(--font-sans); font-size: 22px; font-weight: 700; line-height: 1.1; letter-spacing: -0.5px; }
  .summary-card .label { font-size: 11px; color: var(--c-muted); margin-top: 4px; line-height: 1.3; }
  .summary-card .label .status { font-weight: 600; margin-left: 4px; }
  .num.green  { color: var(--c-ok); }
  .num.orange { color: var(--c-warn); }
  .num.red    { color: var(--c-crit); }
  .status.green  { color: var(--c-ok); }
  .status.orange { color: var(--c-warn); }
  .status.red    { color: var(--c-crit); }

  /* ===== Section card ===== */
  .section { background: var(--c-card); border-radius: 10px; margin-bottom: 14px; box-shadow: var(--shadow-sm); border: 1px solid var(--c-border-light); overflow: hidden; }
  .section[id] { scroll-margin-top: 16px; }
  .section > *:not(h2) { padding-left: 24px; padding-right: 24px; }
  .section > h2 { font-size: 15px; font-weight: 700; color: var(--c-primary-dark); margin: 0; padding: 12px 22px; background: var(--c-primary-soft-2); border-bottom: 1px solid var(--c-border-light); display: flex; align-items: center; letter-spacing: 0; }
  .section > h2 .num { display: inline-block; color: var(--c-primary); font-weight: 700; margin-right: 8px; min-width: 18px; }
  .section > *:first-child + * { padding-top: 18px; }
  .section > *:last-child { padding-bottom: 20px; }
  .section h3 { font-size: 12.5px; font-weight: 600; color: var(--c-text-2); margin: 18px 0 10px; }
  .section h3:first-of-type { margin-top: 0; }
  .section .sub-line { font-size: 12.5px; color: var(--c-muted); margin: -6px 0 12px; }

  /* ===== Tables ===== */
  table { width: 100%; border-collapse: collapse; font-size: 13px; table-layout: fixed; margin-top: 4px; }
  table.table-auto { table-layout: auto; }
  th { background: var(--c-primary-soft-2); text-align: left; padding: 10px 12px; font-weight: 600; font-size: 12px; color: var(--c-text-2); border-bottom: 1px solid var(--c-border-light); white-space: nowrap; }
  td { padding: 9px 12px; border-bottom: 1px solid var(--c-border-light); word-break: break-all; vertical-align: top; font-family: var(--font-mono); font-size: 12.5px; line-height: 1.5; color: var(--c-text); }
  tr:nth-child(even) td { background: var(--c-stripe); }
  tr:hover td { background: var(--c-primary-soft); }
  tr:last-child td { border-bottom: none; }
  td.text { font-family: var(--font-sans); font-size: 13px; }

  /* 列宽 */
  .col-name { width: 15%; } .col-value { width: 25%; } .col-status { width: 100px; }
  .col-pct { width: 12%; } .col-path { width: 40%; } .col-port { width: 22%; }
  .col-proc { width: 25%; } .col-cmd { width: 35%; } .col-fs { width: 18%; }
  .col-mount { width: 25%; } .col-size { width: 80px; } .col-usage { width: 18%; }

  /* ===== Status text (代替 badge for inline) ===== */
  .badge { display: inline-block; padding: 2px 9px; border-radius: 10px; font-size: 11.5px; font-weight: 600; line-height: 1.5; font-family: var(--font-sans); }
  .badge.ok       { background: var(--c-ok-soft);   color: var(--c-ok); }
  .badge.warning  { background: var(--c-warn-soft); color: var(--c-warn); }
  .badge.critical { background: var(--c-crit-soft); color: var(--c-crit); }
  .badge.info     { background: var(--c-info-soft); color: var(--c-info); }
  td .badge { font-weight: 600; }
  td.status-text { font-family: var(--font-sans); font-weight: 600; }
  td.status-text.green  { color: var(--c-ok); }
  td.status-text.orange { color: var(--c-warn); }
  td.status-text.red    { color: var(--c-crit); }

  /* ===== Info grid: 4 列 ===== */
  .info-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px 28px; }
  .info-item { padding: 10px 0; border-bottom: 1px dashed var(--c-border-light); }
  .info-item:nth-last-child(-n+4) { border-bottom: none; }
  .info-item .key { color: var(--c-muted); font-size: 11.5px; display: block; margin-bottom: 3px; font-weight: 500; }
  .info-item .val { color: var(--c-text); font-size: 13px; word-break: break-all; font-weight: 500; }
  @media (max-width: 1100px) {
    .info-grid { grid-template-columns: repeat(3, 1fr); }
    .info-item:nth-last-child(-n+4) { border-bottom: 1px dashed var(--c-border-light); }
    .info-item:nth-last-child(-n+3) { border-bottom: none; }
  }

  /* ===== Progress bar ===== */
  .progress-bar { background: var(--c-border-light); border-radius: 4px; height: 6px; overflow: hidden; display: inline-block; width: 90px; vertical-align: middle; margin-right: 8px; }
  .progress-fill { height: 100%; transition: width 0.3s; }
  .fill-ok   { background: var(--c-ok); }
  .fill-warn { background: var(--c-warn); }
  .fill-crit { background: var(--c-crit); }

  /* ===== Pre / code ===== */
  pre { background: #0f172a; color: #cbd5e1; border: 1px solid #1e293b; padding: 14px 16px; border-radius: 6px; font-family: var(--font-mono); font-size: 12px; line-height: 1.6; overflow-x: auto; white-space: pre-wrap; word-break: break-all; max-height: 340px; overflow-y: auto; margin-bottom: 4px; }
  pre::-webkit-scrollbar { width: 8px; height: 8px; }
  pre::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 4px; }

  /* ===== 推荐卡片（短期/中期/长期）===== */
  .recommends { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin-top: 4px; }
  .rec-card { background: var(--c-card); border: 1px solid var(--c-border-light); border-radius: 8px; padding: 16px 18px; border-top: 3px solid var(--c-muted); }
  .rec-card.r-short { border-top-color: var(--c-warn); }
  .rec-card.r-mid   { border-top-color: var(--c-primary); }
  .rec-card.r-long  { border-top-color: var(--c-ok); }
  .rec-card h4 { font-size: 13px; font-weight: 700; color: var(--c-text); margin-bottom: 12px; display: flex; align-items: center; gap: 6px; }
  .rec-card h4 .span { font-size: 11px; font-weight: 500; color: var(--c-muted); margin-left: 4px; }
  .rec-card ul { list-style: none; padding: 0; margin: 0; }
  .rec-card li { font-size: 12.5px; color: var(--c-text-2); padding: 5px 0 5px 16px; position: relative; line-height: 1.55; }
  .rec-card li::before { content: ""; position: absolute; left: 0; top: 11px; width: 5px; height: 5px; border-radius: 50%; background: var(--c-muted); }
  .rec-card.r-short li::before { background: var(--c-warn); }
  .rec-card.r-mid   li::before { background: var(--c-primary); }
  .rec-card.r-long  li::before { background: var(--c-ok); }

  /* ===== 免责声明 ===== */
  .disclaimer { background: #f8f9fb; border: 1px solid var(--c-border-light); border-radius: 8px; padding: 16px 22px; margin: 14px 0; }
  .disclaimer h4 { font-size: 13px; font-weight: 700; color: var(--c-text); margin-bottom: 8px; }
  .disclaimer p { font-size: 12px; color: var(--c-muted); line-height: 1.65; }

  /* ===== Footer ===== */
  .footer { text-align: center; color: var(--c-muted); font-size: 12px; padding: 22px 0 12px; }
  .footer .sep { color: var(--c-border); margin: 0 8px; }

  /* ===== Misc ===== */
  .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
  .mini-card { background: var(--c-bg); border: 1px solid var(--c-border-light); border-radius: 6px; padding: 14px; }
  .mini-card h4 { font-size: 12px; font-weight: 600; color: var(--c-muted); margin-bottom: 10px; }
  .tag-list { display: flex; flex-wrap: wrap; gap: 6px; }
  .tag { display: inline-block; background: var(--c-card); border: 1px solid var(--c-border); padding: 3px 9px; border-radius: 4px; font-size: 12px; color: var(--c-text-2); font-family: var(--font-mono); }

  /* ===== 锚点 highlight ===== */
  .section:target { animation: tgt 1.6s ease-out; }
  @keyframes tgt {
    0%   { box-shadow: 0 0 0 3px var(--c-primary); }
    100% { box-shadow: var(--shadow-sm); }
  }

  /* ===== Mobile ===== */
  @media (max-width: 900px) {
    .toc { position: relative; width: 100%; height: auto; padding: 14px 16px; }
    .toc-brand { padding-bottom: 10px; margin-bottom: 8px; }
    .toc a { display: inline-flex; padding: 4px 10px; border-left: none; border-radius: 4px; margin: 2px; font-size: 12px; }
    .toc-sec { display: none; }
    .container { margin-left: auto; margin-right: auto; padding: 16px; }
    .summary { grid-template-columns: repeat(2, 1fr); }
    .info-grid { grid-template-columns: 1fr; }
    .recommends { grid-template-columns: 1fr; }
    .header-meta { gap: 10px 18px; }
    .header h1 { font-size: 17px; }
    .header-action { display: none; }
  }

  /* ===== Print ===== */
  @media print {
    body { background: #fff; font-size: 10.5pt; color: #000; }
    .toc, .footer, .header-action { display: none !important; }
    .container { margin: 0; max-width: 100%; padding: 0; }
    .header { background: #1565c0 !important; color: #fff !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .section, .summary-card, .rec-card { box-shadow: none; border: 1px solid #ccc; page-break-inside: avoid; }
    .summary { grid-template-columns: repeat(6, 1fr); }
    .summary-card { padding: 8px 6px; }
    pre { background: #f5f5f5 !important; color: #000 !important; max-height: none; overflow: visible; white-space: pre-wrap; }
    table { page-break-inside: auto; }
    tr { page-break-inside: avoid; page-break-after: auto; }
    a { color: inherit; text-decoration: none; }
  }
</style>
</head>
<body>
<nav class="toc">
  <div class="toc-brand">
    <div class="logo"><svg viewBox="0 0 24 24"><path d="M3 5h18v2H3zm0 6h18v2H3zm0 6h18v2H3z"/></svg></div>
    <div class="meta">
      <div class="name">Linux Inspection</div>
      <div class="ver">__SCRIPT_VERSION_PLACEHOLDER__</div>
    </div>
  </div>
  <a href="#sec-summary">概览</a>
  <a href="#sec-info">基本信息</a>
  <div class="toc-sec">资源</div>
  <a href="#sec-cpu">CPU &amp; 负载</a>
  <a href="#sec-mem">内存</a>
  <a href="#sec-disk">磁盘</a>
  <a href="#sec-large">大文件</a>
  <a href="#sec-fd">文件描述符</a>
  <div class="toc-sec">运行时</div>
  <a href="#sec-net">网络</a>
  <a href="#sec-proc">进程</a>
  <a href="#sec-svc">服务</a>
  <a href="#sec-docker">Docker</a>
  <a href="#sec-cron">定时任务</a>
  <div class="toc-sec">安全 / 维护</div>
  <a href="#sec-security">安全检查</a>
  <a href="#sec-kernel">内核参数</a>
  <a href="#sec-update">系统更新</a>
  <a href="#sec-ssl">SSL 证书</a>
  <a href="#sec-log">系统日志</a>
  <a href="#sec-recommend">总体建议</a>
</nav>
<div class="container">
HEADER

# 替换 nav 里的版本占位符（HEADER 是 quoted heredoc，避免 CSS 中的 $ 干扰）
sed -i "s/__SCRIPT_VERSION_PLACEHOLDER__/${SCRIPT_VERSION}/g" "$REPORT_FILE" 2>/dev/null || true

# ======================== 基本信息采集 ========================
log_step "采集基本信息（主机/CPU/内存/网络/虚拟化）..."

HOSTNAME_VAL=$(hostname)
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || echo "$HOSTNAME_VAL")
# v2.5: hostname -I → ip addr → ifconfig 三级 fallback (最小化镜像可能无 iproute2)
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$IP_ADDR" || "$IP_ADDR" == "N/A" ]]; then
    if command -v ip &>/dev/null; then
        IP_ADDR=$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1 | cut -d/ -f1)
    elif command -v ifconfig &>/dev/null; then
        IP_ADDR=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)
    fi
fi
IP_ADDR="${IP_ADDR:-N/A}"
IP_ALL=$(hostname -I 2>/dev/null | xargs)
[[ -z "$IP_ALL" ]] && IP_ALL=$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{print $4}' | cut -d/ -f1 | xargs 2>/dev/null)
[[ -z "$IP_ALL" ]] && IP_ALL=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | xargs 2>/dev/null)
IP_ALL="${IP_ALL:-N/A}"
detect_os                                   # v2.5: 多源 OS 检测 → OS_ID / OS_FAMILY / OS_PRETTY / OS_VER_MAJOR
OS_VERSION="$OS_PRETTY"
KERNEL=$(uname -r)
ARCH=$(uname -m)
UPTIME=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
UPTIME_DAYS=$(awk '{printf "%.0f", $1/86400}' /proc/uptime 2>/dev/null || echo "N/A")
CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "N/A")
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "N/A")
CPU_SOCKETS=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l || echo "N/A")
MEM_TOTAL=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "N/A")
BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "N/A")
CURRENT_USERS=$(who 2>/dev/null | wc -l)
CURRENT_USERS_LIST=$(who 2>/dev/null | awk '{print $1}' | sort -u | xargs || echo "无")
PROCESS_COUNT=$(ps aux 2>/dev/null | wc -l)
THREAD_COUNT=$(ps -eLf 2>/dev/null | wc -l || echo "N/A")
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce)
    SELINUX_CONFIG=$(grep "^SELINUX=" /etc/selinux/config 2>/dev/null | cut -d= -f2)
    SELINUX_STATUS="${SELINUX_STATUS} (配置: ${SELINUX_CONFIG:-unknown})"
else
    SELINUX_STATUS="未安装"
fi
TIMEZONE=$(detect_timezone)                 # v2.5: timedatectl / /etc/timezone / readlink /etc/localtime / sysconfig/clock 四源 fallback
LOCALE=$(echo "$LANG" 2>/dev/null || echo "N/A")
# v2.5: ip route → netstat -rn → route -n 三级 fallback
DEFAULT_GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
[[ -z "$DEFAULT_GW" ]] && DEFAULT_GW=$(netstat -rn 2>/dev/null | awk '/^0\.0\.0\.0|^default/{print $2; exit}')
[[ -z "$DEFAULT_GW" ]] && DEFAULT_GW=$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/{print $2; exit}')
DEFAULT_GW="${DEFAULT_GW:-N/A}"
DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | xargs || echo "N/A")
# v2.5: 防火墙状态多源识别 (firewalld → ufw → nftables → iptables → SuSEfirewall2), systemd 与 sysvinit 双轨
FIREWALL_STATUS="inactive"
for fw in firewalld ufw nftables iptables SuSEfirewall2; do
    s=$(safe_service_status "$fw")
    if [[ "$s" == "active" ]]; then
        FIREWALL_STATUS="${fw} (active)"
        break
    fi
done
# 最后兜底: 即便没有服务管理也可以从规则表判断 iptables 有无规则
if [[ "$FIREWALL_STATUS" == "inactive" ]] && command -v iptables &>/dev/null; then
    if iptables -L -n 2>/dev/null | grep -qE '^(ACCEPT|DROP|REJECT)'; then
        FIREWALL_STATUS="iptables (规则存在, 服务状态未知)"
    fi
fi
unset s

# 硬件信息
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "N/A")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "N/A")
SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "N/A")
BIOS_VER=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "N/A")

# 虚拟化检测
VIRT_TYPE="物理机"
if command -v systemd-detect-virt &>/dev/null; then
    virt=$(systemd-detect-virt 2>/dev/null || true)
    [[ -n "$virt" && "$virt" != "none" ]] && VIRT_TYPE="$virt"
elif grep -qi "vmware\|virtualbox\|kvm\|qemu\|xen\|hyperv" /sys/class/dmi/id/product_name 2>/dev/null; then
    VIRT_TYPE=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
fi

log_debug "采集基本信息完成"

cat >> "$REPORT_FILE" <<EOF
<div class="header">
  <div class="header-top">
    <h1><span class="tag">巡检</span>Linux 服务器深度巡检报告 - ${HOSTNAME_VAL}</h1>
    <span class="header-action"><svg viewBox="0 0 24 24"><path d="M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z"/></svg>${OUTPUT_FORMAT^^}</span>
  </div>
  <div class="header-meta">
    <div class="field"><span class="k">主机:</span><span class="v">${HOSTNAME_VAL}</span></div>
    <div class="field"><span class="k">IP:</span><span class="v">${IP_ADDR}</span></div>
    <div class="field"><span class="k">操作系统:</span><span class="v">${OS_VERSION}</span></div>
    <div class="field"><span class="k">内核:</span><span class="v">${KERNEL}</span></div>
    <div class="field"><span class="k">生成时间:</span><span class="v">$(date '+%Y-%m-%d %H:%M:%S')</span></div>
    <div class="field"><span class="k">工具版本:</span><span class="v">${SCRIPT_VERSION}</span></div>
  </div>
</div>
EOF

get_cpu_idle() {
    # 提速：直接读两次 /proc/stat 间隔 200ms（精度足够，省去 top/mpstat/vmstat 各 1s 的 fallback）
    local idle=""
    local u1 n1 s1 i1 u2 n2 s2 i2

    if [[ -r /proc/stat ]]; then
        read -r _ u1 n1 s1 i1 _ < /proc/stat 2>/dev/null || true
        sleep 0.2 2>/dev/null || sleep 1
        read -r _ u2 n2 s2 i2 _ < /proc/stat 2>/dev/null || true
        if [[ -n "${i1:-}" && -n "${i2:-}" ]]; then
            local total=$(( (u2+n2+s2+i2) - (u1+n1+s1+i1) ))
            local idle_val=$(( i2 - i1 ))
            if (( total > 0 )); then
                idle=$(awk "BEGIN{printf \"%.1f\", $idle_val/$total*100}")
                [[ "$idle" =~ ^[0-9.]+$ ]] && { echo "$idle"; return; }
            fi
        fi
    fi

    # Fallback: top 单次（不会等 1 秒）
    idle=$(top -bn1 2>/dev/null | grep -i "cpu" | head -1 | grep -oP '[0-9.]+(?=\s*id)' || true)
    [[ "$idle" =~ ^[0-9.]+$ ]] && { echo "$idle"; return; }

    echo "100"
}

# ======================== CPU 检查 ========================
log_step "检查 CPU 使用率与负载..."
CPU_IDLE=$(get_cpu_idle)
CPU_USAGE=$(awk "BEGIN{v=100-$CPU_IDLE; if(v<0) v=0; if(v>100) v=100; printf \"%.0f\", v}")
CPU_BADGE=$(status_badge "$CPU_USAGE" "$CPU_WARN")

if (( CPU_USAGE >= CPU_WARN + CRIT_OFFSET )); then
    log_error "CPU 使用率: ${CPU_USAGE}%"
elif (( CPU_USAGE >= CPU_WARN )); then
    log_warn "CPU 使用率: ${CPU_USAGE}%"
else
    log_info "CPU 使用率: ${CPU_USAGE}%"
fi

# CPU 各状态详细
CPU_DETAIL=$(top -bn1 2>/dev/null | grep -i "cpu(s)" | head -1 || echo "N/A")

# 负载检查
LOAD_1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
LOAD_5=$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo "0")
LOAD_15=$(awk '{print $3}' /proc/loadavg 2>/dev/null || echo "0")
RUNNING_PROCS=$(awk '{print $4}' /proc/loadavg 2>/dev/null || echo "N/A")
LOAD_WARN_VAL=$((CPU_CORES * LOAD_WARN_FACTOR))
LOAD_INT=${LOAD_1%.*}
LOAD_INT=${LOAD_INT:-0}

if (( LOAD_INT >= LOAD_WARN_VAL )); then
    log_warn "系统负载偏高: ${LOAD_1} (核数: ${CPU_CORES})"
    LOAD_BADGE='<span class="badge warning">警告</span>'
else
    LOAD_BADGE='<span class="badge ok">正常</span>'
fi

# CPU 占用 TOP N
CPU_TOP=$(ps_top_to_html -%cpu)

# ======================== 内存检查 ========================
log_step "检查内存与 Swap..."
MEM_TOTAL=$(free -b 2>/dev/null | awk '/Mem:/{print $2}')
MEM_AVAIL=$(free -b 2>/dev/null | awk '/Mem:/{print $7}')
MEM_USAGE=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL ))
MEM_USAGE=${MEM_USAGE:-0}
MEM_BADGE=$(status_badge "$MEM_USAGE" "$MEM_WARN")

MEM_DETAIL=$(free -h 2>/dev/null || echo "N/A")

# Swap
SWAP_TOTAL_B=$(free -b 2>/dev/null | awk '/Swap:/{print $2}')
SWAP_USED_B=$(free -b 2>/dev/null | awk '/Swap:/{print $3}')
if (( SWAP_TOTAL_B > 0 )); then
    SWAP_USAGE=$(( SWAP_USED_B * 100 / SWAP_TOTAL_B ))
else
    SWAP_USAGE=0
fi
SWAP_TOTAL=$(free -h 2>/dev/null | awk '/Swap:/{print $2}' || echo "N/A")
SWAP_USED=$(free -h 2>/dev/null | awk '/Swap:/{print $3}' || echo "N/A")
SWAP_BADGE=$(status_badge "${SWAP_USAGE}" "$SWAP_WARN")

if (( MEM_USAGE >= MEM_WARN + CRIT_OFFSET )); then
    log_error "内存使用率: ${MEM_USAGE}%"
elif (( MEM_USAGE >= MEM_WARN )); then
    log_warn "内存使用率: ${MEM_USAGE}%"
else
    log_info "内存使用率: ${MEM_USAGE}%"
fi

# 内存占用 TOP N
MEM_TOP=$(ps_top_to_html -%mem)

# ======================== 磁盘检查 ========================
log_step "检查磁盘使用率与 Inode..."
DISK_ROWS=""
DISK_ALERT=0
while IFS= read -r line; do
    fs=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && continue
    badge=$(status_badge "$pct" "$DISK_WARN")

    fill_class="fill-ok"
    if (( pct >= DISK_WARN + CRIT_OFFSET )); then
        fill_class="fill-crit"
        log_error "磁盘 ${mount}: ${pct}%"
        ((DISK_ALERT++)) || true
    elif (( pct >= DISK_WARN )); then
        fill_class="fill-warn"
        log_warn "磁盘 ${mount}: ${pct}%"
        ((DISK_ALERT++)) || true
    fi

    DISK_ROWS+="<tr><td>${fs}</td><td>${size}</td><td>${used}</td><td>${avail}</td>"
    DISK_ROWS+="<td><div class=\"progress-bar\"><div class=\"progress-fill ${fill_class}\" style=\"width:${pct}%\"></div></div> ${pct}%</td>"
    DISK_ROWS+="<td>${mount}</td><td>${badge}</td></tr>"
done <<< "$(df -hP 2>/dev/null | grep -vE "^Filesystem|tmpfs|devtmpfs|overlay|cdrom|udev" || true)"

# Inode 检查
INODE_ROWS=""
while IFS= read -r line; do
    fs=$(echo "$line" | awk '{print $1}')
    pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $6}')
    [[ -z "$pct" || "$pct" == "-" || ! "$pct" =~ ^[0-9]+$ ]] && continue
    badge=$(status_badge "$pct" "$INODE_WARN")
    if (( pct >= INODE_WARN )); then
        log_warn "Inode ${mount}: ${pct}%"
    fi
    INODE_ROWS+="<tr><td>${fs}</td><td>${pct}%</td><td>${mount}</td><td>${badge}</td></tr>"
done <<< "$(df -iP 2>/dev/null | grep -vE "^Filesystem|tmpfs|devtmpfs|overlay" || true)"

# 磁盘 I/O 统计
# v2.5: 最小化系统常无 sysstat (iostat) 包, fallback 解析 /proc/diskstats
log_step "检查磁盘 I/O 性能..."
DISK_IO_ROWS=""
if command -v iostat &>/dev/null; then
    while IFS= read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        tps=$(echo "$line" | awk '{print $2}')
        read_s=$(echo "$line" | awk '{print $3}')
        write_s=$(echo "$line" | awk '{print $4}')
        [[ "$dev" =~ ^loop|^ram ]] && continue
        DISK_IO_ROWS+="<tr><td>${dev}</td><td>${tps}</td><td>${read_s}</td><td>${write_s}</td></tr>"
    done <<< "$(iostat -d 2>/dev/null | awk 'NR>3 && NF>0{print}' || true)"
elif [[ -r /proc/diskstats ]]; then
    # /proc/diskstats 字段: major minor name reads merges read_sectors read_ms writes merges_w write_sectors write_ms in_flight io_ms io_weighted
    while IFS= read -r line; do
        dev=$(echo "$line" | awk '{print $3}')
        reads=$(echo "$line" | awk '{print $4}')
        writes=$(echo "$line" | awk '{print $8}')
        rd_kb=$(echo "$line" | awk '{print $6*512/1024}')   # 扇区→KB
        wr_kb=$(echo "$line" | awk '{print $10*512/1024}')
        [[ "$dev" =~ ^loop|^ram|^dm- ]] && continue
        [[ -z "$dev" || "$reads" == "0" && "$writes" == "0" ]] && continue
        DISK_IO_ROWS+="<tr><td>${dev}</td><td>${reads}r/${writes}w</td><td>${rd_kb} KB</td><td>${wr_kb} KB</td></tr>"
    done <<< "$(awk 'NF>=10{print}' /proc/diskstats 2>/dev/null || true)"
fi

# 大文件 TOP N（限制搜索范围提高性能；可用 --no-large-file-scan 跳过）
LARGE_FILES=""
RECENT_LARGE=""
if (( SKIP_LARGE_FILE_SCAN == 1 )); then
    log_step "扫描大文件（已跳过 --no-large-file-scan）"
else
    log_step "扫描大文件（>${LARGE_FILE_SIZE} / 最近${RECENT_FILE_DAYS}天>${RECENT_FILE_SIZE}）..."
    log_debug "搜索路径: ${LARGE_FILE_SEARCH_PATHS} 阈值: ${LARGE_FILE_SIZE}"
    while IFS= read -r line; do
        fsize=$(echo "$line" | awk '{print $1}')
        fpath=$(echo "$line" | cut -d' ' -f2-)
        LARGE_FILES+="<tr><td>${fsize}</td><td>$(html_escape "$fpath")</td></tr>"
    done <<< "$(find $LARGE_FILE_SEARCH_PATHS -xdev -type f -size "$LARGE_FILE_SIZE" 2>/dev/null | head -$((TOP_N * 2)) | xargs du -sh 2>/dev/null | sort -rh | head -"$TOP_N" || true)"

    # 最近 N 天修改的大文件
    while IFS= read -r line; do
        fsize=$(echo "$line" | awk '{print $1}')
        fpath=$(echo "$line" | cut -d' ' -f2-)
        RECENT_LARGE+="<tr><td>${fsize}</td><td>$(html_escape "$fpath")</td></tr>"
    done <<< "$(find $LARGE_FILE_SEARCH_PATHS -xdev -type f -size "$RECENT_FILE_SIZE" -mtime -"$RECENT_FILE_DAYS" 2>/dev/null | head -$((TOP_N * 2)) | xargs du -sh 2>/dev/null | sort -rh | head -"$TOP_N" || true)"
fi

# ======================== 文件描述符 ========================
log_step "检查文件描述符使用..."
FD_CURRENT=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}' || echo "0")
FD_MAX=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $3}' || echo "1")
FD_PCT=$(awk "BEGIN{if($FD_MAX>0) printf \"%.0f\", $FD_CURRENT/$FD_MAX*100; else print 0}")
FD_BADGE=$(status_badge "$FD_PCT" "$FD_WARN")
if (( FD_PCT >= FD_WARN )); then
    log_warn "文件描述符使用率: ${FD_PCT}%"
fi

# 各进程 FD 使用 TOP N
FD_TOP=$(for pid in $(ls /proc/ 2>/dev/null | grep -E '^[0-9]+$' | head -200); do
    fd_count=$(ls /proc/"$pid"/fd 2>/dev/null | wc -l || echo 0)
    name=$(cat /proc/"$pid"/comm 2>/dev/null || echo "unknown")
    echo "$fd_count $pid $name"
done 2>/dev/null | sort -rn | head -"$FD_TOP_N" | awk '{printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", $3, $2, $1}')

# ======================== 网络检查 ========================
log_step "检查网络状态（网卡/TCP/路由）..."
NIC_ROWS=""
while IFS= read -r nic; do
    [[ "$nic" == "lo" ]] && continue
    state=$(cat /sys/class/net/"$nic"/operstate 2>/dev/null || echo "unknown")
    speed=$(cat /sys/class/net/"$nic"/speed 2>/dev/null || echo "N/A")
    [[ "$speed" == "-1" ]] && speed="N/A"
    ip=$(ip -4 addr show "$nic" 2>/dev/null | grep inet | awk '{print $2}' | head -1 || echo "N/A")
    mac=$(cat /sys/class/net/"$nic"/address 2>/dev/null || echo "N/A")
    # 流量统计
    rx_bytes=$(cat /sys/class/net/"$nic"/statistics/rx_bytes 2>/dev/null || echo "0")
    tx_bytes=$(cat /sys/class/net/"$nic"/statistics/tx_bytes 2>/dev/null || echo "0")
    rx_h=$(human_bytes "$rx_bytes")
    tx_h=$(human_bytes "$tx_bytes")
    rx_errors=$(cat /sys/class/net/"$nic"/statistics/rx_errors 2>/dev/null || echo "0")
    tx_errors=$(cat /sys/class/net/"$nic"/statistics/tx_errors 2>/dev/null || echo "0")
    rx_dropped=$(cat /sys/class/net/"$nic"/statistics/rx_dropped 2>/dev/null || echo "0")
    tx_dropped=$(cat /sys/class/net/"$nic"/statistics/tx_dropped 2>/dev/null || echo "0")
    badge='<span class="badge ok">UP</span>'
    [[ "$state" != "up" ]] && badge='<span class="badge warning">DOWN</span>'
    err_badge=""
    total_err=$((rx_errors + tx_errors + rx_dropped + tx_dropped))
    if (( total_err > 0 )); then
        err_badge=' <span class="badge warning">有错误</span>'
    fi
    NIC_ROWS+="<tr><td>${nic}</td><td>${ip}</td><td>${mac}</td><td>${speed}Mbps</td><td>RX:${rx_h} TX:${tx_h}</td><td>错误:${total_err} 丢包:$((rx_dropped+tx_dropped))</td><td>${badge}${err_badge}</td></tr>"
done <<< "$(ls /sys/class/net/ 2>/dev/null || true)"

# TCP 连接统计
CONN_ESTABLISHED=$(ss -tn state established 2>/dev/null | wc -l || echo "0")
CONN_TIME_WAIT=$(ss -tn state time-wait 2>/dev/null | wc -l || echo "0")
CONN_CLOSE_WAIT=$(ss -tn state close-wait 2>/dev/null | wc -l || echo "0")
CONN_SYN_RECV=$(ss -tn state syn-recv 2>/dev/null | wc -l || echo "0")
CONN_LISTEN=$(ss -tln 2>/dev/null | wc -l || echo "0")
CONN_TOTAL=$((CONN_ESTABLISHED + CONN_TIME_WAIT + CONN_CLOSE_WAIT + CONN_SYN_RECV))

if (( CONN_CLOSE_WAIT > CONN_CLOSE_WAIT_THRESHOLD )); then
    log_warn "CLOSE_WAIT 连接数偏高: ${CONN_CLOSE_WAIT} (阈值 ${CONN_CLOSE_WAIT_THRESHOLD})"
fi

# 监听端口
LISTEN_PORTS=$(ss -tlnp 2>/dev/null | awk 'NR>1 {
    split($4, addr, ":")
    port = addr[length(addr)]
    printf "<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", $4, $1, $NF
}' | head -30)

# 路由表
# v2.5: ip route → netstat -rn → route -n
ROUTE_RAW=$(ip route 2>/dev/null || netstat -rn 2>/dev/null || route -n 2>/dev/null || echo "")
ROUTE_TABLE=$(echo "$ROUTE_RAW" | head -20 | while IFS= read -r line; do [[ -n "$line" ]] && echo "<tr><td>$(html_escape "$line")</td></tr>"; done || echo "")
unset ROUTE_RAW

# ======================== 进程检查 ========================
log_step "检查进程状态（僵尸/D状态/长运行）..."
ZOMBIE_COUNT=$(ps aux 2>/dev/null | awk '$8~/Z/{count++} END{print count+0}')
if (( ZOMBIE_COUNT > ZOMBIE_WARN )); then
    log_warn "发现 ${ZOMBIE_COUNT} 个僵尸进程"
    ZOMBIE_BADGE='<span class="badge warning">警告</span>'
    ZOMBIE_LIST=$(ps aux 2>/dev/null | awk '$8~/Z/' | head -10)
else
    ZOMBIE_BADGE='<span class="badge ok">正常</span>'
    ZOMBIE_LIST=""
fi

# D 状态进程(不可中断睡眠)
D_STATE_COUNT=$(ps aux 2>/dev/null | awk '$8~/D/{count++} END{print count+0}')
D_STATE_LIST=""
if (( D_STATE_COUNT > 0 )); then
    log_warn "发现 ${D_STATE_COUNT} 个 D 状态进程"
    D_STATE_LIST=$(ps aux 2>/dev/null | awk '$8~/D/' | head -5)
fi

# 运行时间最长的进程 TOP 5
LONG_RUNNING=$(ps -eo pid,user,etime,comm --sort=-etime 2>/dev/null | head -6 | awk 'NR>1{printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1, $2, $3, $4}' || echo "")

# ======================== 安全检查 ========================
log_step "执行安全检查（SSH/账户/SUID/登录）..."

# SSH 配置
SSH_ROOT="N/A"
SSH_PORT="22"
SSH_PROTOCOL=""
SSH_MAXAUTH=""
SSH_PUBKEY=""
if [[ -f /etc/ssh/sshd_config ]]; then
    SSH_ROOT=$(grep -i "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "默认(yes)")
    SSH_PORT=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    SSH_MAXAUTH=$(grep -i "^MaxAuthTries" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "默认(6)")
    SSH_PUBKEY=$(grep -i "^PubkeyAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "默认(yes)")
fi
[[ -z "$SSH_ROOT" ]] && SSH_ROOT="默认(yes)"
[[ -z "$SSH_MAXAUTH" ]] && SSH_MAXAUTH="默认(6)"
[[ -z "$SSH_PUBKEY" ]] && SSH_PUBKEY="默认(yes)"

# 账户安全审计
# UID=0 的账户
ROOT_USERS=$(awk -F: '$3==0{print $1}' /etc/passwd 2>/dev/null | xargs || echo "root")
# 空密码账户（$2=="" 表示真正的空密码，$2=="!"或"*"表示密码被锁定）
EMPTY_PASS=$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null | head -10 | xargs || echo "无")
# 可登录 shell 的账户
LOGIN_USERS=$(awk -F: '$7!~/nologin|false|sync|shutdown|halt/{print $1}' /etc/passwd 2>/dev/null | xargs || echo "N/A")
LOGIN_USER_COUNT=$(awk -F: '$7!~/nologin|false|sync|shutdown|halt/{count++} END{print count+0}' /etc/passwd 2>/dev/null || echo "0")

# 密码过期账户（提速：直接读 /etc/shadow 第 3,5 列计算，跳过逐个 chage fork）
# shadow 字段: user:hash:lastchange:min:max:warn:inactive:expire:
# 密码过期日期 = lastchange + max （单位：天，从 1970-01-01 起）
EXPIRE_USERS=""
if [[ -r /etc/shadow ]]; then
    now_days=$(( $(date +%s) / 86400 ))
    while IFS=: read -r user _ lastchange _ maxdays _ _ _; do
        # 跳过未设密码 / 永不过期 / 字段为空
        [[ -z "$lastchange" || -z "$maxdays" || "$maxdays" == "99999" || "$maxdays" -le 0 ]] && continue
        expire_day=$(( lastchange + maxdays ))
        days_left=$(( expire_day - now_days ))
        # 仅普通用户告警（UID >= 1000 或 root）
        uid=$(getent passwd "$user" 2>/dev/null | cut -d: -f3)
        [[ -z "$uid" ]] && continue
        (( uid < 1000 && uid != 0 )) && continue
        expire_date=$(date -d "1970-01-01 +${expire_day} days" '+%Y-%m-%d' 2>/dev/null || echo "$expire_day")
        if (( days_left < 0 )); then
            EXPIRE_USERS+="<tr><td>${user}</td><td>${expire_date}</td><td><span class=\"badge critical\">已过期</span></td></tr>"
        elif (( days_left < 7 )); then
            EXPIRE_USERS+="<tr><td>${user}</td><td>${expire_date}</td><td><span class=\"badge warning\">即将过期</span></td></tr>"
        fi
    done < /etc/shadow 2>/dev/null || true
fi

# 最近登录失败（lastb 需 root + /var/log/btmp 存在; 最小化镜像/容器常无 btmp）
FAIL_LOGINS=""
FAIL_COUNT="0"
if [[ "$(id -u)" -eq 0 ]] && [[ -r /var/log/btmp ]] && command -v lastb &>/dev/null; then
    FAIL_LOGINS=$(lastb 2>/dev/null | head -10 | awk 'NF>3{printf "<tr><td>%s</td><td>%s</td><td>%s %s %s</td></tr>\n", $1, $3, $4, $5, $6}' || echo "")
    FAIL_COUNT=$(lastb 2>/dev/null | grep -c "." 2>/dev/null || true)
    FAIL_COUNT=${FAIL_COUNT//[^0-9]/}; FAIL_COUNT=${FAIL_COUNT:-0}
fi

# 最近成功登录
SUCCESS_LOGINS=$(last -n 10 2>/dev/null | awk 'NF>3 && !/^$/ && !/wtmp/{printf "<tr><td>%s</td><td>%s</td><td>%s %s %s</td></tr>\n", $1, $3, $4, $5, $6}' || echo "")

# 可疑 SUID/SGID 文件（提速：合并成一次 find）
SUID_SGID_RAW=$(find /usr/local /opt /home /tmp /var/tmp \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %p\n' 2>/dev/null | head -40 || echo "")
SUID_FILES=$(echo "$SUID_SGID_RAW" | awk '$1+0 ~ /4..[0-7]/ || $1+0 ~ /^[4-7][0-9][0-9][0-9]$/ {print $2}' | head -10 || echo "")
SGID_FILES=$(echo "$SUID_SGID_RAW" | awk '$1+0 ~ /2..[0-7]|6..[0-7]/ {print $2}' | head -10 || echo "")
unset SUID_SGID_RAW
# 全局可写文件（限制搜索范围）
WORLD_WRITABLE=$(find /home /opt /usr/local /var -xdev -type f -perm -0002 ! -path "*/tmp/*" 2>/dev/null | head -10 || echo "")

# /tmp 目录大小
TMP_SIZE=$(du -sh /tmp 2>/dev/null | awk '{print $1}' || echo "N/A")
VAR_LOG_SIZE=$(du -sh /var/log 2>/dev/null | awk '{print $1}' || echo "N/A")

# ======================== 定时任务 ========================
log_step "检查定时任务（crontab/cron.d）..."
CRON_ROWS=""
# 系统 crontab
if [[ -f /etc/crontab ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        CRON_ROWS+="<tr><td>system</td><td>/etc/crontab</td><td>$(html_escape "$line")</td></tr>"
    done <<< "$(grep -vE "^#|^$|^[A-Z]" /etc/crontab 2>/dev/null || true)"
fi
# /etc/cron.d/
for f in /etc/cron.d/*; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        CRON_ROWS+="<tr><td>system</td><td>$(basename "$f")</td><td>$(html_escape "$line")</td></tr>"
    done <<< "$(grep -vE "^#|^$|^[A-Z]" "$f" 2>/dev/null || true)"
done
# 用户 crontab
for user_cron in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [[ -f "$user_cron" ]] || continue
    cron_user=$(basename "$user_cron")
    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        CRON_ROWS+="<tr><td>${cron_user}</td><td>用户crontab</td><td>$(html_escape "$line")</td></tr>"
    done <<< "$(grep -vE "^#|^$" "$user_cron" 2>/dev/null || true)"
done

# ======================== 服务检查 ========================
# v2.5: 通过 safe_service_status 走 systemctl → service → chkconfig → init.d 四级 fallback
#       CentOS 6 / RHEL 6 / 老 SUSE / 容器内 (无 systemd) 都能正确识别
log_step "检查关键服务状态（systemctl/service/chkconfig 自适应）..."
SERVICES=("sshd" "crond" "cron" "rsyslog" "syslog-ng" "firewalld" "ufw" "nftables" "iptables" "chronyd" "chrony" "ntpd" "ntp" "systemd-timesyncd" "openntpd" "docker" "podman" "containerd" "kubelet" "nginx" "httpd" "apache2" "mysqld" "mariadb" "postgresql" "redis-server" "redis" "mongod" "elasticsearch" "php-fpm" "tomcat" "supervisord" "zabbix-agent" "zabbix-agent2" "node_exporter" "prometheus" "grafana-server" "haproxy" "keepalived" "named" "bind9" "dnsmasq" "postfix" "dovecot" "vsftpd" "smbd" "winbind" "sssd" "NetworkManager")
SVC_ROWS=""
# 提速: 一次性把 systemd unit-files 缓存到 ALL_UNITS, safe_service_status 内部用
if has_systemd; then
    ALL_UNITS=$(systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true)
else
    ALL_UNITS=""
fi
for svc in "${SERVICES[@]}"; do
    status=$(safe_service_status "$svc")
    [[ "$status" == "notfound" ]] && continue   # 该服务在本机不存在,不展示
    enabled=$(safe_service_enabled "$svc")
    if [[ "$status" == "active" ]]; then
        badge='<span class="badge ok">运行中</span>'
    elif [[ "$status" == "inactive" ]]; then
        badge='<span class="badge warning">已停止</span>'
    else
        badge='<span class="badge critical">异常</span>'
    fi
    SVC_ROWS+="<tr><td>${svc}</td><td>${badge}</td><td>${enabled}</td></tr>"
done

# 最近失败的服务 (仅 systemd; sysvinit 没这个概念)
if has_systemd; then
    FAILED_SVCS=$(systemctl --failed --no-pager 2>/dev/null | grep "loaded" | awk '{printf "<tr><td>%s</td><td><span class=\"badge critical\">FAILED</span></td><td>%s</td></tr>\n", $2, $4}' || echo "")
else
    FAILED_SVCS=""
fi

# ======================== Docker 检查 ========================
log_step "检查 Docker 容器..."
DOCKER_ROWS=""
DOCKER_IMAGES=""
# v2.5: 优先 docker,否则 podman (RHEL 8+ / Fedora 31+ 默认), 两者 CLI 兼容
CTR_CMD=$(container_cmd)
if [[ -n "$CTR_CMD" ]]; then
    log_debug "容器运行时: ${CTR_CMD}"
    DOCKER_VERSION=$("$CTR_CMD" version --format '{{.Server.Version}}' 2>/dev/null || "$CTR_CMD" --version 2>/dev/null | awk '{print $NF}' || echo "N/A")
    DOCKER_CONTAINERS=$("$CTR_CMD" ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true)
    while IFS= read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        image=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3, $4, $5}')
        badge='<span class="badge ok">运行中</span>'
        if echo "$status" | grep -qi "exited\|dead\|created"; then
            badge='<span class="badge warning">已停止</span>'
        fi
        DOCKER_ROWS+="<tr><td>${name}</td><td>${image}</td><td>${status}</td><td>${badge}</td></tr>"
    done <<< "$("$CTR_CMD" ps -a --format "{{.Names}} {{.Image}} {{.Status}}" 2>/dev/null || true)"
    DOCKER_IMAGES=$("$CTR_CMD" images --format "{{.Repository}}:{{.Tag}} {{.Size}}" 2>/dev/null | head -15 | while read -r img size; do echo "<tr><td>${img}</td><td>${size}</td></tr>"; done || true)
    DOCKER_DISK=$("$CTR_CMD" system df 2>/dev/null || true)
else
    log_debug "未检测到 Docker / Podman"
fi

# ======================== 内核参数 ========================
log_step "检查内核参数（sysctl）..."
KERN_ROWS=""
KERN_PARAMS=(
    "net.ipv4.tcp_syncookies|TCP SYN Cookies|1"
    "net.ipv4.ip_forward|IP 转发|视需求"
    "net.ipv4.tcp_max_syn_backlog|SYN 队列长度|>=1024"
    "net.core.somaxconn|Socket 最大连接队列|>=1024"
    "net.ipv4.tcp_tw_reuse|TIME_WAIT 重用|1"
    "net.ipv4.tcp_fin_timeout|FIN 超时|<=30"
    "net.ipv4.tcp_keepalive_time|Keepalive 时间|<=600"
    "net.core.netdev_max_backlog|网卡积压队列|>=1000"
    "vm.swappiness|Swap 倾向|<=30"
    "vm.overcommit_memory|内存过量分配|视需求"
    "fs.file-max|系统最大文件描述符|>=65535"
    "net.ipv4.conf.all.rp_filter|反向路径过滤|1"
    "kernel.panic|内核 panic 重启|>0"
)
for item in "${KERN_PARAMS[@]}"; do
    IFS='|' read -r param desc recommend <<< "$item"
    val=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    KERN_ROWS+="<tr><td>${param}</td><td>${desc}</td><td>${val}</td><td>${recommend}</td></tr>"
done

# ======================== 系统更新 ========================
if (( SKIP_UPDATE_CHECK == 1 )); then
    log_step "检查系统更新状态（已跳过 --skip-update-check）"
else
    log_step "检查系统更新状态（包管理器）..."
fi
UPDATE_INFO="N/A"
UPDATE_COUNT=0
LAST_UPDATE="N/A"
SEC_UPDATES=""
# v2.5: 直接复用 detect_os 的 OS_FAMILY (兼容更多发行版), 不再单独识别
OS_TYPE="${OS_FAMILY:-other}"

check_updates() {
    local pkg_manager=$1
    case "$pkg_manager" in
        yum)
            if command -v yum &>/dev/null; then
                # yum check-update 有更新时 exit 100, 加上 set -o pipefail 会让 pipeline 整体失败
                # 用 || true 吞退出码, 再用 sanitize 确保是纯数字 (避免 "158\n0" 这种被 grep 输出 + echo fallback 拼出来的脏数据)
                UPDATE_COUNT=$(yum check-update --quiet 2>/dev/null | grep -cE "^[a-zA-Z]" || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="yum: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(rpm -qa --last 2>/dev/null | head -1 | awk '{print $2, $3, $4, $5}' || echo "N/A")
                return 0
            fi
            ;;
        dnf)
            if command -v dnf &>/dev/null; then
                # dnf check-update 同 yum: 有更新时 exit 100
                UPDATE_COUNT=$(dnf check-update --quiet 2>/dev/null | grep -cE "^[a-zA-Z]" || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="dnf: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(rpm -qa --last 2>/dev/null | head -1 | awk '{print $2, $3, $4, $5}' || echo "N/A")
                return 0
            fi
            ;;
        apt)
            if command -v apt &>/dev/null; then
                if [[ "$(id -u)" -eq 0 ]]; then
                    apt update -qq 2>/dev/null || true
                fi
                # grep -c 找不到匹配时 exit 1, pipefail 会让 pipeline 失败
                UPDATE_COUNT=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="apt: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(stat -c %y /var/cache/apt/pkgcache.bin 2>/dev/null | cut -d' ' -f1 || echo "N/A")
                return 0
            fi
            ;;
        zypper)
            if command -v zypper &>/dev/null; then
                UPDATE_COUNT=$(zypper list-updates 2>/dev/null | grep -c "^v" || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="zypper: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(rpm -qa --last 2>/dev/null | head -1 | awk '{print $2, $3, $4, $5}' || echo "N/A")
                return 0
            fi
            ;;
        pacman)
            # v2.5: Arch / Manjaro
            if command -v pacman &>/dev/null; then
                UPDATE_COUNT=$( { checkupdates 2>/dev/null || pacman -Qu 2>/dev/null; } | grep -c . || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="pacman: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(awk '/upgraded|installed/{t=$1" "$2} END{print t}' /var/log/pacman.log 2>/dev/null | tr -d '[]' || echo "N/A")
                return 0
            fi
            ;;
        apk)
            # v2.5: Alpine
            if command -v apk &>/dev/null; then
                apk update >/dev/null 2>&1 || true
                UPDATE_COUNT=$(apk version -l '<' 2>/dev/null | grep -c . || true)
                UPDATE_COUNT=${UPDATE_COUNT//[^0-9]/}; UPDATE_COUNT=${UPDATE_COUNT:-0}
                UPDATE_INFO="apk: ${UPDATE_COUNT} 个可用更新"
                LAST_UPDATE=$(stat -c %y /var/cache/apk 2>/dev/null | cut -d' ' -f1 || echo "N/A")
                return 0
            fi
            ;;
    esac
    return 1
}

if (( SKIP_UPDATE_CHECK == 0 )); then
    # v2.5: OS_FAMILY 路由到包管理器, 最终兜底全试一遍 (容器/混合系统也能覆盖)
    case "$OS_TYPE" in
        kylin|uos) check_updates dnf || check_updates yum || check_updates apt ;;
        rhel)      check_updates dnf || check_updates yum ;;
        debian)    check_updates apt ;;
        suse)      check_updates zypper ;;
        arch)      check_updates pacman ;;
        alpine)    check_updates apk ;;
        *)         check_updates dnf || check_updates yum || check_updates apt || check_updates zypper || check_updates pacman || check_updates apk ;;
    esac

    # 安全更新计数 (同样的 grep -c + pipefail 坑, 用 || true + 数字 sanitize)
    if command -v dnf &>/dev/null; then
        SEC_UPDATES=$(dnf updateinfo list security 2>/dev/null | grep -c "security" || true)
    elif command -v yum &>/dev/null; then
        SEC_UPDATES=$(yum updateinfo list security 2>/dev/null | grep -c "security" || true)
    elif command -v apt &>/dev/null; then
        SEC_UPDATES=$(apt list --upgradable 2>/dev/null | grep -ci "security" || true)
    elif command -v zypper &>/dev/null; then
        SEC_UPDATES=$(zypper list-updates --type patch 2>/dev/null | grep -c "security" || true)
    fi
    SEC_UPDATES=${SEC_UPDATES//[^0-9]/}; SEC_UPDATES=${SEC_UPDATES:-0}
    SEC_UPDATES="${SEC_UPDATES} 个安全更新"

    if [[ "$OS_TYPE" == "kylin" ]]; then
        UPDATE_INFO="[Kylin] ${UPDATE_INFO}"
        if [[ -z "$SEC_UPDATES" ]]; then
            SEC_UPDATES="建议通过麒麟软件中心检查安全更新"
        fi
    fi
else
    UPDATE_INFO="已跳过（--skip-update-check）"
    SEC_UPDATES="已跳过"
fi

# ======================== 日志检查 ========================
log_step "检查系统日志（异常/OOM/认证）..."
SYSLOG_ERRORS=""
if [[ -f /var/log/messages ]]; then
    SYSLOG_ERRORS=$(grep -iE "error|fail|critical|panic|oom" /var/log/messages 2>/dev/null | tail -"$LOG_LINES" || true)
elif [[ -f /var/log/syslog ]]; then
    SYSLOG_ERRORS=$(grep -iE "error|fail|critical|panic|oom" /var/log/syslog 2>/dev/null | tail -"$LOG_LINES" || true)
else
    SYSLOG_ERRORS=$(journalctl -p err --no-pager -n "$LOG_LINES" 2>/dev/null || echo "无法读取日志")
fi

# 提速: dmesg 一次性缓存供 OOM + 硬件错误共用
# v2.5: 内核 5.0+ 默认 dmesg_restrict=1 + 非 root 会失败, 改 safe_dmesg() 走 journalctl -k fallback
DMESG_CACHE=$(safe_dmesg)

# OOM 检查
OOM_COUNT=$(echo "$DMESG_CACHE" | grep -ci "oom\|out of memory" 2>/dev/null || true)
OOM_COUNT=${OOM_COUNT//[^0-9]/}; OOM_COUNT=${OOM_COUNT:-0}
if (( OOM_COUNT > 0 )); then
    log_warn "检测到 ${OOM_COUNT} 次 OOM 事件"
fi

# dmesg 硬件错误
HW_ERRORS=$(echo "$DMESG_CACHE" | grep -iE "hardware error|machine check|ecc|i/o error|medium error" | tail -5 || true)
unset DMESG_CACHE  # 释放内存（dmesg 可能很大）

# 认证日志
AUTH_ERRORS=""
if [[ -f /var/log/auth.log ]]; then
    AUTH_ERRORS=$(grep -iE "failed|invalid|error" /var/log/auth.log 2>/dev/null | tail -10 || true)
elif [[ -f /var/log/secure ]]; then
    AUTH_ERRORS=$(grep -iE "failed|invalid|error" /var/log/secure 2>/dev/null | tail -10 || true)
fi

# ======================== NTP 时间同步 ========================
# v2.5: chronyd / ntpd (ntpq/ntpstat) / systemd-timesyncd / openntpd 四套时间源全识别
log_step "检查 NTP 时间同步..."
NTP_STATUS="未配置"
NTP_BADGE='<span class="badge warning">警告</span>'
NTP_DETAIL=""
if command -v chronyc &>/dev/null && safe_service_status chronyd 2>/dev/null | grep -qE "active|inactive"; then
    NTP_STATUS=$(chronyc tracking 2>/dev/null | awk -F': *' '/Leap status/{print $2; exit}' | xargs || echo "未同步")
    NTP_DETAIL=$(chronyc sources 2>/dev/null | head -10 || true)
    [[ "$NTP_STATUS" == "Normal" ]] && NTP_BADGE='<span class="badge ok">正常</span>' && NTP_STATUS="已同步 (chronyd)"
elif command -v ntpq &>/dev/null && ntpq -pn 2>/dev/null | grep -qE '^\*'; then
    NTP_STATUS="已同步 (ntpd)"
    NTP_BADGE='<span class="badge ok">正常</span>'
    NTP_DETAIL=$(ntpq -pn 2>/dev/null | head -10 || true)
elif command -v ntpstat &>/dev/null; then
    if ntpstat &>/dev/null; then
        NTP_STATUS="已同步 (ntpd)"
        NTP_BADGE='<span class="badge ok">正常</span>'
    else
        NTP_STATUS="未同步"
    fi
elif command -v timedatectl &>/dev/null && timedatectl show 2>/dev/null | grep -q '^NTPSynchronized=yes'; then
    NTP_STATUS="已同步 (systemd-timesyncd)"
    NTP_BADGE='<span class="badge ok">正常</span>'
elif timedatectl 2>/dev/null | grep -qE "synchronized:[[:space:]]+yes|NTP synchronized:[[:space:]]+yes"; then
    NTP_STATUS="已同步 (systemd-timesyncd)"
    NTP_BADGE='<span class="badge ok">正常</span>'
elif command -v ntpctl &>/dev/null && ntpctl -s status 2>/dev/null | grep -q 'clock synced'; then
    # OpenBSD/Alpine 上的 openntpd
    NTP_STATUS="已同步 (openntpd)"
    NTP_BADGE='<span class="badge ok">正常</span>'
fi

# ======================== SSL 证书过期检查 ========================
SSL_ROWS=""
SSL_TOTAL=0
SSL_EXPIRING=0
SSL_EXPIRED=0
if (( SKIP_SSL_CHECK == 1 )); then
    log_step "检查 SSL 证书过期（已跳过 --skip-ssl-check）"
elif command -v openssl &>/dev/null; then
    log_step "检查 SSL 证书过期..."
    SSL_PATHS=(
        "/etc/letsencrypt/live"
        "/etc/ssl/certs"
        "/etc/pki/tls/certs"
        "/etc/nginx/ssl"
        "/etc/nginx/conf.d"
        "/etc/httpd/conf.d"
        "/usr/local/nginx/conf"
    )
    declare -A SSL_SEEN=()
    while IFS= read -r cert; do
        [[ -z "$cert" ]] && continue
        # 去重（同一个证书可能被软链多次指向）
        real_cert=$(readlink -f "$cert" 2>/dev/null || echo "$cert")
        [[ -n "${SSL_SEEN[$real_cert]:-}" ]] && continue
        SSL_SEEN[$real_cert]=1

        end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        [[ -z "$end_date" ]] && continue
        end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
        (( end_epoch == 0 )) && continue
        now_epoch=$(date +%s)
        days_left=$(( (end_epoch - now_epoch) / 86400 ))

        cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/.*CN *= *\([^/,]*\).*/\1/' | xargs)
        [[ -z "$cn" ]] && cn="(no CN)"

        SSL_TOTAL=$((SSL_TOTAL + 1))
        if (( days_left < 0 )); then
            badge='<span class="badge critical">已过期</span>'
            log_error "SSL 证书已过期: ${cn} (${cert})"
            SSL_EXPIRED=$((SSL_EXPIRED + 1))
        elif (( days_left < SSL_CERT_DAYS_WARN )); then
            badge='<span class="badge warning">即将过期</span>'
            log_warn "SSL 证书 ${days_left} 天后过期: ${cn} (${cert})"
            SSL_EXPIRING=$((SSL_EXPIRING + 1))
        else
            badge='<span class="badge ok">正常</span>'
        fi
        SSL_ROWS+="<tr><td>$(html_escape "$cn")</td><td>$(html_escape "$cert")</td><td>${end_date}</td><td>${days_left}</td><td>${badge}</td></tr>"
    done < <(for p in "${SSL_PATHS[@]}"; do
        [[ -d "$p" ]] || continue
        find "$p" -type f \( -name "*.pem" -o -name "*.crt" -o -name "fullchain*.pem" -o -name "cert.pem" \) 2>/dev/null
    done | head -50)
    log_debug "SSL 证书共扫描 ${SSL_TOTAL} 个，即将过期 ${SSL_EXPIRING}，已过期 ${SSL_EXPIRED}"
fi

# ======================== 生成 HTML 报告 ========================
log_step "生成报告（${OUTPUT_FORMAT}）..."

CPU_COLOR=$(get_color_class "$CPU_USAGE" "$CPU_WARN")
MEM_COLOR=$(get_color_class "$MEM_USAGE" "$MEM_WARN")
DISK_COLOR="green"
(( DISK_ALERT > 0 )) && DISK_COLOR="orange"
WARN_COLOR=$(get_color_class "$WARN_COUNT" "$WARN_BADGE_THRESHOLD")

# 顶部色条 class 映射: green→s-ok, orange→s-warn, red→s-crit
color_to_status() {
    case "$1" in
        red) echo "s-crit" ;;
        orange) echo "s-warn" ;;
        *) echo "s-ok" ;;
    esac
}
CPU_S=$(color_to_status "$CPU_COLOR")
MEM_S=$(color_to_status "$MEM_COLOR")
DISK_S=$(color_to_status "$DISK_COLOR")
WARN_S=$(color_to_status "$WARN_COLOR")

color_to_label() {
    case "$1" in
        red) echo "严重" ;;
        orange) echo "警告" ;;
        *) echo "良好" ;;
    esac
}
CPU_LBL=$(color_to_label "$CPU_COLOR")
MEM_LBL=$(color_to_label "$MEM_COLOR")
DISK_LBL=$(color_to_label "$DISK_COLOR")
WARN_LBL=$(color_to_label "$WARN_COLOR")

cat >> "$REPORT_FILE" <<EOF
<div class="summary" id="sec-summary">
  <div class="summary-card ${CPU_S}">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M9 2v2H7v2H5v12h2v2h2v2h6v-2h2v-2h2V6h-2V4h-2V2H9zm0 4h6v2h2v8h-2v2H9v-2H7V8h2V6zm2 2v2h2V8h-2zm0 4v2h2v-2h-2z"/></svg></div>
    <div class="body">
      <div class="num ${CPU_COLOR}">${CPU_USAGE}%</div>
      <div class="label">CPU<span class="status ${CPU_COLOR}">${CPU_LBL}</span></div>
    </div>
  </div>
  <div class="summary-card ${MEM_S}">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M3 6h18v3H3zM3 11h18v3H3zM3 16h18v3H3zM6 7h2v1H6zM6 12h2v1H6zM6 17h2v1H6z"/></svg></div>
    <div class="body">
      <div class="num ${MEM_COLOR}">${MEM_USAGE}%</div>
      <div class="label">内存<span class="status ${MEM_COLOR}">${MEM_LBL}</span></div>
    </div>
  </div>
  <div class="summary-card ${DISK_S}">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm0-13a5 5 0 100 10 5 5 0 000-10zm0 8a3 3 0 110-6 3 3 0 010 6z"/></svg></div>
    <div class="body">
      <div class="num ${DISK_COLOR}">${DISK_ALERT}</div>
      <div class="label">磁盘告警<span class="status ${DISK_COLOR}">${DISK_LBL}</span></div>
    </div>
  </div>
  <div class="summary-card s-info">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/></svg></div>
    <div class="body">
      <div class="num green">${LOAD_1}</div>
      <div class="label">负载 1m</div>
    </div>
  </div>
  <div class="summary-card s-purple">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M12 1l-9 4v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg></div>
    <div class="body">
      <div class="num green">${CONN_TOTAL}</div>
      <div class="label">TCP 连接</div>
    </div>
  </div>
  <div class="summary-card ${WARN_S}">
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z"/></svg></div>
    <div class="body">
      <div class="num ${WARN_COLOR}">${WARN_COUNT}</div>
      <div class="label">警告<span class="status ${WARN_COLOR}">${WARN_LBL}</span></div>
    </div>
  </div>
</div>

<!-- 基本信息 -->
<div class="section" id="sec-info">
  <h2><span class="num">1.</span>基本信息</h2>
  <div class="info-grid">
    <div class="info-item"><span class="key">主机名</span><span class="val">${HOSTNAME_VAL}</span></div>
    <div class="info-item"><span class="key">FQDN</span><span class="val">${HOSTNAME_FQDN}</span></div>
    <div class="info-item"><span class="key">IP 地址</span><span class="val">${IP_ALL}</span></div>
    <div class="info-item"><span class="key">操作系统</span><span class="val">${OS_VERSION}</span></div>
    <div class="info-item"><span class="key">内核版本</span><span class="val">${KERNEL}</span></div>
    <div class="info-item"><span class="key">架构</span><span class="val">${ARCH}</span></div>
    <div class="info-item"><span class="key">运行时间</span><span class="val">${UPTIME} (${UPTIME_DAYS}天)</span></div>
    <div class="info-item"><span class="key">启动时间</span><span class="val">${BOOT_TIME}</span></div>
    <div class="info-item"><span class="key">时区</span><span class="val">${TIMEZONE}</span></div>
    <div class="info-item"><span class="key">CPU 型号</span><span class="val">${CPU_MODEL}</span></div>
    <div class="info-item"><span class="key">CPU 核数/插槽</span><span class="val">${CPU_CORES}核 / ${CPU_SOCKETS}路</span></div>
    <div class="info-item"><span class="key">总内存</span><span class="val">${MEM_TOTAL}</span></div>
    <div class="info-item"><span class="key">当前用户</span><span class="val">${CURRENT_USERS}人 (${CURRENT_USERS_LIST})</span></div>
    <div class="info-item"><span class="key">进程/线程</span><span class="val">${PROCESS_COUNT} / ${THREAD_COUNT}</span></div>
    <div class="info-item"><span class="key">SELinux</span><span class="val">${SELINUX_STATUS}</span></div>
    <div class="info-item"><span class="key">防火墙</span><span class="val">${FIREWALL_STATUS}</span></div>
    <div class="info-item"><span class="key">时间同步</span><span class="val">${NTP_STATUS} ${NTP_BADGE}</span></div>
    <div class="info-item"><span class="key">默认网关</span><span class="val">${DEFAULT_GW}</span></div>
    <div class="info-item"><span class="key">DNS 服务器</span><span class="val">${DNS_SERVERS}</span></div>
    <div class="info-item"><span class="key">虚拟化</span><span class="val">${VIRT_TYPE}</span></div>
    <div class="info-item"><span class="key">厂商/型号</span><span class="val">${VENDOR} ${PRODUCT}</span></div>
    <div class="info-item"><span class="key">序列号</span><span class="val">${SERIAL}</span></div>
    <div class="info-item"><span class="key">BIOS 版本</span><span class="val">${BIOS_VER}</span></div>
  </div>
</div>

<!-- CPU & 负载 -->
<div class="section" id="sec-cpu">
  <h2><span class="num">2.</span>CPU &amp; 负载</h2>
  <table>
    <tr><th>指标</th><th>当前值</th><th>阈值</th><th>状态</th></tr>
    <tr><td>CPU 使用率</td><td>${CPU_USAGE}%</td><td>${CPU_WARN}%</td><td>${CPU_BADGE}</td></tr>
    <tr><td>负载(1/5/15分钟)</td><td>${LOAD_1} / ${LOAD_5} / ${LOAD_15}</td><td>核数x${LOAD_WARN_FACTOR}=${LOAD_WARN_VAL}</td><td>${LOAD_BADGE}</td></tr>
    <tr><td>运行中进程/总进程</td><td>${RUNNING_PROCS}</td><td>-</td><td><span class="badge info">信息</span></td></tr>
  </table>
  <h3>CPU 占用 TOP 10 进程</h3>
  <table>
    <tr><th class="col-name">用户</th><th class="col-value">PID</th><th class="col-pct">CPU%</th><th class="col-pct">MEM%</th><th class="col-cmd">命令</th></tr>
    ${CPU_TOP}
  </table>
</div>

<!-- 内存 & Swap -->
<div class="section" id="sec-mem">
  <h2><span class="num">3.</span>内存 &amp; Swap</h2>
  <table>
    <tr><th>指标</th><th>当前值</th><th>阈值</th><th>状态</th></tr>
    <tr><td>内存使用率</td><td>${MEM_USAGE}%</td><td>${MEM_WARN}%</td><td>${MEM_BADGE}</td></tr>
    <tr><td>Swap 使用率</td><td>${SWAP_USAGE}% (${SWAP_USED}/${SWAP_TOTAL})</td><td>${SWAP_WARN}%</td><td>${SWAP_BADGE}</td></tr>
  </table>
  <h3>内存详细</h3>
  <pre>$(html_escape "$MEM_DETAIL")</pre>
  <h3>内存占用 TOP 10 进程</h3>
  <table>
    <tr><th class="col-name">用户</th><th class="col-value">PID</th><th class="col-pct">CPU%</th><th class="col-pct">MEM%</th><th class="col-cmd">命令</th></tr>
    ${MEM_TOP}
  </table>
</div>

<!-- 磁盘使用 -->
<div class="section" id="sec-disk">
  <h2><span class="num">4.</span>磁盘使用</h2>
  <table>
    <tr><th class="col-fs">文件系统</th><th class="col-size">大小</th><th class="col-size">已用</th><th class="col-size">可用</th><th class="col-usage">使用率</th><th class="col-mount">挂载点</th><th class="col-status">状态</th></tr>
    ${DISK_ROWS}
  </table>
  <h3>Inode 使用情况</h3>
  <table>
    <tr><th>文件系统</th><th>Inode 使用率</th><th>挂载点</th><th>状态</th></tr>
    ${INODE_ROWS}
  </table>
EOF

# 磁盘 I/O
if [[ -n "$DISK_IO_ROWS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>磁盘 I/O 统计</h3>
  <table>
    <tr><th>设备</th><th>TPS</th><th>读(KB/s)</th><th>写(KB/s)</th></tr>
    ${DISK_IO_ROWS}
  </table>
EOF
fi

cat >> "$REPORT_FILE" <<EOF
  <div class="two-col" style="margin-top:14px;">
    <div class="mini-card"><h4>/tmp 大小</h4><span style="font-size:18px;font-weight:bold;">${TMP_SIZE}</span></div>
    <div class="mini-card"><h4>/var/log 大小</h4><span style="font-size:18px;font-weight:bold;">${VAR_LOG_SIZE}</span></div>
  </div>
</div>

<!-- 大文件 -->
<div class="section" id="sec-large">
  <h2><span class="num">5.</span>大文件分析</h2>
EOF

if [[ -n "$LARGE_FILES" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>大文件 TOP 10 (>100M)</h3>
  <table>
    <tr><th class="col-size">大小</th><th class="col-path">路径</th></tr>
    ${LARGE_FILES}
  </table>
EOF
else
    echo "  <p style='color:#999;font-size:13px;'>未发现超过 100M 的大文件</p>" >> "$REPORT_FILE"
fi

if [[ -n "$RECENT_LARGE" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>最近7天修改的大文件 (>50M)</h3>
  <table>
    <tr><th class="col-size">大小</th><th class="col-path">路径</th></tr>
    ${RECENT_LARGE}
  </table>
EOF
fi

cat >> "$REPORT_FILE" <<EOF
</div>

<!-- 文件描述符 -->
<div class="section" id="sec-fd">
  <h2><span class="num">6.</span>文件描述符</h2>
  <table>
    <tr><th>指标</th><th>当前值</th><th>最大值</th><th>使用率</th><th>状态</th></tr>
    <tr><td>系统 FD</td><td>${FD_CURRENT}</td><td>${FD_MAX}</td><td>${FD_PCT}%</td><td>${FD_BADGE}</td></tr>
  </table>
EOF

if [[ -n "$FD_TOP" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>FD 使用 TOP 5 进程</h3>
  <table>
    <tr><th>进程名</th><th>PID</th><th>FD 数</th></tr>
    ${FD_TOP}
  </table>
EOF
fi

cat >> "$REPORT_FILE" <<EOF
</div>

<!-- 网络状态 -->
<div class="section" id="sec-net">
  <h2><span class="num">7.</span>网络状态</h2>
  <h3>网卡信息</h3>
  <table>
    <tr><th>网卡</th><th>IP</th><th>MAC</th><th>速率</th><th>流量(累计)</th><th>错误/丢包</th><th>状态</th></tr>
    ${NIC_ROWS}
  </table>
  <h3>TCP 连接统计</h3>
  <table>
    <tr><th>ESTABLISHED</th><th>TIME_WAIT</th><th>CLOSE_WAIT</th><th>SYN_RECV</th><th>LISTEN</th><th>总计</th></tr>
    <tr><td>${CONN_ESTABLISHED}</td><td>${CONN_TIME_WAIT}</td><td>${CONN_CLOSE_WAIT}</td><td>${CONN_SYN_RECV}</td><td>${CONN_LISTEN}</td><td>${CONN_TOTAL}</td></tr>
  </table>
  <h3>监听端口 (前30)</h3>
  <table>
    <tr><th class="col-port">地址:端口</th><th class="col-value">协议</th><th class="col-proc">进程</th></tr>
    ${LISTEN_PORTS}
  </table>
  <h3>路由表</h3>
  <table>
    <tr><th>路由条目</th></tr>
    ${ROUTE_TABLE}
  </table>
</div>

<!-- 进程检查 -->
<div class="section" id="sec-proc">
  <h2><span class="num">8.</span>进程检查</h2>
  <table>
    <tr><th>检查项</th><th>结果</th><th>状态</th></tr>
    <tr><td>僵尸进程(Z)</td><td>${ZOMBIE_COUNT}</td><td>${ZOMBIE_BADGE}</td></tr>
    <tr><td>D 状态进程</td><td>${D_STATE_COUNT}</td><td>$(if (( D_STATE_COUNT > 0 )); then echo '<span class="badge warning">警告</span>'; else echo '<span class="badge ok">正常</span>'; fi)</td></tr>
  </table>
EOF

if [[ -n "$ZOMBIE_LIST" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>僵尸进程详情</h3>
  <pre>$(html_escape "$ZOMBIE_LIST")</pre>
EOF
fi

if [[ -n "$D_STATE_LIST" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>D 状态进程详情</h3>
  <pre>$(html_escape "$D_STATE_LIST")</pre>
EOF
fi

if [[ -n "$LONG_RUNNING" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>运行时间最长的进程 TOP 5</h3>
  <table>
    <tr><th>PID</th><th>用户</th><th>运行时间</th><th>进程名</th></tr>
    ${LONG_RUNNING}
  </table>
EOF
fi

cat >> "$REPORT_FILE" <<EOF
</div>

<!-- 服务状态 -->
<div class="section" id="sec-svc">
  <h2><span class="num">9.</span>服务状态</h2>
  <table>
    <tr><th>服务名</th><th>运行状态</th><th>开机自启</th></tr>
    ${SVC_ROWS}
  </table>
EOF

if [[ -n "$FAILED_SVCS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>失败的服务 (systemctl --failed)</h3>
  <table>
    <tr><th>服务</th><th>状态</th><th>说明</th></tr>
    ${FAILED_SVCS}
  </table>
EOF
fi

cat >> "$REPORT_FILE" <<EOF
</div>
EOF

# Docker 部分
if [[ -n "$DOCKER_ROWS" ]] || [[ -n "$DOCKER_IMAGES" ]]; then
    cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-docker">
  <h2><span class="num">10.</span>Docker 容器</h2>
  <p style="font-size:12px;color:#888;margin-bottom:10px;">Docker 版本: ${DOCKER_VERSION:-N/A}</p>
  <h3>容器列表</h3>
  <table>
    <tr><th>容器名</th><th>镜像</th><th>状态</th><th>运行状态</th></tr>
    ${DOCKER_ROWS}
  </table>
EOF
    if [[ -n "$DOCKER_IMAGES" ]]; then
        cat >> "$REPORT_FILE" <<EOF
  <h3>镜像列表 (前15)</h3>
  <table>
    <tr><th>镜像</th><th>大小</th></tr>
    ${DOCKER_IMAGES}
  </table>
EOF
    fi
    if [[ -n "${DOCKER_DISK:-}" ]]; then
        cat >> "$REPORT_FILE" <<EOF
  <h3>Docker 磁盘占用</h3>
  <pre>$(html_escape "$DOCKER_DISK")</pre>
EOF
    fi
    echo "</div>" >> "$REPORT_FILE"
fi

# 定时任务
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-cron">
  <h2><span class="num">11.</span>定时任务</h2>
EOF
if [[ -n "$CRON_ROWS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <table>
    <tr><th>用户</th><th>来源</th><th>任务内容</th></tr>
    ${CRON_ROWS}
  </table>
EOF
else
    echo "  <p style='color:#999;font-size:13px;'>未发现定时任务</p>" >> "$REPORT_FILE"
fi
echo "</div>" >> "$REPORT_FILE"

# 安全检查
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-security">
  <h2><span class="num">12.</span>安全检查</h2>
  <h3>SSH 配置</h3>
  <table>
    <tr><th>配置项</th><th>当前值</th><th>建议</th></tr>
    <tr><td>Root 登录</td><td>${SSH_ROOT}</td><td>建议设为 no 或 prohibit-password</td></tr>
    <tr><td>SSH 端口</td><td>${SSH_PORT}</td><td>建议修改默认端口</td></tr>
    <tr><td>最大认证次数</td><td>${SSH_MAXAUTH}</td><td>建议 <=3</td></tr>
    <tr><td>密钥认证</td><td>${SSH_PUBKEY}</td><td>建议 yes</td></tr>
    <tr><td>SELinux</td><td>${SELINUX_STATUS}</td><td>建议 Enforcing</td></tr>
    <tr><td>防火墙</td><td>${FIREWALL_STATUS}</td><td>建议开启</td></tr>
  </table>
  <h3>账户审计</h3>
  <table>
    <tr><th>检查项</th><th>结果</th></tr>
    <tr><td>UID=0 的账户</td><td>${ROOT_USERS}</td></tr>
    <tr><td>可登录 Shell 账户数</td><td>${LOGIN_USER_COUNT} (${LOGIN_USERS})</td></tr>
    <tr><td>登录失败总次数</td><td>${FAIL_COUNT}</td></tr>
  </table>
EOF

if [[ -n "$EXPIRE_USERS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>密码过期/即将过期账户</h3>
  <table>
    <tr><th>用户</th><th>过期时间</th><th>状态</th></tr>
    ${EXPIRE_USERS}
  </table>
EOF
fi

if [[ -n "$FAIL_LOGINS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>最近登录失败记录 (前10)</h3>
  <table>
    <tr><th>用户</th><th>来源IP</th><th>时间</th></tr>
    ${FAIL_LOGINS}
  </table>
EOF
fi

if [[ -n "$SUCCESS_LOGINS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>最近成功登录记录</h3>
  <table>
    <tr><th>用户</th><th>来源</th><th>时间</th></tr>
    ${SUCCESS_LOGINS}
  </table>
EOF
fi

if [[ -n "$SUID_FILES" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>可疑 SUID 文件</h3>
  <pre>$(html_escape "$SUID_FILES")</pre>
EOF
fi

if [[ -n "$SGID_FILES" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>可疑 SGID 文件</h3>
  <pre>$(html_escape "$SGID_FILES")</pre>
EOF
fi

if [[ -n "$WORLD_WRITABLE" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>全局可写文件</h3>
  <pre>$(html_escape "$WORLD_WRITABLE")</pre>
EOF
fi

echo "</div>" >> "$REPORT_FILE"

# 内核参数
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-kernel">
  <h2><span class="num">13.</span>内核参数</h2>
  <table>
    <tr><th>参数</th><th>说明</th><th>当前值</th><th>建议值</th></tr>
    ${KERN_ROWS}
  </table>
</div>
EOF

# 系统更新
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-update">
  <h2><span class="num">14.</span>系统更新</h2>
  <table>
    <tr><th>检查项</th><th>结果</th></tr>
    <tr><td>可用更新</td><td>${UPDATE_INFO}</td></tr>
    <tr><td>安全更新</td><td>${SEC_UPDATES:-N/A}</td></tr>
    <tr><td>最近安装/更新</td><td>${LAST_UPDATE:-N/A}</td></tr>
  </table>
</div>
EOF

# SSL 证书
if (( SSL_TOTAL > 0 )); then
    ssl_summary_badge='<span class="badge ok">正常</span>'
    if (( SSL_EXPIRED > 0 )); then
        ssl_summary_badge='<span class="badge critical">'${SSL_EXPIRED}' 已过期</span>'
    elif (( SSL_EXPIRING > 0 )); then
        ssl_summary_badge='<span class="badge warning">'${SSL_EXPIRING}' 即将过期</span>'
    fi
    cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-ssl">
  <h2><span class="num">15.</span>SSL 证书</h2>
  <p style="font-size:13px;color:#666;margin-bottom:10px;">共扫描 ${SSL_TOTAL} 个证书 ${ssl_summary_badge}（告警阈值: 剩余 &lt; ${SSL_CERT_DAYS_WARN} 天）</p>
  <table>
    <tr><th class="col-name">CN</th><th class="col-path">证书路径</th><th>到期时间</th><th>剩余天数</th><th class="col-status">状态</th></tr>
    ${SSL_ROWS}
  </table>
</div>
EOF
fi

# 系统日志
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-log">
  <h2><span class="num">16.</span>系统日志（最近异常）</h2>
  <pre>$([ -n "$SYSLOG_ERRORS" ] && html_escape "$SYSLOG_ERRORS" || echo "无异常日志")</pre>
  <p style="margin-top:8px;font-size:12px;color:#888;">OOM 事件次数: ${OOM_COUNT}</p>
EOF

if [[ -n "$HW_ERRORS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>硬件错误 (dmesg)</h3>
  <pre>$(html_escape "$HW_ERRORS")</pre>
EOF
fi

if [[ -n "$AUTH_ERRORS" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>认证日志异常 (前10)</h3>
  <pre>$(html_escape "$AUTH_ERRORS")</pre>
EOF
fi

if [[ -n "$NTP_DETAIL" ]]; then
    cat >> "$REPORT_FILE" <<EOF
  <h3>NTP 时间源详情</h3>
  <pre>$(html_escape "$NTP_DETAIL")</pre>
EOF
fi

echo "</div>" >> "$REPORT_FILE"

# 总体建议 3 列卡片（基于 warn/critical 数量动态生成）
cat >> "$REPORT_FILE" <<EOF
<div class="section" id="sec-recommend">
  <h2><span class="num">17.</span>总体建议</h2>
  <div class="recommends">
    <div class="rec-card r-short">
      <h4>短期建议<span class="span">(立刻 / 1-3 天)</span></h4>
      <ul>
EOF

# 短期：根据严重项动态生成
if (( CRITICAL_COUNT > 0 )); then
    echo "        <li>处理 ${CRITICAL_COUNT} 项严重告警</li>" >> "$REPORT_FILE"
fi
if (( DISK_ALERT > 0 )); then
    echo "        <li>清理告警磁盘上的大文件 / 日志，释放空间</li>" >> "$REPORT_FILE"
fi
if (( OOM_COUNT > 0 )); then
    echo "        <li>排查 ${OOM_COUNT} 次 OOM 事件原因，必要时增加内存</li>" >> "$REPORT_FILE"
fi
if (( SSL_EXPIRED > 0 )); then
    echo "        <li>续签 ${SSL_EXPIRED} 张已过期 SSL 证书</li>" >> "$REPORT_FILE"
fi
if (( ZOMBIE_COUNT > 0 )); then
    echo "        <li>清理 ${ZOMBIE_COUNT} 个僵尸进程</li>" >> "$REPORT_FILE"
fi
# 兜底
if (( CRITICAL_COUNT == 0 && DISK_ALERT == 0 && OOM_COUNT == 0 && SSL_EXPIRED == 0 && ZOMBIE_COUNT == 0 )); then
    echo "        <li>当前无紧急问题</li>" >> "$REPORT_FILE"
    echo "        <li>建议保持每周一次例行巡检</li>" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF
      </ul>
    </div>
    <div class="rec-card r-mid">
      <h4>中期建议<span class="span">(1-4 周)</span></h4>
      <ul>
EOF

if (( WARN_COUNT > 0 )); then
    echo "        <li>梳理 ${WARN_COUNT} 项警告，制定整改计划</li>" >> "$REPORT_FILE"
fi
if (( SSL_EXPIRING > 0 )); then
    echo "        <li>提前续签 ${SSL_EXPIRING} 张即将过期证书</li>" >> "$REPORT_FILE"
fi
if (( UPDATE_COUNT > 0 )); then
    echo "        <li>评估并应用 ${UPDATE_COUNT} 个待安装系统更新</li>" >> "$REPORT_FILE"
fi
if (( FAIL_COUNT > 0 )); then
    echo "        <li>分析最近登录失败记录，加固 SSH 配置</li>" >> "$REPORT_FILE"
fi
echo "        <li>检查关键服务的备份策略与监控覆盖</li>" >> "$REPORT_FILE"
echo "        <li>评估内核参数是否符合业务负载特征</li>" >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<EOF
      </ul>
    </div>
    <div class="rec-card r-long">
      <h4>长期建议<span class="span">(1-6 个月)</span></h4>
      <ul>
        <li>建立服务器健康基线，定期对比指标变化</li>
        <li>完善自动化巡检与告警推送机制</li>
        <li>规划容量增长与资源弹性扩展</li>
        <li>建立日志/审计的归档与合规流程</li>
        <li>定期演练故障恢复与应急响应流程</li>
      </ul>
    </div>
  </div>
</div>

<div class="disclaimer">
  <h4>免责声明</h4>
  <p>本报告由 linux_inspect.sh 自动采集生成，基于巡检时刻的瞬时状态。系统运行状态可能随时间变化，建议结合监控/日志系统综合判断。报告中的阈值与告警等级仅作参考，请根据业务实际情况调整。脚本仅做只读采集，不会修改系统配置。</p>
</div>

<div class="footer">
  巡检完成 <span class="sep">·</span> 警告 ${WARN_COUNT} <span class="sep">·</span> 严重 ${CRITICAL_COUNT} <span class="sep">·</span> 生成于 $(date '+%Y-%m-%d %H:%M:%S') <span class="sep">·</span> linux_inspect.sh ${SCRIPT_VERSION}
</div>
</div>
<script>
// scroll-spy: 高亮当前可见章节对应的 TOC 链接
(function(){
  var links = document.querySelectorAll('.toc a[href^="#"]');
  var map = {};
  links.forEach(function(a){
    var id = a.getAttribute('href').slice(1);
    var el = document.getElementById(id);
    if (el) map[id] = a;
  });
  if (!('IntersectionObserver' in window)) return;
  var visible = new Set();
  var io = new IntersectionObserver(function(entries){
    entries.forEach(function(e){
      if (e.isIntersecting) visible.add(e.target.id);
      else visible.delete(e.target.id);
    });
    links.forEach(function(a){ a.classList.remove('active'); });
    var first = null;
    Object.keys(map).forEach(function(id){
      if (visible.has(id) && !first) first = id;
    });
    if (first && map[first]) map[first].classList.add('active');
  }, { rootMargin: '-10% 0px -75% 0px', threshold: 0 });
  Object.keys(map).forEach(function(id){
    io.observe(document.getElementById(id));
  });
})();
</script>
</body>
</html>
EOF

# ======================== JSON 输出 ========================
END_TIME=$(date +%s)
ELAPSED_TIME=$(( END_TIME - START_TIME ))

# JSON 字符串转义
json_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    REPORT_FILE="$REPORT_FILE_FINAL"
    cat > "$REPORT_FILE" <<JSON
{
  "version": "$(json_str "$SCRIPT_VERSION")",
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "elapsed_seconds": ${ELAPSED_TIME},
  "host": {
    "hostname": "$(json_str "$HOSTNAME_VAL")",
    "fqdn": "$(json_str "$HOSTNAME_FQDN")",
    "ip": "$(json_str "$IP_ADDR")",
    "os": "$(json_str "$OS_VERSION")",
    "kernel": "$(json_str "$KERNEL")",
    "arch": "$(json_str "$ARCH")",
    "uptime_days": ${UPTIME_DAYS:-0},
    "virt_type": "$(json_str "$VIRT_TYPE")",
    "selinux": "$(json_str "$SELINUX_STATUS")",
    "firewall": "$(json_str "$FIREWALL_STATUS")",
    "timezone": "$(json_str "$TIMEZONE")"
  },
  "metrics": {
    "cpu_usage_pct": ${CPU_USAGE:-0},
    "cpu_cores": ${CPU_CORES:-0},
    "load_1m": ${LOAD_1:-0},
    "load_5m": ${LOAD_5:-0},
    "load_15m": ${LOAD_15:-0},
    "mem_usage_pct": ${MEM_USAGE:-0},
    "swap_usage_pct": ${SWAP_USAGE:-0},
    "fd_usage_pct": ${FD_PCT:-0},
    "disk_alert_count": ${DISK_ALERT:-0},
    "tcp_connections": ${CONN_TOTAL:-0},
    "tcp_close_wait": ${CONN_CLOSE_WAIT:-0},
    "tcp_listen": ${CONN_LISTEN:-0},
    "process_count": ${PROCESS_COUNT:-0},
    "zombie_count": ${ZOMBIE_COUNT:-0},
    "d_state_count": ${D_STATE_COUNT:-0},
    "oom_count": ${OOM_COUNT:-0}
  },
  "ssl": {
    "total": ${SSL_TOTAL:-0},
    "expiring_in_${SSL_CERT_DAYS_WARN}_days": ${SSL_EXPIRING:-0},
    "expired": ${SSL_EXPIRED:-0}
  },
  "updates": {
    "available": "$(json_str "$UPDATE_INFO")",
    "security": "$(json_str "${SEC_UPDATES:-N/A}")"
  },
  "thresholds": {
    "cpu_warn": ${CPU_WARN},
    "mem_warn": ${MEM_WARN},
    "disk_warn": ${DISK_WARN},
    "swap_warn": ${SWAP_WARN},
    "fd_warn": ${FD_WARN},
    "ssl_days_warn": ${SSL_CERT_DAYS_WARN}
  },
  "result": {
    "warnings": ${WARN_COUNT},
    "critical": ${CRITICAL_COUNT},
    "exit_code": $((CRITICAL_COUNT > 0 ? 2 : (WARN_COUNT > 0 ? 1 : 0)))
  }
}
JSON
fi

# ======================== 终端输出汇总 ========================
ELAPSED_MIN=$(( ELAPSED_TIME / 60 ))
ELAPSED_SEC=$(( ELAPSED_TIME % 60 ))

if (( QUIET == 0 )); then
    echo ""
    echo "=============================================="
    echo "  Linux Inspection ${SCRIPT_VERSION} - 巡检完成"
    echo "  Host: $(hostname)"
    echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Steps: ${CURRENT_STEP}/${TOTAL_STEPS}"
    echo -e "  Warnings: ${YELLOW}${WARN_COUNT}${NC}    Critical: ${RED}${CRITICAL_COUNT}${NC}"
    echo "  Elapsed: ${ELAPSED_MIN}m${ELAPSED_SEC}s"
    echo "  Format: ${OUTPUT_FORMAT}"
    echo "  Report: ${REPORT_FILE_FINAL}"
    echo "=============================================="
    echo ""
fi

# Exit code 语义化：0=正常 1=警告 2=严重
if (( CRITICAL_COUNT > 0 )); then
    exit 2
elif (( WARN_COUNT > 0 )); then
    exit 1
fi
exit 0
