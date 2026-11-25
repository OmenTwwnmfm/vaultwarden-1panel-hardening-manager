# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.3.0] - 2026-11-25

### Added
- SSH 登录方式菜单支持密码（不建议）、密钥、密码 + TOTP、密钥 + TOTP，提供 root 密码修改。模式修改有生效值校验和 5 分钟防锁死保护。
- 防火墙菜单支持 1Panel iptables 与 UFW，规则按来源 IP/CIDR、协议、端口和优先顺序实时生效并写入持久配置，变更可回滚。
- Fail2Ban SSH jail 使用 systemd path 和定时器检测 sshd 配置变化，自动同步 vhm 管理的 SSH jail 端口。
- 每次进入菜单自动检查 GitHub main 并尝试快进更新；源码有本地改动或网络不可用时提示并保留现状。不创建 GitHub Release。
- 菜单扩展至 [27]。

## [0.2.0] - 2026-11-24

**不兼容变更**：从「只审计、给指引」改为「VPS + Vaultwarden 加固工具」，菜单重新编号为 `[01]–[26]`，旧子命令全部移除。v0.3.0 在 [14] 后增加防火墙管理项，后续菜单编号顺延到 [27]。

### Added
- 新菜单：顶部状态面板（SSH 端口 / 2FA / 密码登录、防火墙、Fail2Ban、Vaultwarden 注册与后台），按 7 个大类分组，样式与 vbm 一致。
- `[02]` VPS 安全体检（只读）：端口、防火墙、Docker 绕过防火墙、SSH、Fail2Ban、系统账户、自动更新、内核参数、1Panel、Vaultwarden、vbm 备份；按 正常 / 注意 / 危险 标出并附处理建议。
- SSH：状态、登录密钥管理（拒绝删除唯一密钥或当前会话的密钥）、修改端口（先双端口监听，确认后关闭旧端口，同步 Fail2Ban）、登录记录与失败 IP 排行。
- SSH 2FA：密钥 + 动态口令（`libpam-google-authenticator`），仅 root，不留 `nullok`；绑定时在终端显示二维码（附手动输入密钥），先校验一次口令并生成 5 个应急码；支持重新显示二维码、重新绑定、查看应急码、关闭。
- 软件包安装失败时自动 `apt-get update` 重试，并区分「DNS 不可用」与「apt 下载用户读不到 DNS 配置」两种情况给出处理方法。
- 所有 SSH 修改带 5 分钟防锁死保护：`sshd -t` 与生效值校验，systemd 定时器到时未确认自动回滚，当前会话不断开。
- Fail2Ban：安装、SSH 防护配置（`jail.d/vhm-sshd.local`，自动识别端口与日志后端，白名单默认填入当前 IP）、状态、封禁列表、解封。
- 防火墙交给 1Panel 管理：体检识别 1Panel 的 iptables / nftables 防火墙以及 ufw、firewalld，按「对所有 IP 开放 / 只对指定 IP 放行 / 被拦截」列出监听端口；Docker 端口暴露检查并入体检，检测到 1Panel v2 的 Docker 端口访问控制时降为提示。
- 1Panel 面板（`[09]`–`[14]`，通过 `1pctl`，按 v2.5 实现）：面板状态、修改面板端口（检查占用与放行，可回滚）、修改用户名 / 密码、切换 IPv4 / IPv6 监听（可回滚）、启动 / 停止 / 重启、应急重置（安全入口、授权 IP、域名、HTTPS、两步验证、通行密钥，需输入项目名确认）。
- Vaultwarden：状态总览、开关开放注册 / 邀请注册、后台 ADMIN（argon2id 哈希令牌或关闭）、用户列表（只读打开数据库）、安全选项（密码提示、Send、紧急访问、组织创建、图标服务）。设置写入数据目录的 `config.json`。
- 修改 Vaultwarden 前自动调用 vbm 完整备份，本地校验、服务恢复、远端核验全部通过才继续；修改期间持有 vbm 锁避免定时备份介入；重启后健康检查失败自动恢复。
- 系统加固：自动安全更新（unattended-upgrades）、内核网络参数（`/etc/sysctl.d/90-vhm-hardening.conf`）。
- `[24]` 变更记录与回滚：每次修改前保存原文件，可按条回滚；可删除指定记录（支持多选和范围）、删除已回滚的记录、只保留最近 N 条，并显示占用空间。自动保留最近 50 条以及 90 天内的记录，防锁死保护中的记录不会被删除。
- 测试：`test-change-rollback`、`test-change-prune`、`test-vw-config`；`test-menu-interaction` 改为校验分发分支与子命令。

### Removed
- 审计 / 计划 / 应用 / 回滚快照流程、A–D 评级、JSON 报告、指引菜单、定时巡检与通知、`EXTERNAL_PROBE_URL`。
- 升级后首次进入菜单时自动停用并删除旧的 `vaultwarden-hardening-watch.service/.timer` 和 `/usr/local/lib/vaultwarden-hardening`。

## [0.1.0] - 2026-11-23

### Added
- 项目骨架：`run.sh` 安装器、`vhm` 全局命令、菜单 `[01]–[23]`。
- 公共库 `vh-common.sh`：日志、`yes` 确认、锁（冲突退出码 75）、脱敏、实例识别。
- 只读审计、加固计划、权限自动修复与回滚、定时巡检与通知、加固指引、脱敏诊断、logrotate、CI 与基础测试。
