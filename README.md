<div align="center">

# Vaultwarden 1Panel Hardening Manager

**安全体检 · SSH 登录模式 · 1Panel / UFW 防火墙 · Fail2Ban 端口同步 · Vaultwarden 管理**

面向 Ubuntu / Debian 上通过 1Panel 应用商店安装 Vaultwarden 的 VPS

![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-blue)
![Panel](https://img.shields.io/badge/panel-1Panel-1677ff)
![SSH](https://img.shields.io/badge/ssh-password%20%7C%20key%20%7C%20TOTP-16a34a)
![Protection](https://img.shields.io/badge/protection-Fail2Ban-dc2626)
![Version](https://img.shields.io/badge/version-0.3.1-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![CI](https://github.com/OmenTwwnmfm/vaultwarden-1panel-hardening-manager/actions/workflows/ci.yml/badge.svg)

</div>

---

## 项目简介

Vaultwarden 把整个家庭或团队的密码库放在一台 VPS 上，这台服务器本身的安全就是密码库的安全。本项目提供一个交互式加固管理器：体检 VPS 当前开放了哪些端口、对哪些 IP 放行、SSH 怎么登录、有没有暴力破解防护；然后一步步完成 SSH 双因素认证、Fail2Ban、系统加固，并管理 Vaultwarden 的注册、后台和安全选项。

项目不替代 1Panel。1Panel 继续负责应用安装、Docker、域名、HTTPS 和反向代理；防火墙规则可以在 1Panel 页面或 vhm `[15]` 中修改，两边读写同一套规则。本项目负责 SSH 登录安全、防火墙规则、Fail2Ban、系统参数和 Vaultwarden 的 `config.json` 设置。兄弟项目 [vaultwarden-1panel-backup-manager](https://github.com/OmenTwwnmfm/vaultwarden-1panel-backup-manager)（`vbm`）管「数据不丢」，本项目管「门锁不坏」。

> **修改 SSH 前请先打开 VPS 服务商控制台的 VNC。** 本工具对每次 SSH 修改都有 5 分钟自动回滚保护，但 VNC 是最后的应急入口，不受 SSH 配置影响。

## 操作确认输入

所有会修改系统的操作都会先显示要改什么，再要求输入 `yes`。大小写不敏感：`yes`、`YES`、`Yes` 都可以继续；其他输入均取消。只读功能（体检、状态、端口一览、用户列表、登录记录）不需要确认，也不会修改任何文件。

## 功能特点

### v0.3.1 修复说明

- 回滚失败会记录为「回滚失败」并允许重试；自动回滚失败也会明确报警，不再被确认动作掩盖。
- 自动回滚会等待全局修改锁并检查更新的重叠变更，避免覆盖正在编辑的配置。
- UFW 规则删除改为按 `vhm` 注释定位，同条件但非 vhm 创建的规则不会被误删。
- PAM 的 `auth substack common-auth` 写法在切换登录方式时可以正确恢复。
- `sshd -T` 使用当前登录来源地址计算，`Match Address` 块能正确参与校验；2FA 状态识别 `nullok` 配置。
- Fail2Ban 的 vhm jail 缺少 `port` 行时会自动补上；源码更新对 SSH 远端禁用交互式提示。
- 本次同样只推送源码提交，不创建 GitHub Release。

### v0.3.0 升级说明

- 进入管理菜单时自动检查 GitHub main 并快进更新。工作区存在本地改动或网络不可用时保留当前代码并提示，可用 [27] 手动重试。
- 新增 SSH 登录方式选择：密码（不建议）、密钥、密码 + 动态口令、密钥 + 动态口令（推荐），并支持修改 root 系统密码。
- 新增 1Panel iptables / UFW 防火墙规则管理，支持来源 IP/CIDR 和规则顺序，修改同时写入运行规则与持久配置。
- Fail2Ban SSH jail 通过 systemd path 和 15 秒定时检查自动跟踪 SSH 端口变化。
- 菜单编号扩展到 [27]。本次只推送源码提交，不创建 GitHub Release。

### v0.2.0 升级说明

v0.2.0 从「只审计、给指引」改为可直接操作的加固工具，菜单重新编号为 `[01]`–`[26]`，0.1.x 的子命令全部移除。

- 升级后首次进入菜单，会自动停用并删除 0.1.x 的定时巡检 `vaultwarden-hardening-watch.service/.timer` 和 `/usr/local/lib/vaultwarden-hardening`。
- 0.1.x 的报告与快照留在 `/var/lib/vaultwarden-hardening/reports/`、`snapshots/`，不再使用，可手动删除。
- 详细变更见 [CHANGELOG.md](CHANGELOG.md)。

### 菜单结构

主菜单分为七类，顶部状态面板显示 SSH 端口、2FA、密码登录、防火墙、Fail2Ban 封禁数，以及 Vaultwarden 的注册与后台状态。

| 分类 | 菜单 |
|---|---|
| 01 · 快速操作 | `[01]` 首次配置 / 识别 Vaultwarden 实例　`[02]` VPS 安全体检 |
| 02 · SSH 登录安全 | `[03]` SSH 状态　`[04]` 管理登录密钥　`[05]` 修改 SSH 端口　`[06]` 登录方式　`[07]` 2FA 管理　`[08]` 登录记录 |
| 03 · 1Panel 面板 | `[09]` 面板状态 `[10]` 修改面板端口 `[11]` 修改用户名 / 密码 `[12]` 切换监听地址 `[13]` 启动 / 停止 / 重启 `[14]` 应急重置 |
| 04 · 防火墙 | `[15]` 规则列表 / 添加 / 删除（1Panel iptables 与 UFW） |
| 05 · Fail2Ban | `[16]` 安装 / 修改 SSH 防护配置　`[17]` 状态、封禁列表、解封 IP |
| 06 · Vaultwarden | `[18]` 状态总览　`[19]` 开启 / 关闭注册　`[20]` 后台 ADMIN　`[21]` 用户列表　`[22]` 安全选项 |
| 07 · 系统加固 | `[23]` 自动安全更新　`[24]` 内核网络参数加固 |
| 08 · 系统维护 | `[25]` 变更记录与回滚　`[26]` 生成脱敏诊断报告　`[27]` 检查 / 更新项目源码 |

### VPS 安全体检

`[02]` 一次检查整台 VPS，结果按 **正常 / 注意 / 危险** 标出，每项附一句处理建议：

- **端口与防火墙**：识别 1Panel 管理的防火墙（iptables / nftables）以及 ufw、firewalld；列出哪些端口对所有 IP 开放、哪些只对指定 IP 放行。体检本身只读，规则在 1Panel 或 `[15]` 中修改。
- **Docker 绕过防火墙**：容器端口发布在 `0.0.0.0` 时，外网可以绕过 OpenResty 和主机防火墙直接访问。体检会标红并实测访问；检测到 1Panel v2 的 Docker 端口访问控制时降为提示。
- **SSH**：端口、密码登录、2FA、`authorized_keys` 权限、系统时间同步。
- **Fail2Ban**：是否安装、运行、有 sshd 防护，当前封禁多少 IP。
- **系统**：root 以外 UID 为 0 的账户、sudo 用户、自动安全更新、内核网络参数、是否需要重启。
- **1Panel**：面板服务、面板端口是否对所有 IP 放行、是否为默认端口、安全入口、面板 HTTPS。
- **Vaultwarden**：开放注册、后台状态与令牌类型、`DOMAIN` 是否 https、数据目录权限、vbm 最近一次备份结果。

体检只做本机检查，无法证明公网实际可达性；云服务器还要核对服务商的安全组。

### 防火墙管理与同步

- [15] 检测当前后端并写入同一个规则体系。1Panel iptables 模式更新 1PANEL_BASIC 链并写入 1Panel 启动时读取的 firewall rules 文件；UFW 模式通过 ufw 命令写入其持久规则。
- 规则包含动作、地址族、TCP/UDP、端口和来源 IPv4/IPv6/CIDR。规则立即生效并显示在 1Panel 防火墙页面，重启后仍保留。
- 每次修改留下可回滚记录。回滚会恢复规则文件与内核运行规则，UFW 会重新加载。

### SSH 登录方式与 2FA

- [06] 可选密码登录（不建议）、密钥登录、密码 + 动态口令、密钥 + 动态口令（推荐），也可修改 root 系统密码。
- 启用密钥 + 动态口令时，root 登录必须同时通过 SSH 密钥和手机验证器上的 6 位动态口令。
- 使用 `libpam-google-authenticator`，支持 Google Authenticator、Microsoft Authenticator、2FAS 等任意 TOTP 验证器。
- 不使用 `nullok`：没有绑定动态口令就无法登录，不留「没绑定就跳过」的后门。
- 绑定时在终端显示二维码（同时给出可手动输入的密钥和 `otpauth://` 链接），先校验一次动态口令，再显示 5 个一次性应急码。
- `[07]` 可以重新显示绑定二维码（在新手机或第二个验证器上添加同一账号）、重新绑定（换新密钥）、查看剩余应急码或关闭 2FA。
- 启用前检查 root 至少有一个登录密钥、系统时间已同步，并提示其他用户和 1Panel「终端」功能会受到的影响。

### 防锁死保护

修改端口、启用或关闭 2FA、重新绑定动态口令时：

1. 写入配置后执行 `sshd -t`，并用 `sshd -T` 确认生效值确实是期望值，防止被其他配置文件覆盖。
2. 重载 SSH 服务（兼容 Ubuntu 22.10+ 的 `ssh.socket`），**当前会话不会断开**。
3. 启动 5 分钟的 systemd 定时器。你另开窗口按新方式登录，成功后回来输入 `yes` 保留。
4. 输入其他内容、超时或管理器被中断，定时器都会自动回滚。

修改端口时先同时监听新旧端口，确认新端口能登录后再关闭旧端口。Fail2Ban 通过 systemd 配置监视器和 15 秒周期核对自动同步 sshd jail 端口。

### Fail2Ban

- 未安装时自动安装；配置失败次数、统计时间窗口、封禁时长和白名单（默认填入当前连接 IP）。
- 配置写入独立的 `/etc/fail2ban/jail.d/vhm-sshd.local`，不修改系统自带文件；SSH 端口与日志后端（auth.log / systemd journal）自动识别。
- 配置先经 `fail2ban-client -t` 检查，启动失败自动恢复原配置。
- `[17]` 查看状态与封禁列表，输入 IP 即可解封。

### 1Panel 面板

全部通过 1Panel 自带的 `1pctl` 完成（按 1Panel v2 实现），vhm 不直接修改 1Panel 数据库。

- **面板状态**：版本、服务状态、面板端口、安全入口（只显示前两位）、访问协议、监听方式，以及面板端口在防火墙中是否对所有 IP 放行。
- **修改面板端口**：先检查新端口未被占用、已在 1Panel 防火墙中放行，修改后等待面板在新端口启动；失败自动改回，也可在 `[25]` 回滚。
- **修改用户名 / 密码**：可先生成一个 20 位随机密码供粘贴，再由 `1pctl` 交互输入。不保存旧值，因此不能回滚。
- **切换监听地址**：只监听 IPv4，或监听 IPv6（同时接受 IPv4）。可回滚。
- **启动 / 停止 / 重启**：兼容 v2 的 `1panel-core` / `1panel-agent` 两个服务。
- **应急重置**：被面板挡在外面时自救，可取消安全入口、授权 IP、域名绑定、面板 HTTPS、两步验证或通行密钥。只列出当前版本 `1pctl reset` 支持的项目；必须输入项目名确认，且不能回滚，恢复访问后请立即在面板中重新设置。
- 不提供卸载和数据恢复，误操作代价太大。

### Vaultwarden 管理

- **开放注册 / 邀请注册**：分别开关。
- **后台 ADMIN**：开启时自动生成随机密码（只显示一次）或自己输入，`config.json` 中只保存 argon2id 哈希；不用时可一键关闭。
- **用户列表**：邮箱、注册时间、最近活动、是否开启两步验证、是否被禁用。只读打开 SQLite，不修改数据库。
- **安全选项**：密码提示、登录页显示提示、Send、紧急访问、可创建组织的用户、图标服务，支持一键推荐设置。
- 设置写入数据目录的 `config.json`，与在 `/admin` 页面保存的效果相同。它优先于 1Panel 应用参数，且 1Panel 升级或重建应用时不会被覆盖。`[18]` 显示每项的实际生效值和来源。

### 修改前自动备份

每次修改 Vaultwarden 设置：

1. 先调用 vbm 做一次完整备份（Vaultwarden 会短暂停止）。本地校验、服务恢复、远端核验全部通过才继续；vbm 正在执行定时备份时直接放弃，不会修改。
2. 修改期间持有 vbm 的锁，避免定时备份在重启容器时介入。
3. 保存原 `config.json` → 原子写入（权限 `600`）→ 重启容器 → 等待健康检查（最长 120 秒）。
4. 健康检查失败自动恢复原 `config.json` 并再次重启。

未安装 vbm 时会额外要求确认，并仍保存修改前的 `config.json` 供回滚。

### 系统加固

- **自动安全更新**：安装并启用 `unattended-upgrades`。只装系统安全更新，不升级容器和 1Panel 应用，不自动重启。
- **内核网络参数**：开启 SYN cookies，拒绝 ICMP 重定向与源路由，开启反向路径过滤（宽松模式，兼容 Docker），忽略广播 ping。写入 `/etc/sysctl.d/90-vhm-hardening.conf`，不修改 `ip_forward`。

### 变更记录与回滚

- 每次修改前保存涉及的原文件、权限和属主，记录在 `/var/lib/vaultwarden-hardening/changes/`。
- `[25]` 列出最近 30 条变更和占用空间，可按条回滚；回滚后自动重新加载 SSH、Fail2Ban、内核参数、1Panel 面板设置、防火墙规则或重启 Vaultwarden。
- 可删除指定记录（支持 `3 5 8-12` 这样的多选和范围）、一键删除已回滚的记录，或只保留最近 N 条。
- 自动清理：保留最近 50 条以及 90 天内的全部记录，更早的在下次修改时自动删除。防锁死保护中的记录不会被删除。
- 修改操作互斥，同时只能有一个在运行；冲突时以退出码 `75` 明确跳过。

### 全局快捷命令

- 每次通过 `sudo bash ./run.sh` 启动时，都会自动安装或修复 `/usr/local/bin/vhm`。
- 之后在任意目录执行 `sudo vhm` 即可进入菜单。
- 每次进入菜单时，vhm 自动检查 GitHub main。工作区干净且可快进时自动更新并重启菜单；本地有改动或网络不可用时保留当前版本，可用 [27] 手动重试。
- `vhm` 指向当初克隆的项目目录，项目目录不要随意移动或删除。

## 快速开始

```bash
sudo git clone https://github.com/OmenTwwnmfm/vaultwarden-1panel-hardening-manager /opt/vaultwarden-1panel-hardening-manager
cd /opt/vaultwarden-1panel-hardening-manager
sudo bash ./run.sh
```

第一次也可以先只做体检、不动系统：进入菜单选 `[02]`，或退出后运行 `sudo vhm checkup`。体检是只读的，不会修改任何文件；先看清哪些项是「危险」，再决定改什么。会改哪些文件、哪些事明确不会做、怎么回滚，见 [安全与影响说明](docs/安全与影响说明.md)。

推荐顺序：

1. `[01]` 首次配置：检查依赖、识别 Vaultwarden 实例（已安装 vbm 时复用其实例）。
2. `[02]` 安全体检，先看哪些项是「危险」。
3. `[04]` 确认 root 的登录密钥都是你自己的。
4. `[15]` 管理防火墙规则，`[16]` 启用 Fail2Ban。
5. `[06]` 选择 SSH 登录方式，使用动态口令时另开窗口测试登录后再确认。
6. `[19]` 关闭开放注册，`[20]` 不用时关闭后台，`[22]` 应用推荐安全选项。
7. `[23]` 自动安全更新，`[24]` 内核网络参数。
8. 体检提示 Docker 端口暴露时，在 1Panel 应用参数中取消「端口外部访问」。

## 文件与路径

| 用途 | 路径 |
|---|---|
| 配置（实例） | `/etc/vaultwarden-hardening.conf`（`600`） |
| 变更记录 | `/var/lib/vaultwarden-hardening/changes/` |
| 日志（已脱敏） | `/var/log/vaultwarden-hardening.log` |
| SSH 配置 | `/etc/ssh/sshd_config.d/00-vhm.conf` |
| 2FA 绑定 | `/root/.google_authenticator`（`400`） |
| Fail2Ban | `/etc/fail2ban/jail.d/vhm-sshd.local` |
| 内核参数 | `/etc/sysctl.d/90-vhm-hardening.conf` |
| Vaultwarden 设置 | `<数据目录>/config.json` |

## 命令行

`sudo vhm` 进入交互菜单。只读子命令：`checkup`、`ports`、`ssh-status`、`vw-status`、`vw-users`、`changes`、`diagnose`、`deps`、`version`；`rollback <变更ID>` 回滚一条变更。修改操作只在菜单中提供。

退出码：`0` 成功 · `1` 失败或取消 · `2` 实例无法确定 · `75` 另一个修改操作正在运行。

## 常见问题

**启用 2FA 后登录被拒怎么办？** 先确认系统时间已同步，再尝试用应急码登录。仍不行就在保护时间内什么都不做，等待自动回滚；或通过 VNC 登录，用 `vhm changes` 查看变更 ID 后执行 `vhm rollback <变更ID>`。

**为什么启用 2FA 后 `PermitRootLogin` 是 `yes`？** 认证方式已强制「先通过密钥，再输入动态口令」，密码登录同时关闭，所以不会放开 root 密码登录。设为 `prohibit-password` 会让动态口令那一步被拒绝。关闭 2FA 时自动改回 `prohibit-password`。

**1Panel「SSH 管理」显示的值和实际不一致？** vhm 的配置在 `sshd_config.d/00-vhm.conf`，优先于主配置。以 `[03]` 显示的生效值为准，SSH 建议只用 vhm 管理。

**1Panel 的网页「终端」用不了了？** 它通过 SSH 连接本机，启用 2FA 后无法使用。1Panel 的「容器终端」不走 SSH，不受影响。

**改了 1Panel 应用参数却不生效？** `config.json` 中的同名设置优先。用 `[18]` 查看每项的来源，在 vhm 中修改即可。

**防火墙里关了端口，外网还能访问 Vaultwarden？** Docker 发布的端口会绕过 ufw / firewalld。在 1Panel →「已安装应用」→ Vaultwarden →「参数」中取消「端口外部访问」，让容器只监听 `127.0.0.1`。

**提示「发现多个候选实例」？** 在 `/etc/vaultwarden-hardening.conf` 中填写 `VW_DATA_DIR`（容器 `/data` 对应的主机路径），再运行 `[01]`。

## 安全声明

- 修改 SSH 前请确认能通过服务商控制台的 VNC 登录。
- 2FA 应急码请离线保存；手机丢失且应急码用完时，只能通过 VNC 恢复。
- 后台 ADMIN 密码只显示一次，请立即保存到密码管理器；不用后台时建议关闭，或在 1Panel 反向代理中限制 `/admin` 的来源 IP。
- 管理器需要从 root 所有且普通用户不可修改的目录运行；推荐按快速开始安装到 `/opt`。
- 诊断报告和日志只输出配置项名称、状态和路径，不输出令牌、哈希、密码等秘密值。
- 本项目不构成安全审计或安全保证，请自行评估风险。

## 贡献

欢迎提交 Issue 或 Pull Request。涉及 SSH、PAM、防火墙和容器启停的修改，请同时提供 shellcheck 结果、测试结果，以及防锁死和回滚路径的说明。不要在 Issue 中上传真实配置、应急码、令牌或未脱敏的日志；需要环境信息时请贴 `[26]` 的脱敏诊断报告。

## 开发与测试

CI 在每次推送和 Pull Request 时运行 shellcheck、全部测试、密钥泄漏扫描和发布策略检查。本地可用同样的命令验证：

```bash
shellcheck -x run.sh scripts/*.sh tests/*.sh
for t in tests/test-*.sh; do bash "$t"; done
```

提交涉及 SSH、PAM、防火墙和容器启停的修改前，请先在本地跑通全部测试，并说明防锁死与回滚路径。

## 文档

- [快速开始](docs/快速开始.md)
- [使用手册](docs/使用手册.md)
- [安全与影响说明](docs/安全与影响说明.md)
- [路线图](ROADMAP.md)
- [更新日志](CHANGELOG.md)

## License

MIT License。详见仓库中的 `LICENSE`。
