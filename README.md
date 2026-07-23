# sing-box

轻量级 sing-box 管理脚本，适用于 Alpine Linux 或 Debian/Ubuntu。

| 项目 | 内容 |
|---|---|
| 安装脚本 | `install.sh` |
| 管理命令 | `sb` |
| 项目地址 | <https://github.com/fexumo/sing-box> |

## 快速开始

```sh
# 下载、审阅并安装
curl -fLO https://raw.githubusercontent.com/fexumo/sing-box/main/install.sh
chmod 0755 install.sh
sudo ./install.sh i

# 添加 VLESS Reality
sb a vl -p 443 -s www.speedtest.net

# 查看状态与节点
sb c
sb l
sb u all -s example.com
```

固定内核版本安装：

```sh
sudo ./install.sh i -v v1.13.14
```

> 脚本不会自动调整防火墙或云安全组，请自行放行对应端口。

---

## 特性

- 支持 Alpine/OpenRC、Debian/Ubuntu/systemd、`amd64`、`arm64`；
- sing-box 使用独立非 root 账户运行；
- 官方内核下载与 SHA-256 校验；
- 配置应用前执行 `sing-box check`；
- 配置、内核、恢复和首次安装失败时自动回滚或清理；
- 严格 TLS 证书校验和原子证书轮换；
- 安全备份、私有副本恢复、中断事务恢复；
- 安全管理脚本自更新。

## 支持协议

| 短名 | 协议 | 传输 |
|---|---|---|
| `ss` | Shadowsocks 2022 | TCP + UDP |
| `tj` | Trojan | TCP + TLS |
| `vl` | VLESS + Reality | TCP |
| `at` | AnyTLS | TCP + TLS |
| `hy` | Hysteria2 | UDP + TLS |
| `sn` | Snell v6 | TCP |

> Snell v6 要求 sing-box 1.14 或更高版本。

## 系统要求

- Alpine Linux 或 Debian/Ubuntu；
- root 权限；
- `amd64` 或 `arm64`；
- 可访问 GitHub API 和 GitHub Release。

---

## 命令速查

```text
sb i [-v VERSION]                         安装
sb a <协议> [选项]                        添加或重建协议
sb d <协议> -y                            删除协议
sb l                                      协议列表
sb u [协议|all] [-s SERVER]               输出连接 URI
sb c                                      校验配置
sb v                                      内核版本和服务状态
sb cert <tj|at|hy> -s 域名 -c 证书 -k 私钥  轮换证书
sb log [-f]                               查看或跟随日志
sb up [--check] [-v VERSION]              检查或更新内核
sb self-up [--check] [-f]                 检查或更新管理脚本
sb bak [FILE]                             导出备份
sb res <FILE> -y                          恢复备份
sb un [-p] -y                             卸载
```

完整帮助：

```sh
sb help
```

长命令同样可用：

```sh
sb add vless --port 443 --sni www.speedtest.net
sb update --check
sb self-update --check
```

### 添加协议选项

| 选项 | 说明 |
|---|---|
| `-p, --port` | 监听端口；省略时随机生成 |
| `-P, --password` | 密码或 PSK |
| `-s, --sni` | TLS / Reality SNI |
| `-c, --cert` | X.509 PEM 证书 |
| `-k, --key` | PEM 私钥 |
| `-u, --uuid` | VLESS UUID |
| `-i, --short-id` | Reality Short ID |
| `-m, --snell-mode` | Snell 模式 |
| `-f, --force` | 强制重建已有协议 |

重建已有协议必须添加 `-f`，且可能轮换密码、UUID 或 Reality 密钥：

```sh
sb a vl -p 443 -s www.speedtest.net -f
```

---

## 常用场景

### Hysteria2 使用受信任证书

```sh
sb a hy \
  -p 8443 \
  -s edge.example.com \
  -c /etc/letsencrypt/live/edge.example.com/fullchain.pem \
  -k /etc/letsencrypt/live/edge.example.com/privkey.pem
```

未指定证书时，Trojan、AnyTLS 和 Hysteria2 使用自动生成的自签名证书。

### 轮换证书，不改变协议凭据

```sh
sb cert hy \
  -s edge.example.com \
  -c /etc/letsencrypt/live/edge.example.com/fullchain.pem \
  -k /etc/letsencrypt/live/edge.example.com/privkey.pem
```

`cert` 支持 `tj`、`at`、`hy`。部署前验证证书/私钥格式、密钥匹配、至少 24 小时有效期及 SAN/SNI 匹配。

### 更新

```sh
# 内核
sb v
sb up --check
sb up
sb up -v v1.14.0-alpha.50

# 管理脚本
sb self-up --check
sb self-up
```

若 `sb` 尚未部署：

```sh
./install.sh self-up -f
```

内核更新校验 SHA-256 和候选配置；管理脚本更新固定到 Git 提交 SHA，并校验 `SHA256SUMS`、脚本标识、语法及可选 ShellCheck。

### 备份与恢复

```sh
sb bak /root/sing-box-backup.tar.gz
sb res /root/sing-box-backup.tar.gz -y
```

备份包含密码、UUID、配置和私钥，权限自动设为 `0600`。

备份输出目录必须由 root 所有且不可被组或其他用户写入；脚本拒绝符号链接、硬链接、已有目标，以及配置/数据/日志目录中的输出路径。

恢复时先复制归档到权限为 `0700` 的私有事务目录，再验证路径、类型、数量、体积和候选配置。中断恢复会在下次执行 `sb` 时自动回滚。

### 卸载

```sh
sb un -y      # 删除内核和服务，保留配置
sb un -p -y   # 彻底清除
```

彻底清除会删除内核、配置、证书、日志、`sb` 命令，以及脚本创建的服务用户和用户组。

---

## 安全设计

- 独立非 root 服务账户；
- 配置与证书仅 root 和服务组可读；
- 内核、配置、证书和恢复均有校验与回滚；
- 服务定义、logrotate、管理命令和备份采用原子写入；
- 备份防符号链接、硬链接、非可信目录和恢复 TOCTOU；
- 锁记录 PID 与进程启动时间，防 PID 重用误判；
- 启动时清理孤立事务目录；
- 证书内容寻址使用 128 位截断 SHA-256；
- 不使用 `curl | sh`。

## 排障与文件位置

```sh
sb c
sb l
sb log
sb log -f
ss -lntup
```

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/sing-box` | 内核 |
| `/usr/local/sbin/sb` | 管理命令 |
| `/etc/sing-box/config.d` | 配置 |
| `/etc/sing-box/state` | 私有状态 |
| `/etc/sing-box/tls` | 证书与私钥 |
| `/var/log/sing-box/sing-box.log` | 日志 |

服务状态：

```sh
# Alpine/OpenRC
rc-service sing-box status

# Debian/systemd
systemctl status sing-box
journalctl -u sing-box
```

## 完整性校验

```sh
curl -fLO https://raw.githubusercontent.com/fexumo/sing-box/main/SHA256SUMS
sha256sum -c SHA256SUMS
```

## 免责声明

请仅在有权管理的服务器和网络中使用。管理员需自行负责防火墙、证书续期、备份保管、系统更新和当地法律合规。
