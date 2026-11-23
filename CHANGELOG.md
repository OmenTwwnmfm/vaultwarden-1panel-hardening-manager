# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed
- 脱敏不再误伤绝对路径、URL 与 `PasswordAuthentication=yes` 等普通配置；仍屏蔽 `*_TOKEN/*_PASSWORD/*_SECRET/*_KEY` 值、argon2 哈希与长随机串。
- D-02 覆盖 `db.sqlite3-wal`、`db.sqlite3-shm`、`rsa_key*`、`attachments/`、`sends/`；审计、`plan --diff`、apply 快照共用同一路径列表。
- D-01 不再把 `failed: 0` 判为失败，并以 `vbm status` 退出码为准。
- E-03 明确外部探测协议（响应体只含 3 位状态码），非法响应判 unknown。
- 通知与外部探测的 URL（可能含 token）经标准输入传给 curl，不再出现在进程命令行。
- 审计、应用、回滚与巡检统一加互斥锁（冲突退出码 75），内部调用可重入。
- apply 部分失败时返回非 0；快照目录名带 PID 防止同秒冲突。
- 修正 `vh-apply.sh`、`confirm_yes` 注释与实际行为不一致。
- 依赖检查补充 curl、ss、git。

### Added
- 测试：`test-redaction-paths`、`test-perms-coverage`、`test-apply-rollback`、`test-d01-vbm-status`、`test-e03-probe`、`test-audit-lock`、`test-notify-no-argv`，公共桩库 `tests/lib.sh`。
- 文档：`docs/使用手册.md`。

## [0.1.0] - 2026-11-23

### Added
- 项目骨架：`run.sh` 安装器、`vhm` 全局命令、冻结菜单 `[01]–[23]`。
- 公共库 `vh-common.sh`：日志、`yes` 确认、锁（冲突退出码 75）、脱敏、实例识别。
- 配置样例 `scripts/hardening.conf.example`。
- 只读审计 `checks/10–70` 与 `vh_rules.py`（JSON schema_version=1、Markdown 报告、A–D 评级）。
- 加固计划 `vh-plan.sh`（1Panel 条目只给面板指引，`--diff`）。
- 应用/回滚：仅 D-02 自动；权限快照 + sha256、健康闸门、失败自动回滚。
- 定时巡检 systemd timer，仅新增失败项时通知（Telegram/ntfy/Webhook）。
- 加固指引、脱敏诊断、logrotate、CI 与基础测试。
