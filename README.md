# vaultwarden-1panel-hardening-manager（`vhm`）

面向 **1Panel 应用商店安装的 Vaultwarden** 的安全审计与加固助手。
兄弟项目 [vaultwarden-1panel-backup-manager](https://github.com/OmenTwwnmfm/vaultwarden-1panel-backup-manager)（`vbm`）管「数据不丢」，本项目管「门锁不坏」。

## 原则
- 1Panel 管理的对象（域名、HTTPS、反代、compose、应用参数）**只审计 + 给指引**，不自动改。
- 只有本工具完全拥有的对象（如数据目录权限）才允许 `auto`，且先快照、后健康闸门、失败自动回滚。
- 审计零写入；报告、诊断、日志不输出秘密值。
- 实例身份与 `vbm` 一致：以 `/data` 主机挂载路径为准，多候选即停止。

## 快速开始
```bash
sudo git clone https://github.com/OmenTwwnmfm/vaultwarden-1panel-hardening-manager /opt/vaultwarden-1panel-hardening-manager
cd /opt/vaultwarden-1panel-hardening-manager
sudo bash ./run.sh        # 安装 vhm 并进入菜单
```
菜单中依次执行 `[01]` 首次配置 → `[03]` 全量审计 → `[07]` 生成计划。

子命令：`vhm audit [--domain panel|exposure|app|container|host|data|supply]`、`vhm plan [--diff]`、`vhm apply`、`vhm rollback [--list]`、`vhm report show|export`、`vhm watch install|status|pause|resume|run`、`vhm diagnose`。

## 路径
| 用途 | 路径 |
|---|---|
| 配置 | `/etc/vaultwarden-hardening.conf`（600） |
| 状态/报告/快照 | `/var/lib/vaultwarden-hardening/` |
| 日志 | `/var/log/vaultwarden-hardening.log` |
| 后台脚本 | `/usr/local/lib/vaultwarden-hardening/` |

## 退出码
`0` 成功 · `1` 失败/取消 · `2` 实例无法确定 · `75` 锁冲突跳过。

完整用法见 [docs/使用手册.md](docs/使用手册.md)，规则详见 [docs/检查项说明.md](docs/检查项说明.md)。

## License
MIT
