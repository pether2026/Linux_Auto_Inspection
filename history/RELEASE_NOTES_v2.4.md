# Linux Auto Inspection v2.4 Release Notes

**发布日期**: 2026-05-10
**代号**: 提速 + Token Insight 风排版
**代码量**: 1289 行 → **2012 行**（+723 行）
**测试机器**: jum-dev (Rocky Linux 10.1 / 192.168.2.14)

---

## 升级亮点

### 🚀 性能优化（实测 60s → 8-15s）

| 优化点 | 之前 | 之后 | 估省 |
|---|---|---|---|
| 服务检查 | 38 次 `systemctl list-unit-files \| grep` fork | 调一次缓存到字符串，循环 `grep <<<` 匹配 | **3-5s** |
| CPU IDLE 检测 | `top → mpstat 1 1 → vmstat 1 2 → /proc/stat sleep 1` 多重 fallback | 直接 `/proc/stat` + 200ms 间隔 | **1-3s** |
| dmesg 调用 | OOM + HW errors 各调一次 | 缓存共用 | **1-2s** |
| 密码过期检查 | 每用户 fork `chage` | `awk` 直读 `/etc/shadow` 字段 | **0.5-2s** |
| SUID/SGID 扫描 | `find` 跑两次 | 合并一次 + `awk` 分流 | **0.5-1s** |

### 🆕 快速模式 / 命令行参数

```bash
./linux_inspect.sh --fast                   # 快速模式（推荐日常巡检，10s 左右）
./linux_inspect.sh -f json -o /tmp/r.json   # JSON 输出（对接监控）
./linux_inspect.sh -v --skip-update-check   # 详细日志 + 不查更新
./linux_inspect.sh -h                       # 帮助
```

| 参数 | 作用 |
|---|---|
| `-o FILE` | 自定义报告路径 |
| `-f FORMAT` | `html` / `json` |
| `-v / --verbose` | Debug 日志 |
| `-q / --quiet` | 静默模式 |
| `--no-large-file-scan` | 跳过 find 大文件 |
| `--skip-update-check` | 跳过包管理器联网（最慢的单步） |
| `--skip-ssl-check` | 跳过 SSL 证书 |
| `--fast` | 一键开 3 个 skip |

### 🆕 SSL 证书过期检查

新增第 15 章节，自动扫描 `/etc/letsencrypt/live`、`/etc/ssl/certs`、`/etc/pki/tls/certs`、`/etc/nginx/ssl` 等路径，提取 CN / 到期时间 / 剩余天数，剩余 < 30 天告警。

### 🆕 JSON 输出 + Exit Code 语义化

```json
{
  "version": "v2.4",
  "host": { "hostname": "jum-dev", "ip": "192.168.2.14", "os": "Rocky Linux 10.1", ... },
  "metrics": { "cpu_usage_pct": 12, "mem_usage_pct": 34, ... },
  "ssl": { "total": 4, "expiring_in_30_days": 2, "expired": 0 },
  "result": { "warnings": 2, "critical": 0, "exit_code": 1 }
}
```

退出码：
- `0` = 正常（无警告/无严重）
- `1` = 有警告
- `2` = 有严重告警 / 脚本错误

可直接对接 Prometheus / Telegram bot / CI/CD 流水线。

### 🆕 巡检 banner + 步骤进度

```
==============================================
  Linux Inspection v2.4
  Host: jum-dev
  Time: 2026-05-10 20:34:46
  Format: html  |  Verbose: off
  Steps: 19
==============================================
[ 1/19] (  5%) 采集基本信息（主机/CPU/内存/网络/虚拟化）...
[ 2/19] ( 10%) 检查 CPU 使用率与负载...
...
```

### 🎨 HTML 模板重构（Token Insight 风）

- **顶部蓝色 banner** — 横向 6 字段 metadata（主机/IP/操作系统/内核/生成时间/工具版本）+ "巡检"标签徽章 + 右上角格式标识
- **17 个章节加蓝色编号** — `1./2./.../17.` 前缀 + 浅蓝色标题底栏贴边铺满
- **Summary 卡片重设计** — 左侧 38×38 方形彩色 SVG 图标 + 右侧大数字 + 状态标签（良好/警告/严重）
- **基本信息 4 列网格** — 更紧凑可读
- **深色侧栏 TOC** — 顶部 SVG logo + 名称版本 + 分组导航（资源 / 运行时 / 安全维护）
- **第 17 章节"总体建议"** — 短期/中期/长期 3 列卡片（橙/蓝/绿顶部边框），**根据告警动态生成**：
  - 短期：处理严重告警、清理磁盘、续签过期证书、清僵尸进程
  - 中期：梳理警告、安装更新、加固 SSH、检查备份监控
  - 长期：建立健康基线、自动化巡检、容量规划、合规归档
- **免责声明区** — 灰底框说明报告生成原理与使用建议
- **IntersectionObserver scroll-spy** — TOC 自动高亮当前可见章节
- **完整 `@media print` 打印样式** — 隐藏 TOC + 整齐分页 + 黑白友好

---

## 累计修复（v2.0 → v2.4 共 20 项缺陷已全部 close）

| 版本 | 严重 | 中等 | 轻微 | 新功能 |
|---|---|---|---|---|
| v2.1 | 5 | 2 | 0 | 0 |
| v2.2 | 0 | 6 | 3 | 0 |
| v2.3 | 0 | 0 | 6 | 5 |
| v2.4 | 0 | 0 | 0 | 8 |

### v2.1 严重缺陷（5）
1. 缺少必要工具检查（`awk/grep/sed/...`）
2. `apt update` 需要 root 权限
3. `lastb` 需要特殊权限
4. 空密码账户判断逻辑错误（误把 `!`/`*` 锁定状态当空密码）
5. 系统更新检查不支持 RHEL/Kylin

### v2.2 重要优化（6 中等 + 3 轻微）
- CPU 检测函数化（`get_cpu_idle()`）
- 内存字节级精算
- SELinux 配置增强（同时显示当前状态 + 配置文件）
- Docker 权限优雅处理
- HTML 表格列宽 CSS 优化
- here-string 兼容性修复
- OOM_COUNT 算术错误修复
- 执行时间统计 + 版本号显示

### v2.3 收尾 + 新功能（6 轻微 + 5 新）
- 错误处理（`trap ERR` + `mkdir` 失败处理）
- 代码重复消除（`ps_top_to_html()` / `pre_block()` 通用函数）
- 魔法数字外提（10+ 配置变量）
- Bash 版本检查
- 日志详细度控制（`log_debug` / `-v` / `-q`）
- HTML 转义完善 + footer 版本号修复
- **新功能**：SSL 证书 / HTML 目录导航 / JSON 输出 / Exit code / 命令行参数

---

## 升级建议

### 从 v2.0 升级

```bash
git pull origin main
chmod +x linux_inspect.sh
./linux_inspect.sh --fast    # 推荐先用快速模式验证
```

### 配置兼容性

v2.4 完全向下兼容，原有配置不需要改。新增配置项（可选）：

```bash
CRIT_OFFSET=10                  # 严重 = 警告阈值 + 此偏移
CONN_CLOSE_WAIT_THRESHOLD=50    # CLOSE_WAIT 偏高阈值
SSL_CERT_DAYS_WARN=30           # SSL 证书剩余天数告警阈值
TOP_N=10                        # ps/file 等 TOP 列表条数
FD_TOP_N=5                      # 文件描述符 TOP 条数
RECENT_FILE_DAYS=7              # 最近修改大文件天数
RECENT_FILE_SIZE="+50M"         # 最近修改大文件阈值
LARGE_FILE_SEARCH_PATHS="/var /home /opt /usr/local"
```

### 报告路径变化

无变化，仍是 `/tmp/inspect_report/inspect_<hostname>_<timestamp>.html`。

可用环境变量自定义：
```bash
INSPECT_REPORT_DIR=/var/log/inspect ./linux_inspect.sh
```

或命令行：
```bash
./linux_inspect.sh -o /var/log/inspect/today.html
```

---

## 已知限制

1. **未在 Linux 真机大规模实测** — 当前仅在 jum-dev (Rocky Linux 10.1) 跑过验证，建议在你的环境先用 `--fast` 试一次
2. **Bash 4.0+ 强制要求** — CentOS 6 / 老版 RHEL 5 等极老系统不支持
3. **大文件扫描在 NAS / 大容量机器仍较慢** — 建议这类机器走 `--no-large-file-scan` 或 `--fast`
4. **iostat 依赖 sysstat 包** — 没装会跳过磁盘 I/O 章节（不影响其他）

---

## 后续路线（暂未做）

- `--watch` 持续监控模式
- 与上次巡检对比（baseline.json）
- 钉钉 / 飞书 / Telegram 推送内置
- CIS 安全基线打分
- Podman / K8s pod 状态扩展

---

## 致谢

本次发布修复 20 项已识别缺陷 + 新增 13 项关键改进，从 v2.0 的 1100+ 行成长到 v2.4 的 2012 行。

完整历史见 [CHANGELOG.md](CHANGELOG.md)，缺陷分析报告见 [linux_inspect_script_analysis.md](linux_inspect_script_analysis.md)。

GitHub: https://github.com/Aidan-996/Linux_Auto_Inspection
