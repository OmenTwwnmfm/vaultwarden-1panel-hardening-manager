# vaultwarden-1panel-hardening-manager（`vhm`）

面向 **1Panel + Vaultwarden** 的 VPS 加固工具：SSH 2FA、Fail2Ban、安全体检、Vaultwarden 设置管理。
兄弟项目 [vaultwarden-1panel-backup-manager](https://github.com/OmenTwwnmfm/vaultwarden-1panel-backup-manager)（`vbm`）管「数据不丢」，本项目管「门锁不坏」。

## 快速开始
```bash
sudo git clone https://github.com/OmenTwwnmfm/vaultwarden-1panel-hardening-manager /opt/vaultwarden-1panel-hardening-manager
sudo bash /opt/vaultwarden-1panel-hardening-manager/run.sh   # 安装 vhm 并进入菜单
```
以后直接运行 `sudo vhm`。建议顺序：`[01]` 首次配置 → `[02]` 安全体检 → 按体检建议处理。

## 菜单
```
01 · 快速操作        [01] 首次配置 / 识别 Vaultwarden 实例   [02] VPS 安全体检
02 · SSH 登录安全    [03] SSH 状态  [04] 登录密钥  [05] 修改端口  [06] 启用 2FA  [07] 2FA 管理  [08] 登录记录
03 · 防火墙与端口    [09] 端口与放行规则一览  [10] Docker 端口暴露检查（只读）
04 · Fail2Ban        [11] 安装 / 修改 SSH 防护  [12] 状态、封禁列表、解封
05 · Vaultwarden     [13] 状态  [14] 注册  [15] 后台 ADMIN  [16] 用户列表  [17] 安全选项
06 · 系统加固        [18] 自动安全更新  [19] 内核网络参数
07 · 系统维护        [20] 变更记录与回滚  [21] 脱敏诊断  [22] 更新源码
```

## 原则
- 每个修改都先显示要改什么，输入 `yes` 才执行；修改前保存原文件，失败自动恢复，`[20]` 可手动回滚。
- SSH 修改带 5 分钟防锁死保护：新开窗口登录成功后回来确认，否则自动回滚。
- 修改 Vaultwarden 前先调用 vbm 完整备份，备份通过远端核验才继续。
- 防火墙端口规则由 1Panel 管理，vhm 只读检查。
- 诊断与日志不输出秘密值。

完整说明见 [docs/使用手册.md](docs/使用手册.md)。

## License
MIT
