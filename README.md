# deploy-proxy.sh 一键部署说明

在一台**全新的 Ubuntu / Debian VPS**（root、systemd）上一键部署：

- **主力**：Xray `VLESS + Reality + Vision`（TCP，优先 443，被占用则 8443）
- **备用**：Hysteria2（UDP，随机高位端口 + 端口跳跃 20000-50000，自签证书 + 证书指纹锁定）
- **系统优化**：BBR + fq，UDP/TCP 缓冲上限 16MB

## 一行用法

把脚本传到服务器后：

```bash
bash deploy-proxy.sh
```

如果把脚本放在自己的网址（例如 GitHub 私有 Gist / 自己的服务器）：

```bash
curl -fsSL https://你的网址/deploy-proxy.sh -o deploy-proxy.sh && bash deploy-proxy.sh
```

结束时终端会打印分享链接和二维码，同时写入：

- `/root/proxy-client/links.txt`：vless:// 和 hysteria2://（单端口 / 跳跃逗号写法 / mport 写法）
- `/root/proxy-client/clash-meta.yaml`：mihomo / Clash Meta 配置（select + url-test + fallback 分组）
- `/root/proxy-client/qr/*.png`：二维码图片

## 其他命令

| 命令 | 作用 |
|---|---|
| `bash deploy-proxy.sh` | 安装；重复运行会**沿用已有密码 / UUID / 端口**（不会重复加规则，客户端不用改） |
| `bash deploy-proxy.sh --show` | 只重新打印链接和二维码 |
| `bash deploy-proxy.sh --uninstall` | 卸载脚本装的所有东西（Xray、Hysteria2、端口跳跃、BBR 配置、状态文件）；加 `KEEP_BBR=1` 保留 BBR |

## 可选环境变量

```bash
NODE_NAME=SG1 HY2_PORT=40443 REALITY_PORT=443 bash deploy-proxy.sh
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `NODE_NAME` | 主机名 | 链接里的节点名前缀 |
| `SERVER_ADDR` | 自动检测公网 IPv4 | 链接里写的地址（可填域名） |
| `HY2_PASSWORD` | 随机 20 位 | Hysteria2 密码（想沿用旧客户端时指定原密码） |
| `HY2_PORT` | 随机 50001-65000 | Hysteria2 UDP 端口 |
| `HOP_RANGE` | `20000-50000` | 端口跳跃范围；`NO_HOP=1` 关闭跳跃 |
| `REALITY_PORT` | 443（被占用则 8443） | Reality TCP 端口 |
| `REALITY_SNI` | 自动挑选 | 伪装站点。默认在 dl.google.com / www.amazon.com / www.microsoft.com / www.apple.com 中测速，并**实际跑通一次 Reality 才采用**；apple 排最后（Xray 官方提示 apple/icloud 容易被标记） |

## 注意

1. **云厂商防火墙 / 安全组**要自己放行：Reality 的 TCP 端口、Hysteria2 的 UDP 端口、UDP 跳跃范围。脚本只在 ufw 已启用时自动放行，否则不碰本机防火墙。
2. Hysteria2 是自签证书，客户端用 `insecure=1 + pinSHA256`（证书指纹锁定）。指纹不对会拒绝连接，安全性有保证。
3. 端口跳跃靠 `hy2-porthop.service`（iptables/ip6tables 的 nat 表 HY2_PORTHOP 链），开机自动生效，和 docker 规则互不干扰。
4. 如果 443 已经被网站（nginx 等）占用，Reality 会用 8443。非 443 端口相对更容易被识别，日后可以让 nginx 按 SNI 分流再挪到 443。
5. 凭据保存在 `/etc/proxy-deploy/state.env`（仅 root 可读）。`/root/proxy-client/` 里的文件都含密钥，**不要外传**。
