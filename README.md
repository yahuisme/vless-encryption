# vless-encryption

Xray VLESS Encryption 安装与管理脚本。

当前版本：`v26.09.10`

支持两种模式：

- VLESS Encryption
- VLESS Encryption + REALITY + Vision

客户端及其内核须支持 VLESS Encryption，并能导入链接中的 `encryption` 参数；仅支持普通 VLESS/REALITY 的客户端不适用。

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

安装或重装会覆盖 Xray 配置；修改参数或切换模式只更新首个入站的相关字段，保留监听地址及其他自定义配置。卸载会调用官方 `remove --purge`（仅残留文件时直接清理），删除 Xray 配置、日志和客户端信息，全部成功后才删除本脚本。回滚失败的快照保留并显示路径，须手动恢复或清理。

## 检查脚本

```bash
bash -n install.sh
shellcheck install.sh
```
