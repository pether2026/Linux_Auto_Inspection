# Linux 服务器巡检脚本 - 更新日志

## 文档概述

本文档记录 `linux_inspect.sh` 脚本的所有版本更新信息，包括修复的缺陷、新增功能和改进内容。

---

## 版本历史

### v2.5 (2026-05-25) - 跨发行版兼容大改 + 健壮性修复

**核心目标**: 一份脚本跑遍主流 Linux 发行版,不挑食、不假设环境

#### 修复 (来自实战反馈)

1. **CRLF 行尾兼容** — CentOS 7 用户反馈跑到 17/19 步 NTP 时 `syntax error near unexpected token '<'`。根因: 脚本副本是 CRLF 行尾, bash 把 `done\r` 后面的 `<` 当意外 token。修复: 加 `.gitattributes` 锁 `*.sh / *.bash` 为 `eol=lf`, 防止 Windows checkout 自动转 CRLF
2. **`set -o pipefail` + `grep -c ...|| echo "0"` 反模式** — Rocky Linux 9 跑到 L1841 `(( UPDATE_COUNT > 0 ))` 报 `((: 158\n0: syntax error`。根因: `yum/dnf check-update` 有更新时故意 exit 100, pipefail 让 pipeline 失败, 触发 `|| echo "0"` 把 `0` 拼在 grep 已输出的 `158` 之后, 变量成 `"158\n0"`。修了 6 处 (UPDATE_COUNT × 4 + FAIL_COUNT + SEC_UPDATES × 4 + OOM_COUNT), 改用 `|| true` + `VAR=${VAR//[^0-9]/}` 双重 sanitize

#### 跨发行版兼容 (新增 ~200 行 helper 与降级路径)

3. **多源 OS 识别** `detect_os()` — `/etc/os-release` → `/etc/kylin-release` → `/etc/centos-release` → `/etc/redhat-release` → `/etc/SuSE-release` → `/etc/debian_version` → `/etc/alpine-release` → `/etc/arch-release` → `/etc/gentoo-release` → `/etc/system-release` → `uname -s` 十一级 fallback;输出归一的 `OS_FAMILY` (rhel/debian/suse/kylin/uos/arch/alpine/gentoo/other), 覆盖 RHEL/CentOS/Rocky/Alma/Oracle/Fedora/Amazon Linux/openEuler/Anolis/TencentOS/Alibaba Cloud Linux/EulerOS/Scientific/Ubuntu/Debian/Kali/Mint/Pop!_OS/Raspbian/Elementary/Deepin/SUSE/openSUSE/Kylin/NeoKylin/UOS/Arch/Manjaro/EndeavourOS/Garuda/Alpine/Gentoo 等 30+ 发行版
4. **服务管理双轨** `safe_service_status()` / `safe_service_enabled()` — `systemctl is-active` → `service xxx status` → `chkconfig --list` → `/etc/init.d/xxx status` 四级 fallback, 兼容 CentOS 6 / RHEL 6 / 老 SUSE / 无 systemd 容器
5. **防火墙多识别** — 同时检测 `firewalld` / `ufw` / `nftables` / `iptables` / `SuSEfirewall2`, 服务管理走双轨; 最后兜底用 `iptables -L` 看有无规则推断
6. **时区检测多源** `detect_timezone()` — `timedatectl` → `/etc/timezone` → `readlink /etc/localtime` → `/etc/sysconfig/clock` 四级 fallback
7. **dmesg 权限/可用性** `safe_dmesg()` — 内核 5.0+ 默认 `kernel.dmesg_restrict=1` + 非 root 跑 dmesg 失败时, 自动 fallback `journalctl -k --no-pager`
8. **NTP 时间同步四套全识别** — `chronyd` (chronyc) / `ntpd` (ntpq) / `ntpstat` / `systemd-timesyncd` (timedatectl) / `openntpd` (ntpctl), 主动判 `^\\*` peer / `NTPSynchronized=yes` 等多种"已同步"信号
9. **iostat fallback** — 没装 sysstat 包时, 改读 `/proc/diskstats`, 解析扇区数 × 512 得到 KB 量
10. **网络命令双轨** — `hostname -I` → `ip addr` → `ifconfig` 三级 IP 获取; `ip route` → `netstat -rn` → `route -n` 三级路由获取
11. **容器运行时** — Docker 优先, 失败 fallback `podman` (RHEL 8+ / Fedora 31+ 默认), CLI 兼容直接复用同一套代码
12. **包管理器扩展** — 在 yum/dnf/apt/zypper 基础上加 `pacman` (Arch/Manjaro) + `apk` (Alpine), `checkupdates` 优先 pacman 数据库不需 root
13. **`lastb` 守护** — 同时判断 root + `/var/log/btmp` 可读 + `lastb` 命令存在, 三条件全满足才执行, 避免最小化镜像/容器无 btmp 时空跑
14. **服务列表大扩** — 38 → 47 个监控对象, 新增 `chrony` / `ntp` / `openntpd` / `podman` / `nftables` / `bind9` / `winbind` / `sssd` / `NetworkManager` 等

#### 文档

15. README 加 **兼容性矩阵** (列明每个发行版的测试状态) + **已修复踩坑表** + **架构说明**
16. RELEASE_NOTES_v2.5.md 列详细发布说明 + 升级指引 + Known Issues

---

### v2.4 (2026-05-10) - 提速 + 排版重构 + Token Insight 风模板

**第二轮 HTML 重构（参照 Token Insight 报告样式）：**

13. **Header 顶部 banner 重构** — 蓝色渐变 + "巡检"标签徽章 + 横向 6 字段 metadata（主机/IP/操作系统/内核/生成时间/工具版本）+ 右上角格式标识徽章
14. **侧栏 logo 区** — Brand 区加 28x28 蓝色方形 SVG logo + 名称 + 版本号
15. **章节编号** — 全部 17 个 section h2 加 "1. / 2. / ... / 17." 编号前缀，编号用蓝色粗体显示
16. **章节标题底色块** — h2 改浅蓝色 BG（`--c-primary-soft-2`）贴边铺满
17. **Summary 卡片重设计** — 从纯数字卡片改为左侧方形彩色 SVG 图标 + 右侧大数字 + 状态标签布局；6 种状态色（s-ok 绿/s-warn 橙/s-crit 红/s-info 蓝/s-purple 紫/s-orange 金）
18. **基本信息 4 列** — info-grid 从 2 列改 4 列，key 在上 val 在下（更紧凑）
19. **新增"总体建议"章节** — 短期/中期/长期 3 列卡片（顶部边框 橙/蓝/绿），根据警告数据动态生成内容
20. **新增"免责声明"区** — 灰底框说明报告生成原理与使用建议
21. **Footer** — 改为分隔点 `·` 风格，统一中文化

**性能优化（实测 60s → 8-15s）：**

1. **服务检查缓存** — `systemctl list-unit-files` 改为调用 1 次缓存到字符串，循环里 `grep <<< "$cache"` 匹配。从 38 次 fork 降到 1 次，省 **3-5 秒**
2. **CPU IDLE 简化** — 去掉 `top → mpstat 1 1 → vmstat 1 2 → /proc/stat sleep 1` 多重 fallback，直接 `/proc/stat` + 200ms 间隔，省 **1-3 秒**
3. **dmesg 缓存** — OOM 检查 + 硬件错误检查共用一次 dmesg 输出，省 **1-2 秒**
4. **chage → /etc/shadow 直读** — 用户密码过期检查不再每个用户 fork chage，直接 awk 读 shadow 字段计算
5. **SUID/SGID find 合并** — 一次 find 用 `\(-perm -4000 -o -perm -2000\)` + `-printf '%m %p'` 然后 awk 分流，省一次磁盘遍历

**新增快速模式参数：**

6. `--skip-update-check` — 跳过最慢的包管理器联网检查（5-30 秒）
7. `--skip-ssl-check` — 跳过 SSL 证书扫描
8. `--fast` — 一键开 `--no-large-file-scan + --skip-update-check + --skip-ssl-check`

**HTML 排版（v2.4 第一轮）：**

9. **标题中文化** — header 从 "Linux Inspection Report — host" 改为 "Linux 服务器巡检报告 · host"
10. **章节标题底色块** — h2 改为浅蓝色背景 + 4px 蓝竖条
11. **基本信息 3 列**（已被第二轮 4 列覆盖）
12. **Section 内边距重构** — 移除 section 整体 padding，h2 贴边

---

### v2.3 (2026-05-10) - 轻微缺陷收尾 + 关键新功能

**修复（剩余 6 个轻微缺陷全部 close）：**

1. **错误处理机制**
   - 增加 `trap ERR` 捕获异常并打印行号
   - `mkdir -p` 失败、报告文件不可写时立即退出（exit 2）
   - 关键失败路径走 stderr，不再静默吞错

2. **代码重复消除**
   - 提取 `ps_top_to_html()` 函数，统一 CPU_TOP / MEM_TOP 生成
   - 提取 `pre_block()` 函数，封装空值/escape 处理

3. **魔法数字外提**
   - `CRIT_OFFSET=10`（严重 = 警告 + 偏移）
   - `CONN_CLOSE_WAIT_THRESHOLD=50`
   - `TOP_N=10` / `FD_TOP_N=5`
   - `RECENT_FILE_DAYS=7` / `RECENT_FILE_SIZE="+50M"`
   - `LARGE_FILE_SEARCH_PATHS` / `WARN_BADGE_THRESHOLD=3`
   - `SSL_CERT_DAYS_WARN=30`

4. **版本/兼容性检查**
   - Bash ≥ 4.0 检查（here-string 必需）
   - OS 支持矩阵明确写入头注释

5. **日志详细度提升**
   - 新增 `log_debug()` 函数（仅 verbose 模式输出）
   - `-v/--verbose` / `-q/--quiet` 两档控制
   - 命令行参数 `-h/--help`、`-o FILE`、`-f html|json`、`--no-large-file-scan`

6. **HTML 转义完善**
   - footer 写死的 `v2.0` → 用 `${SCRIPT_VERSION}`
   - `MEM_DETAIL`、`SYSLOG_ERRORS` 等 pre 块补 `html_escape`
   - 隐藏 bug 修复：`SGID_FILES` 采集了但没渲染，补上 pre 块

**新功能：**

7. **SSL 证书过期检查**
   - 扫描 `/etc/letsencrypt/live`、`/etc/ssl/certs`、`/etc/pki/tls`、`/etc/nginx/ssl` 等路径
   - 提取 CN、到期时间、剩余天数
   - 剩余 < 30 天告警，已过期严重
   - 报告中独立章节展示

8. **HTML 目录导航**
   - 左侧固定 nav 栏，16 个章节锚点跳转
   - `scroll-behavior: smooth` 平滑滚动
   - 移动端（< 900px）折叠为顶部横排

9. **JSON 输出**
   - `-f json` 输出机器可读 JSON
   - 包含 host / metrics / ssl / updates / thresholds / result 六大字段
   - 便于对接 Prometheus / Telegram bot / 监控平台

10. **Exit code 语义化**
    - `0` = 正常（无警告）
    - `1` = 有警告
    - `2` = 有严重告警 / 脚本错误
    - 便于 CI / 自动化判断巡检结果

11. **可跳过慢扫描**
    - `--no-large-file-scan` 跳过 `find` 大文件扫描
    - 用于快速诊断模式

12. **巡检 Banner + 步骤进度**
    - 开头打印 banner：版本号 / 主机 / 时间 / 输出格式 / 总步骤数
    - 19 个主要检查阶段全部使用 `log_step` 输出 `[N/M] (xx%) 描述`
    - 结尾汇总同样改为统一风格，含 Steps、Warnings、Critical、Elapsed、Format
    - QUIET 模式下不输出 banner 和进度

13. **HTML 报告样式重构（工程师风）**
    - 去除渐变 header，改用 GitHub 风扁平卡片
    - 调色板 CSS 变量化（`--c-primary` / `--c-ok` / `--c-warn` / `--c-crit` 等 16 个 token）
    - 字体栈：`-apple-system / Segoe UI / PingFang SC / 微软雅黑` (sans) + `ui-monospace / SFMono / Cascadia / JetBrains Mono` (mono)
    - 表格斑马纹（subtle）+ hover 行高亮，TH 大写小字标签
    - Badge 改胶囊形（圆角 12px）+ 边框，色彩对比更稳
    - Summary 卡片网格化为 6 列（移动端 3 列）
    - Section 卡片去阴影，改 `border + h2 左侧 3px 蓝条`
    - Pre 块统一 mono 字体 + 浅灰背景 + 浅边框
    - 锚点跳转到目标章节时短暂高亮闪烁（`@keyframes tgt`）
    - 加入 `IntersectionObserver` scroll-spy，左侧 TOC 自动高亮当前可见章节
    - `@media print` 完整打印样式：隐藏 TOC + 整齐分页 + 黑白友好
    - 移动端响应式：< 900px 顶部横排 TOC + 单列网格

**统计：** 1289 行 → 1747 行（+458），20 项缺陷已 close 全部 20 项。

---

### v2.2 (2026-05-09) - 完全优化版本

**主要改进：**

1. **代码结构优化**
   - 将 CPU 使用率计算逻辑提取为 `get_cpu_idle()` 函数
   - 简化文件描述符统计逻辑，移除临时文件依赖

2. **内存计算优化**
   - 使用字节级精确计算内存使用率
   - 改进 Swap 使用率计算逻辑

3. **SELinux 状态检查增强**
   - 同时显示当前状态和配置文件设置
   - 添加未安装检测

4. **Docker 检查优化**
   - 添加权限检查，优雅处理权限不足情况

5. **执行时间统计**
   - 添加脚本执行时间计时功能
   - 在终端输出中显示耗时信息

6. **脚本版本管理**
   - 添加版本号标识（v2.2）
   - 在终端输出中显示版本信息

7. **语法兼容性修复**
   - 将进程替换语法 `<(command)` 替换为 Here-string 语法 `<<< "$(command)"`
   - 提高脚本在不同 bash 版本中的兼容性

8. **OOM_COUNT 语法错误修复**
   - 修复 `OOM_COUNT` 变量可能包含换行符导致的算术表达式错误
   - 添加 `tr -d ' \n'` 移除空格和换行符

9. **HTML 表格列宽优化**
   - 添加列宽 CSS 类控制表格布局
   - 优化磁盘使用、进程列表、大文件等表格的列宽分配
   - 添加 `table-layout: fixed` 固定表格布局

---

### v2.1 (2026-05-09) - 主要缺陷修复版本

**修复的严重缺陷：**

1. **缺少必要工具检查**
   - 添加 `check_dependencies()` 函数检查关键依赖
   - 检查工具：awk, grep, sed, cat, date, hostname, uname, head, tail, wc, cut, xargs

2. **系统更新检查不支持 RHEL/Kylin**
   - 添加操作系统类型检测（kylin, rhel, debian, suse）
   - 支持多种包管理器：dnf, yum, apt, zypper
   - Kylin 系统优先使用 dnf，其次 yum，最后 apt

3. **`apt update` 权限问题**
   - 添加 root 权限检查
   - 非 root 用户跳过 `apt update`，直接检查可升级包

4. **`lastb` 权限问题**
   - 添加 root 权限检查
   - 非 root 用户登录失败检查返回空结果

5. **空密码账户判断逻辑错误**
   - 修正逻辑：`$2 == ""` 才表示真正的空密码
   - `$2 == "!"` 或 `"*"` 表示密码被锁定（非空密码）

**性能优化：**

6. **大文件搜索优化**
   - 限制搜索范围到 /var, /home, /opt, /usr/local
   - 提高搜索效率，减少执行时间

7. **全局可写文件搜索优化**
   - 限制搜索范围，排除临时目录

---

### v2.0 (2026-04-08) - 初始版本

**功能特性：**

- ✅ 基本信息采集（主机名、IP、OS、内核、CPU、内存等）
- ✅ CPU 使用率检查和负载监控
- ✅ 内存和 Swap 使用情况检查
- ✅ 磁盘空间和 Inode 使用检查
- ✅ 磁盘 I/O 统计
- ✅ 文件描述符检查
- ✅ 网络状态检查（网卡、TCP 连接、监听端口）
- ✅ 进程检查（僵尸进程、D 状态进程）
- ✅ 服务状态检查
- ✅ Docker 容器检查
- ✅ 定时任务检查
- ✅ 安全检查（SSH 配置、账户审计、登录日志）
- ✅ 内核参数检查
- ✅ 系统更新检查
- ✅ 日志检查（系统日志、认证日志、OOM 事件）
- ✅ NTP 时间同步检查
- ✅ HTML 报告生成

---

## 支持的操作系统

| 操作系统 | 版本 | 包管理器 | 支持状态 |
|---------|------|---------|---------|
| Kylin | V10+ | dnf/yum/apt | ✅ 完全支持 |
| Kylin | older | yum/apt | ✅ 支持 |
| RHEL | 8+ | dnf | ✅ 完全支持 |
| RHEL | 7 | yum | ✅ 支持 |
| CentOS | 8+ | dnf | ✅ 完全支持 |
| CentOS | 7 | yum | ✅ 支持 |
| Debian | 9+ | apt | ✅ 完全支持 |
| Ubuntu | 18.04+ | apt | ✅ 完全支持 |
| SUSE | 12+ | zypper | ✅ 支持 |

---

## 修复统计

| 版本 | 严重缺陷 | 中等缺陷 | 轻微缺陷 | 新功能 | 总计 |
|------|---------|---------|---------|--------|------|
| v2.1 | 5 | 2 | 0 | 0 | 7 |
| v2.2 | 0 | 6 | 3 | 0 | 9 |
| v2.3 | 0 | 0 | 6 | 5 | 11 |
| **总计** | **5** | **8** | **9** | **5** | **27** |

**v2.3 后所有已识别缺陷（20 项）全部修复。**

---

## 使用说明

### 运行脚本

```bash
# 赋予执行权限
chmod +x linux_inspect.sh

# 执行巡检
./linux_inspect.sh

# 以 root 用户执行（获取完整信息）
sudo ./linux_inspect.sh
```

### 输出报告

脚本执行完成后，报告会生成在：
```
/tmp/inspect_report/inspect_<hostname>_<timestamp>.html
```

### 终端输出示例

```
========================================
  巡检完成: server01
  时间: 2026-05-09 14:30:00
  版本: v2.2
  警告数: 2
  严重数: 0
  耗时: 1分35秒
  报告: /tmp/inspect_report/inspect_server01_20260509_143000.html
========================================
```

---

**文档生成时间**: 2026-05-10  
**脚本版本**: v2.3