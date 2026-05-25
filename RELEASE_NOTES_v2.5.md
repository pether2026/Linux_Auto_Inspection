# Linux Auto Inspection v2.5 Release Notes

**发布日期**: 2026-05-25
**主题**: 跨发行版兼容大改 + 健壮性修复

---

## TL;DR

v2.5 不加新章节, 只做一件事: **让一份脚本在主流 30+ Linux 发行版上都能跑通**。

- 修了 v2.4 在 CentOS 7 (CRLF) 和 Rocky Linux 9 (pipefail) 上的两个生产事故
- 加了 4 个跨发行版 helper (`detect_os` / `safe_service_status` / `safe_dmesg` / `detect_timezone` 等)
- 兼容矩阵从 RHEL/Debian/SUSE/Kylin 四系扩展到 RHEL 系 + Debian 系 + SUSE 系 + 国产系 + Arch 系 + Alpine 系 + Gentoo 系
- 服务、网络、时间同步、磁盘 IO、防火墙全部双轨/三轨 fallback
- 不再假设 systemd 一定存在,不再假设 dmesg 一定可读,不再假设 iostat 一定装了

---

## 兼容性矩阵

| 发行版 | 测试状态 | 备注 |
|---|---|---|
| RHEL 7 / 8 / 9 | ✅ 完整支持 | OS_FAMILY=rhel |
| CentOS 7 / 8 / 9 | ✅ 完整支持, 实测 | v2.5 修复 CRLF 后跑通 |
| Rocky Linux 8 / 9 | ✅ 完整支持, 实测 | v2.5 修复 pipefail 后跑通 |
| AlmaLinux 8 / 9 | ✅ 完整支持 | 与 Rocky 一致 |
| Oracle Linux 7 / 8 / 9 | ✅ 完整支持 | |
| Fedora 36+ | ✅ 完整支持 | podman 默认替代 docker |
| Amazon Linux 2 / 2023 | ✅ 完整支持 | 走 `/etc/system-release` |
| Anolis / openEuler / TencentOS / Alibaba Cloud Linux / EulerOS | ✅ 完整支持 | 走 ID_LIKE=rhel |
| Ubuntu 18 / 20 / 22 / 24 | ✅ 完整支持 | OS_FAMILY=debian |
| Debian 10 / 11 / 12 | ✅ 完整支持 | |
| Kali / Mint / Pop!_OS / Raspbian / Elementary | ✅ 兼容 | 走 ID_LIKE=debian |
| SUSE Linux Enterprise 12 / 15 | ✅ 完整支持 | OS_FAMILY=suse |
| openSUSE Leap 15 / Tumbleweed | ✅ 完整支持 | |
| Kylin V10 / NeoKylin | ✅ 完整支持 | OS_FAMILY=kylin, 走 `/etc/kylin-release` |
| UOS / Deepin | ✅ 兼容 | OS_FAMILY=uos, ID_LIKE=debian |
| Arch Linux / Manjaro / EndeavourOS | ✅ 兼容 | 新增 pacman 支持 |
| Alpine Linux | ⚠️ 部分兼容 | 新增 apk 支持; 但 busybox grep/awk 与 GNU 有差异, 个别章节可能输出退化 |
| Gentoo | ⚠️ 兼容性未实测 | OS_FAMILY=gentoo, 包管理 (Portage) 未集成 |
| CentOS 6 / RHEL 6 | ⚠️ 部分兼容 | bash 4.1.2 OK; 无 systemd, 走 service/chkconfig 双轨; 老 grep/awk OK |
| WSL2 / 容器 | ⚠️ 部分兼容 | 无 systemd 容器走 sysvinit 路径, `dmesg` 通常受限走 `journalctl -k` |

---

## 修复 (来自实战反馈)

### 1. CRLF 行尾兼容 (CentOS 7 报错事故)

**现象**: 用户在 CentOS 7 上跑到 17/19 步 NTP 时:
```
linux_inspect.sh: line 1278: syntax error near unexpected token '<'
```

**根因**: 脚本副本是 CRLF 行尾 (Windows 编辑过), bash 看到 `done\r < <(...)` 时把 `done\r` 当一个命令, 后面的 `<` 当意外 token。前 16 步能跑是因为简单命令对 `\r` 容忍度高, `done < <(...)` 这种紧凑语法不容忍。

**修复**:
- 文件本身一定是 LF (GitHub 端历来如此)
- 加 `.gitattributes` 锁定 `*.sh / *.bash` 为 `eol=lf`, 防止 Windows clone 后 git autocrlf 自动转 CRLF
- 客户端最快兜底命令: `sed -i 's/\r$//' linux_inspect.sh`

### 2. `set -o pipefail` + `grep -c ... || echo "0"` 反模式 (Rocky 9 报错事故)

**现象**: 用户在 Rocky Linux 9 (有 158 个可用更新) 上跑到 L1841 算术报错:
```
linux_inspect.sh: line 1841: ((: 158
0: syntax error in expression (error token is "0")
```

**根因**:
- `dnf check-update` 在**有可用更新时故意 exit 100** (不是 0)
- 脚本顶部 `set -o pipefail` 让整个 pipeline 也返回 100
- 触发 `|| echo "0"` 兜底, 但此时 `grep -c` 已经把 `158` 写到 stdout
- `echo 0` 又写一遍 → 变量值变成 `"158\n0"` 两行字符串
- 传入 `(( ... ))` 算术上下文 → bash 求值崩

**修复**: 把 `|| echo "0"` 全部改成 `|| true` (只吞退出码不污染 stdout), 再加 `VAR=${VAR//[^0-9]/}; VAR=${VAR:-0}` 双重 sanitize。共修 6 处。

---

## 新增 (跨发行版兼容)

### `detect_os()` — 多源 OS 识别

| 来源 | 适用 |
|---|---|
| `/etc/os-release` | 现代 Linux (systemd 时代) |
| `/etc/kylin-release` | Kylin / NeoKylin |
| `/etc/centos-release` | CentOS 6 / 7 / 8 |
| `/etc/redhat-release` | RHEL / CentOS / Scientific Linux |
| `/etc/SuSE-release` | 老 SUSE |
| `/etc/debian_version` | Debian / Ubuntu 老版本 |
| `/etc/alpine-release` | Alpine |
| `/etc/arch-release` | Arch |
| `/etc/gentoo-release` | Gentoo |
| `/etc/system-release` | Amazon Linux |
| `uname -s` | 兜底 |

输出归一的 `OS_FAMILY`: `rhel` / `debian` / `suse` / `kylin` / `uos` / `arch` / `alpine` / `gentoo` / `other`

### `safe_service_status()` / `safe_service_enabled()` — 服务管理双轨

```
systemctl is-active → service xxx status → chkconfig --list → /etc/init.d/xxx status
```

统一输出三态: `active` / `inactive` / `notfound`, 兼容 CentOS 6 / RHEL 6 / 无 systemd 容器。

### `safe_dmesg()` — dmesg 权限 fallback

内核 5.0+ 默认 `kernel.dmesg_restrict=1`, 非 root 跑 `dmesg` 会失败。v2.5 fallback `journalctl -k --no-pager | tail -3000`。

### `detect_timezone()` — 时区四源 fallback

```
timedatectl → /etc/timezone → readlink /etc/localtime → /etc/sysconfig/clock
```

### `container_cmd()` — Docker / Podman 双识别

RHEL 8+ / Fedora 31+ 默认装 podman 不装 docker, CLI 兼容直接复用脚本里所有 `docker xxx` 路径。

### NTP 四套时间源全识别

| 命令 | 检测信号 |
|---|---|
| `chronyc tracking` | `Leap status: Normal` |
| `ntpq -pn` | `^\*` 任意 peer 行 |
| `ntpstat` | exit 0 |
| `timedatectl show` | `NTPSynchronized=yes` |
| `ntpctl -s status` | `clock synced` (openntpd) |

### 防火墙多识别

`firewalld` / `ufw` / `nftables` / `iptables` / `SuSEfirewall2` 都查一遍, 用 `safe_service_status` 双轨判断; 最后用 `iptables -L` 看有无规则做兜底推断。

### iostat fallback

没装 sysstat (iostat 缺失) 时, 改读 `/proc/diskstats`, awk 解析扇区数 × 512 算出 KB 量。

### 包管理器扩展

| OS_FAMILY | 包管理器 |
|---|---|
| rhel | dnf → yum |
| debian | apt |
| suse | zypper |
| **arch** | **pacman (新增, 走 `checkupdates` 不需 root)** |
| **alpine** | **apk (新增)** |
| kylin / uos | dnf → yum → apt |

### `lastb` 守护

同时判 `root` + `/var/log/btmp` 可读 + `lastb` 命令存在, 三条件齐全才跑, 避免最小化镜像/容器空跑。

### 网络命令双轨

| 用途 | 优先 | Fallback |
|---|---|---|
| IP 获取 | `hostname -I` | `ip addr` → `ifconfig` |
| 默认网关 | `ip route` | `netstat -rn` → `route -n` |
| 路由表 | `ip route` | `netstat -rn` → `route -n` |

---

## 升级指引

### 从 v2.4 升级

```bash
# Git clone
git clone https://github.com/Aidan-996/Linux_Auto_Inspection.git
cd Linux_Auto_Inspection
bash linux_inspect.sh

# 或直接 wget 单文件
wget -O linux_inspect.sh https://raw.githubusercontent.com/Aidan-996/Linux_Auto_Inspection/main/linux_inspect.sh
chmod +x linux_inspect.sh
./linux_inspect.sh
```

如果你从 Windows 拷贝到 Linux 后行尾变 CRLF (v2.4 用户老问题),一行命令兜底:
```bash
sed -i 's/\r$//' linux_inspect.sh
```

### 行为变化

| | v2.4 | v2.5 |
|---|---|---|
| 无 systemd 系统 (CentOS 6) | 服务章节全空 | service/chkconfig fallback 仍展示 |
| 内核 5.0+ 非 root | dmesg 空 | journalctl -k fallback |
| Alpine / Arch | 大量 N/A | apk / pacman 集成 |
| 容器运行时 (podman-only) | Docker 章节全空 | 自动识别 podman |
| Datastore 中文 / 时区 | 部分丢失 | 时区四源识别 + UTF-8 强制 |

---

## Known Issues

- **Alpine busybox**: `grep -P` (PCRE) 不支持, 但 v2.5 已全部用 `grep -E`。`awk` 在某些章节可能输出退化 (busybox awk vs GNU awk), 但不会崩
- **CentOS 5**: bash 3.x, 关联数组 (`declare -A`) 不支持, **不支持**, 脚本启动会拒绝
- **Gentoo**: portage (`emerge`) 没集成, 更新检查会显示 N/A
- **WSL1**: 内核版本检测不准, 服务管理章节会显示退化

---

## 文件清单

| 文件 | 行数 / 大小 | 说明 |
|---|---|---|
| `linux_inspect.sh` | 2219 行 | 主脚本, v2.4 → v2.5 增加 ~200 行兼容性 helper |
| `.gitattributes` | 17 行 | 锁定 `*.sh` 为 LF 行尾, v2.5 新增 |
| `README.md` | 重写 | 加兼容性矩阵 + 已修复踩坑表 |
| `CHANGELOG.md` | 增补 v2.5 段落 | |
| `RELEASE_NOTES_v2.5.md` | 本文件 | |
| `linux_inspect_script_analysis.md` | 未变 | 历史代码审查报告 (v2.0 → v2.3) |
| `LICENSE` | MIT | |

---

## 贡献

实战反馈来自:
- CentOS 7 用户报告 CRLF 行尾导致 SSL 检查 process substitution 崩
- Rocky Linux 9 用户报告 dnf check-update + pipefail 导致 UPDATE_COUNT 多行字符串崩

如果你在没列入兼容矩阵的发行版上跑通了 (或踩了新坑), 欢迎开 issue / PR。
