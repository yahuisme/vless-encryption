# vless-encryption

Xray VLESS Encryption 安装与管理脚本。

当前版本：`v26.08.27`

支持两种模式：

- VLESS Encryption
- VLESS Encryption + REALITY + Vision

需要 root 权限，脚本会自动安装缺失的 `curl`、`jq`。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh)
```

## 无交互安装

VLESS Encryption：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh) install --port 12345
```

VLESS Encryption + REALITY + Vision：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/vless-encryption/main/install.sh) install --port 12345 --sni www.sega.com
```

参数：

```text
--port <端口>              默认 443
--uuid <UUID>              自动生成
--auth <mlkem768|x25519>   默认 mlkem768
--mode <native|xorpub|random> 默认 native
--sni <域名>               启用 REALITY + Vision
--short-id <十六进制 ID>   默认 20220701，仅 REALITY 可用
```

不带 `--sni` 安装 VLESS Encryption，带 `--sni` 安装 REALITY 模式。

## 管理

直接运行脚本进入菜单，可执行安装、更新、重启、卸载、修改配置和查看订阅。

安装或重装会覆盖 Xray 配置。卸载会调用官方 `remove --purge`，并删除 Xray 配置、日志、客户端信息、本脚本及临时回滚文件，不保留备份。

## 检查脚本

```bash
bash -n install.sh
shellcheck install.sh
```
