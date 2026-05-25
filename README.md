# Linux Auto Inspection

**Linux 服务器一键巡检脚本** — 纯 Bash 编写,零依赖,自动适配主流发行版,输出工程师风 HTML 报告。

[![Shell](https://img.shields.io/badge/Shell-Bash%204.0%2B-green)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-orange)]()
[![Version](https://img.shields.io/badge/Version-v2.5-brightgreen)]()

---

## 为什么用它

写一份脚本 vs 写 10 份脚本: 主流 Linux 发行版的诡异差异 (systemd vs sysvinit, GNU vs busybox, /etc/os-release vs /etc/redhat-release, dmesg vs journalctl, docker vs podman, iostat 装没装) 都被这一个脚本吃下了。

- **零依赖**: 系统自带 bash 4.0+ 就能跑, 不需要装 Python / PowerCLI / pyvmomi / 任何包
- **跨发行版**: RHEL/CentOS/Rocky/Alma/Oracle/Fedora/Amazon/Anolis/openEuler/TencentOS/AliyunLinux/EulerOS/Ubuntu/Debian/Kali/Mint/Pop!_OS/Raspbian/Deepin/SUSE/openSUSE/Kylin/NeoKylin/UOS/Arch/Manjaro/EndeavourOS/Alpine/Gentoo, 30+ 发行版
- **不假设环境**: 没 systemd? 没 iproute2? 没 sysstat? 没 docker? non-root 跑 dmesg? 全部自动 fallback
- **工程师风**: 不要 emoji 装饰、不要营销腔、不要渐变光晕。表格、徽章、颜色码,够用

## 报告样张

![Linux 巡检报告样张](docs/report-preview.png)

> 上图为某 Rocky Linux 实测报告的整页截图,工程师风扁平卡片 + 17 章节侧栏导航 + 进度条 + 徽章。HTML 输出可直接在浏览器打开、邮件转发或打印归档。

## 兼容性矩阵

| 发行版 | 状态 | 备注 |
|---|---|---|
| RHEL 7/8/9, CentOS 7/8/9, Rocky 8/9, AlmaLinux 8/9 | ✅ 完整支持, 实战测试 | OS_FAMILY=rhel |
| Oracle Linux 7/8/9, Fedora 36+, Amazon Linux 2/2023 | ✅ 完整支持 | |
| Anolis, openEuler, TencentOS, Alibaba Cloud Linux, EulerOS, Scientific | ✅ 完整支持 | 走 ID_LIKE=rhel |
| Ubuntu 18/20/22/24, Debian 10/11/12 | ✅ 完整支持 | OS_FAMILY=debian |
| Kali, Mint, Pop!_OS, Raspbian, Elementary, Deepin | ✅ 兼容 | 走 ID_LIKE=debian |
| SUSE Linux Enterprise 12/15, openSUSE Leap 15/Tumbleweed | ✅ 完整支持 | OS_FAMILY=suse |
| Kylin V10, NeoKylin | ✅ 完整支持 | OS_FAMILY=kylin |
| UOS, Deepin | ✅ 兼容 | OS_FAMILY=uos |
| Arch, Manjaro, EndeavourOS, Garuda | ✅ 兼容, 新增 pacman 支持 | OS_FAMILY=arch |
| Alpine Linux | ⚠️ 部分兼容 | apk 已集成; busybox grep/awk 个别章节输出退化 |
| Gentoo | ⚠️ 未实测 | OS_FAMILY=gentoo; portage 未集成 |
| CentOS 6 / RHEL 6 | ⚠️ 部分兼容 | bash 4.1.2 + sysvinit 双轨 fallback 路径已覆盖 |
| CentOS 5 / 老版 | ❌ 不支持 | bash 3.x 不支持关联数组 |
| WSL1 / WSL2 / 容器 | ⚠️ 部分兼容 | 无 systemd 走 sysvinit, dmesg 走 journalctl |

## 快速开始

```bash
# 方式 1: git clone (推荐, 自动跟 .gitattributes 保持 LF 行尾)
git clone https://github.com/Aidan-996/Linux_Auto_Inspection.git
cd Linux_Auto_Inspection
bash linux_inspect.sh

# 方式 2: wget 单文件
wget -O linux_inspect.sh https://raw.githubusercontent.com/Aidan-996/Linux_Auto_Inspection/main/linux_inspect.sh
chmod +x linux_inspect.sh
./linux_inspect.sh

# 方式 3: 一键 wget + 跑
curl -sL https://raw.githubusercontent.com/Aidan-996/Linux_Auto_Inspection/main/linux_inspect.sh | bash
```

### 看截图 (默认输出)

```
==============================================
  Linux Inspection v2.5
  Host: prod-app-01
  Time: 2026-05-25 14:13:10
  Format: html  |  Verbose: off
  Steps: 19
==============================================
[ 1/19] (  5%) 采集基本信息(主机/CPU/内存/网络/虚拟化)...
[ 2/19] ( 10%) 检查 CPU 使用率与负载...
[ 3/19] ( 15%) 检查内存与 Swap...
[ 4/19] ( 21%) 检查磁盘使用率与 Inode...
[ 5/19] ( 26%) 检查磁盘 I/O 性能...
[ 6/19] ( 31%) 扫描大文件 (>+100M / 最近7天>+50M)...
[ 7/19] ( 36%) 检查文件描述符使用...
[ 8/19] ( 42%) 检查网络状态 (网卡/TCP/路由)...
[ 9/19] ( 47%) 检查进程状态 (僵尸/D状态/长运行)...
[10/19] ( 52%) 执行安全检查 (SSH/账户/SUID/登录)...
[11/19] ( 57%) 检查定时任务 (crontab/cron.d)...
[12/19] ( 63%) 检查关键服务状态 (systemctl/service/chkconfig 自适应)...
[13/19] ( 68%) 检查 Docker / Podman 容器...
[14/19] ( 73%) 检查内核参数 (sysctl)...
[15/19] ( 78%) 检查系统更新状态 (包管理器)...
[16/19] ( 84%) 检查系统日志 (异常/OOM/认证)...
[17/19] ( 89%) 检查 NTP 时间同步...
[18/19] ( 94%) 检查 SSL 证书过期...
[19/19] (100%) 生成报告 (html)...
==============================================
  Linux Inspection v2.5 - 巡检完成
  Host: prod-app-01      Steps: 19/19
  Warnings: 2    Critical: 0    Elapsed: 0m12s
  Report: /tmp/inspect_report/inspect_prod-app-01_20260525_141322.html
==============================================
```

## 命令行参数

```
用法: ./linux_inspect.sh [选项]

选项:
  -o, --output FILE       指定输出文件路径 (默认 /tmp/inspect_report/...)
  -f, --format FORMAT     输出格式: html (默认) | json
  -v, --verbose           显示详细 debug 日志
  -q, --quiet             静默模式, 只输出报告路径
  --no-large-file-scan    跳过大文件扫描 (大磁盘环境提速)
  --skip-update-check     跳过包管理器更新检查 (内网无外网时用)
  --skip-ssl-check        跳过 SSL 证书过期检查
  --fast                  快速模式 (= 上面三个 skip 全开)
  -h, --help              显示帮助
```

## 17 大类检查维度

| # | 维度 | 涉及命令 |
|---|---|---|
| 1 | 主机基本信息 | hostname / uname / nproc / /proc/cpuinfo / dmidecode |
| 2 | CPU 使用率与负载 | /proc/stat / /proc/loadavg |
| 3 | 内存与 Swap | /proc/meminfo / free |
| 4 | 磁盘使用率 + Inode | df -h / df -i |
| 5 | 磁盘 I/O 性能 | iostat (fallback /proc/diskstats) |
| 6 | 大文件 TOP N | find + du |
| 7 | 文件描述符 | /proc/sys/fs/file-nr |
| 8 | 网络 (网卡/TCP/路由) | ip addr / ifconfig / ss / netstat |
| 9 | 进程状态 (僵尸/D状态/长运行) | ps |
| 10 | 安全检查 (SSH/账户/SUID/登录) | sshd_config / /etc/shadow / find |
| 11 | 定时任务 (crontab/cron.d) | crontab / /etc/cron.d/* |
| 12 | 关键服务 | systemctl + service + chkconfig 三轨 |
| 13 | Docker / Podman 容器 | docker / podman ps / images |
| 14 | 内核参数 (sysctl) | sysctl -a |
| 15 | 系统更新 (yum/dnf/apt/zypper/pacman/apk) | 多包管理器分发 |
| 16 | 系统日志 (异常/OOM/认证) | dmesg / journalctl -k / /var/log/* |
| 17 | NTP 时间同步 | chronyc / ntpq / ntpstat / timedatectl / ntpctl |
| (+) | SSL 证书过期 | openssl x509 |

## 兼容性设计 (v2.5 核心改进)

### 四个 helper 函数

| 函数 | 用途 | 降级路径 |
|---|---|---|
| `detect_os()` | 多源 OS 识别 | os-release → kylin-release → centos-release → redhat-release → SuSE-release → debian_version → alpine-release → arch-release → gentoo-release → system-release → uname |
| `safe_service_status()` | 服务状态 | systemctl → service → chkconfig → init.d |
| `safe_dmesg()` | 内核日志 | dmesg → journalctl -k |
| `detect_timezone()` | 时区 | timedatectl → /etc/timezone → readlink /etc/localtime → /etc/sysconfig/clock |

### NTP 四套时间源全识别

```
chronyc tracking ─┐
ntpq -pn         ─┤
ntpstat          ─┼→ 任一返回"已同步"即为正常
timedatectl show ─┤
ntpctl -s status ─┘
```

### 防火墙五套并查

```
firewalld / ufw / nftables / iptables / SuSEfirewall2
```

每个走 `safe_service_status` 双轨; 最后兜底 `iptables -L` 看有无规则推断。

### 包管理器扩展

| OS_FAMILY | 包管理器 |
|---|---|
| rhel | dnf → yum |
| debian | apt |
| suse | zypper |
| arch | pacman (走 `checkupdates` 不需 root) |
| alpine | apk |
| kylin / uos | dnf → yum → apt |

### IP / 路由命令双轨

| 用途 | 优先 | Fallback |
|---|---|---|
| IP 获取 | `hostname -I` | `ip addr` → `ifconfig` |
| 默认网关 | `ip route` | `netstat -rn` → `route -n` |
| 路由表 | `ip route` | `netstat -rn` → `route -n` |

## 已修复的踩坑 (v2.5)

> 这里列两个真实生产事故,提醒后来者别再踩

### 踩坑 1: CRLF 行尾让 bash 突然崩 (CentOS 7 / Rocky)

**症状**:
```
linux_inspect.sh: line 1278: syntax error near unexpected token '<'
```
跑到某个 `done < <(...)` 紧凑语法时 bash 直接挂。

**根因**: 文件被 Windows 编辑过, 行尾是 CRLF。bash 把 `done\r` 当一个命令, 后面的 `<` 当意外 token。前面 16 步能跑是因为简单命令对 `\r` 容忍度高。

**预防**:
- v2.5 仓库带 `.gitattributes`, 锁定 `*.sh` 为 LF 行尾
- 客户端兜底: `sed -i 's/\r$//' linux_inspect.sh`

### 踩坑 2: `set -o pipefail` + `grep -c ... || echo "0"` 算术崩 (Rocky 9 dnf)

**症状**:
```
linux_inspect.sh: line 1841: ((: 158
0: syntax error in expression (error token is "0")
```

**根因**:
- `dnf check-update` **有可用更新时故意 exit 100** (不是 0)
- `set -o pipefail` 让整个 pipeline 也返回 100
- 触发 `|| echo "0"`, 但 grep 已经输出了 `158`, echo 又写一遍
- 变量值变成 `"158\n0"` 两行字符串, `(( VAR > 0 ))` 崩

**预防**: 所有 `|| echo "0"` → `|| true`, 再加 `VAR=${VAR//[^0-9]/}; VAR=${VAR:-0}` 双重 sanitize

## 文件结构

```
Linux_Auto_Inspection/
├── linux_inspect.sh                # 主脚本 (2200+ 行, 单文件即用)
├── .gitattributes                  # 锁定 *.sh 为 LF 行尾
├── README.md                       # 本文件
├── CHANGELOG.md                    # 完整版本历史 (v2.0 → v2.5)
├── CONTRIBUTING.md                 # 贡献指南
├── LICENSE                         # MIT
├── docs/
│   └── report-preview.png          # 报告样张
└── history/                        # 历史版本发布说明 + 代码审查归档
    ├── RELEASE_NOTES_v2.5.md       # v2.5 发布说明
    ├── RELEASE_NOTES_v2.4.md       # v2.4 发布说明
    └── linux_inspect_script_analysis.md  # v2.0-v2.3 代码缺陷分析档案
```

## License

MIT License — 见 [LICENSE](LICENSE)

## 贡献

实战反馈来自:
- CentOS 7 用户报告 CRLF 行尾导致 SSL 检查 process substitution 崩
- Rocky Linux 9 用户报告 dnf check-update + pipefail 导致 UPDATE_COUNT 多行字符串崩

如果你在没列入兼容矩阵的发行版上跑通了 (或踩了新坑), 欢迎开 issue / PR。

完整版本历史见 [CHANGELOG.md](CHANGELOG.md), v2.5 发布详情见 [history/RELEASE_NOTES_v2.5.md](history/RELEASE_NOTES_v2.5.md)。
