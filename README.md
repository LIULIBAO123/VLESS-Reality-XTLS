# VLESS + Reality + XTLS Vision 一键部署脚本

适用于 **Ubuntu / Debian** 的 Xray-core 一键部署脚本，自动搭建 `VLESS + Reality + XTLS Vision` 节点，无需域名、无需证书。

## 特性

- 自动安装 Xray-core（官方安装脚本）
- 自动生成 UUID、X25519 密钥对、Short ID
- 可选 Reality 伪装目标（微软 / 苹果 / iCloud / 三星 / 自定义）
- 可选监听端口（默认 `443`）
- 自动启用 **BBR** 拥塞控制
- 内核网络参数优化（TCP Fast Open、缓冲区扩大、MTU 探测等）
- 自动配置防火墙（UFW / firewalld）
- 输出可直接导入客户端的分享链接
- 客户端信息保存至 `/usr/local/etc/xray/client-info.txt`

## 使用方法

```bash
# 下载脚本
wget -O deploy-vless-reality.sh https://raw.githubusercontent.com/LIULIBAO123/VLESS-Reality-XTLS/main/deploy-vless-reality.sh

# 赋予权限并运行
chmod +x deploy-vless-reality.sh
sudo bash deploy-vless-reality.sh
```

按提示选择伪装目标和端口，部署完成后会输出 `vless://` 分享链接。

## 客户端

将输出的 `vless://` 链接粘贴导入以下任一客户端即可，参数会自动填充：

- [v2rayN](https://github.com/2dust/v2rayN)（Windows）
- [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)（Android）
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)（跨平台）
- [Hiddify](https://github.com/hiddify/hiddify-next)（跨平台）

## 管理命令

```bash
systemctl status xray      # 查看状态
systemctl restart xray     # 重启
journalctl -u xray -f      # 实时日志
```

配置文件位置：`/usr/local/etc/xray/config.json`

## 解锁 AI 服务（ChatGPT / Claude 等）

服务端无需额外配置，能否解锁主要取决于 **服务器 IP 质量**：

- 住宅 IP / 原生 IP：通常可直接解锁
- 数据中心 IP（常见 VPS）：大概率被风控，建议在服务器上叠加 Cloudflare WARP 出口

## 香港中转加速（relay-gost-hk.sh）

当落地机（如台湾节点）线路较差、晚高峰拥堵时，可用一台**优质线路的香港机做中转**，在保留落地机出口 IP（AI 解锁不受影响）的同时改善速度。

```
客户端 → 香港中转机(gost 转发) → 台湾落地机(出口) → 目标
```

出口仍是落地机，目标网站（含 Cursor/ChatGPT）识别到的是**落地机 IP**，不是香港。

**在香港机上运行：**

```bash
wget -O relay-gost-hk.sh https://raw.githubusercontent.com/LIULIBAO123/VLESS-Reality-XTLS/main/relay-gost-hk.sh
chmod +x relay-gost-hk.sh
sudo bash relay-gost-hk.sh
```

按提示输入落地机 IP、端口即可。脚本会用 gost 做 TCP/UDP 透明转发并注册为 systemd 服务（`gost-relay`）。

**客户端改动：** 复制原落地节点，只把 `地址` 从落地机 IP 改成香港机 IP，端口改成香港监听端口；`UUID / 公钥 / shortId / SNI / flow` **全部不变**（SNI 仍填落地节点原伪装域名）。

> ⚠️ 方向不能反：落地机必须是最后一跳（出口），香港只做中转。

## 说明

本脚本仅供学习与合法网络调试用途，请遵守所在国家/地区的法律法规。
