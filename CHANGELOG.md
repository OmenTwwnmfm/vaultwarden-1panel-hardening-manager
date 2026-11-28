# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.4.1] - 2026-11-28

### Changed
- 项目改名为 `vaultwarden-hardening-manager`，更新安装地址、CI 徽章、菜单和源码更新地址。兄弟项目链接与提示同步为 `vaultwarden-backup-manager`。`vhm` 命令及已有配置、日志和变更记录路径不变。
- README 增加演示菜单预览；使用手册补上旧仓址迁移、固定版本安装和更新签名校验说明。

### Fixed
- 初始化时保留已有配置父目录的权限。首次配置在确认后持锁执行，配置保存失败时明确报错。
- 修改 Vaultwarden 配置前确认 vbm 备份的是当前实例的数据目录。回滚时也持有 vbm 锁，避免与备份同时重启容器；保留配置中显式设置的空字符串。
- 源码更新执行前重新核对官方 origin、分支、当前提交和工作区；不在日志中回显非官方远端 URL。
- SSH 变更先保存原配置并启用两种回滚保护，再写入系统配置。修改 SSH 端口时校验两阶段的生效端口，最终确认状态保存后才停止定时器。
- UFW 删除记录保存原顺序，只有规则表仍与删除后状态一致时才自动恢复。无法确认原位置的旧记录或双栈删除改为提示人工处理，避免改变防火墙规则优先级。
- 修复端口体检漏掉同端口的非环回监听、防火墙后端名称读取失败，以及系统参数回滚吞掉部分失败的问题。

### CI
- 本地开发验证和 CI 共用 Bash 语法与测试入口。发布策略同时检查版本格式、变更日志、版本徽章和指向待发布提交的版本标签。

## [0.4.0] - 2026-11-27

### Changed
- **源码更新默认改为「提示后确认」**：进入菜单时检查 GitHub main，有新版本时列出待更新的提交，输入 `yes` 才快进。配置文件新增 `AUTO_UPDATE=notify|apply|off`（默认 `notify`；`apply` 为 0.3.x 的自动更新行为）与 `UPDATE_REQUIRE_SIGNED=1`（只接受通过 `git verify-commit` 的提交）。
- Fail2Ban 端口同步：`.path` 改为监视整个 `/etc/ssh/sshd_config.d/` 目录，兜底定时器由 15 秒放宽到 5 分钟。已安装的单元在进入菜单时自动更新。
- `scripts/vh-common.sh` 按主题拆分到 `scripts/lib/`（日志与锁、Vaultwarden、变更记录、SSH、防火墙、1Panel、Fail2Ban、源码更新），函数与行为不变。

### Added
- **保护期内重启也会自动回滚**：SSH 变更启用防锁死保护时安装常驻的 `vhm-guard-boot.service`，开机时回滚仍未确认的受保护变更；已确认或之后有新变更改过同一文件的不会回滚。
- 体检新增 root 直接登录、空密码、`MaxAuthTries`、`LoginGraceTime`、`X11Forwarding` 检查，以及 vhm 后台服务指向的脚本是否存在。
- 项目目录被移动或重新克隆后，进入菜单时自动把 vhm 的 systemd 单元改到当前位置。
- `run.sh` 安装日志轮转配置 `/etc/logrotate.d/vaultwarden-hardening`。
- 防火墙添加「所有 IP」规则时提示只作用于所选地址族；1Panel 修改用户名 / 密码的确认文案注明无法回滚。
- 使用手册新增「VNC 手动恢复」与「改用普通用户登录」。

### Fixed
- 防火墙添加规则后的回读改为先完整读取再匹配，避免大规则链下 `grep -m1` 提前退出触发 SIGPIPE 误报失败；规则编号按完整编号匹配。

### CI
- 第三方 Action 固定到提交 SHA，工作流权限收紧为 `contents: read`；移除从不失败的 shfmt 步骤，新增 `bash -n` 语法检查；shellcheck 覆盖 `scripts/lib/`。
- 发布策略测试同时校验 README 版本徽章。

### Tests
- 新增源码更新（官方 origin、分支、脏工作区、非快进、网络失败、签名校验、确认前不改源码）、开机回滚、systemd 单元刷新的测试；防火墙测试覆盖编号前缀误匹配。

## [0.3.2] - 2026-11-27

### Fixed
- 端口体检按 `1PANEL_BASIC_BEFORE → 1PANEL_BASIC → 1PANEL_BASIC_AFTER` 的实际顺序判断，修复 BEFORE 中的 SSH 端口放行被误报为“被防火墙拦截”。
- 防火墙菜单和 1Panel 面板状态同时显示三条 1Panel 链；vhm 新建规则仍写入 `1PANEL_BASIC`。

### Tests

- 新增 `port_scope` 的链顺序、来源限制、loopback/ESTABLISHED 过滤测试。

## [0.3.1] - 2026-11-27

### Fixed
- 回滚失败时记录状态改为 `rollback_failed`，不再错误标记为已回滚；修复问题后可在 [25] 重试。自动回滚失败时确认动作会报警并拒绝冒充成功。
- UFW 规则删除按 `vhm` 注释定位并核对删除结果，同条件但由 1Panel 或其他工具创建的规则不会被误删；UFW 添加被跳过时给出明确提示。
- PAM 的 `auth substack common-auth` 写法在切回密码或密钥登录时能正确取消注释。
- 自动回滚会等待全局修改锁，并检测之后是否有改过同批文件的新变更，避免覆盖正在编辑的配置。
- `sshd -T` 使用当前 SSH 客户端的真实来源地址计算，`Match Address` 块能正确参与生效值校验。
- UFW 调用固定英文 locale，非英文系统不再误判防火墙状态；检测到 1Panel iptables 链时优先按 1Panel 后端处理。
- 端口体检按 `1PANEL_BASIC_BEFORE → 1PANEL_BASIC → 1PANEL_BASIC_AFTER` 的实际顺序判断，修复 BEFORE 中的放行（如 SSH 端口）被误报为拦截；防火墙和面板状态同时显示三条链。
- 2FA 状态识别 `nullok` 和未注释的 `common-auth`，状态页、体检和 2FA 管理会提示配置与显示不一致。
- 变更记录删除先完整校验序号再执行，避免部分删除；数据目录体检同时检查组权限；修正多处菜单编号引用。
- 防锁死确认与定时器回滚的竞态：确认保留时在变更记录锁内先行认领（新增 `confirmed` 状态），自动回滚在锁内复查状态，不再出现「界面报成功、配置却被回滚、记录显示已生效」的不一致。
- `/etc/pam.d/sshd` 改为同目录临时文件 + 原子替换写入，避免写一半断电留下残缺 PAM 配置。
- SSH 登录方式的生效值校验补上 `PermitRootLogin`，与写入的 drop-in 保持一致。
- 防火墙来源地址在下发与确认回显前归一化（如 `1.2.3.4/24` → `1.2.3.0/24`），确认文案与实际放行范围一致。
- google-authenticator 失败输出不再写入日志（只回显当前终端），避免种子/应急码落盘；apt 代理地址写日志前去掉内嵌凭据。
- 全局锁与 vbm 锁拒绝符号链接；运行日志以 `600` 权限创建；`vhm` 启动器每次运行复检项目目录权限；已保存的 Vaultwarden 容器/数据目录配对会复检 `/data` 挂载。
- 面板监听模式为具体地址或未知时，变更前明确提示回滚不能自动恢复监听方式；防锁死确认提示注明保护期内重启机器将使自动回滚失效。
- Fail2Ban 的 vhm jail 缺少 `port` 行时自动补写；源码更新对 SSH 远端使用 `BatchMode`，避免卡在交互提示。

### Tests

- 新增回滚失败后重试、PAM 两种 `common-auth` 写法、UFW 标记删除、大 iptables 输出、端口链顺序和 SSH 登录方式识别的回归测试。

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
