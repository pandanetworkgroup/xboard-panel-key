# Xboard 面板侧证书指纹（Cert Fingerprint）部署指南

本仓库为 [Xboard](https://github.com/cedar2025/Xboard) 面板提供**证书固定（Certificate Pinning）**补丁，覆盖 8 类主流客户端订阅格式。

> 配套 Node 侧补丁仓库：<https://github.com/pandanetworkgroup/xboard-node-key>

---

## 1. 功能说明

使用自签 TLS 证书的节点（hysteria2 / tuic / anytls / vless+TLS / trojan+TLS / vmess+TLS）默认向所有客户端下发 `insecure: true` / `allow_insecure: true`，关闭了证书验证，存在中间人攻击（MITM）风险。

本补丁让面板改为下发**证书指纹固定**：

| 客户端 | 证书固定字段 |
| --- | --- |
| sing-box | `certificate` + `certificate_public_key_sha256` |
| Clash Meta / Stash | `fingerprint` + `skip-cert-verify:false` |
| Surge / Surfboard | `server-cert-fingerprint-sha256` |
| v2rayN | `v2rayn://` JSON 的 `CertSha` + `Cert` |
| v2rayNG / general / passwall / ssrplus / sagernet | URI `pcs` / `pinSHA256` 参数 |
| Clash 原版 | 内联 `ca-pem` + `skip-cert-verify:false` |

8 个补丁文件覆盖 Xboard 自带的所有订阅路由。

---

## 2. 工作原理

```
Node 端 (xboard-node 带改动二进制)
   ├── 启动时读取 /etc/xboard-node/instances/<id>/<node>/certs/cert.pem
   ├── 计算 cert_fingerprint = SHA-256(SPKI DER, Base64)
   ├── 读取 cert_pem = 完整 PEM 证书
   └── WebSocket 上报 → 面板 DB v2_server.cert_fingerprint + cert_pem

面板端 (PHP 补丁)
   ├── ServerService.php: getAvailableServers() 返回含 cert 字段
   ├── 各 Protocol 文件: 读取 cert_pem → computeCertSha256()
   │   (SHA-256 of full cert DER, uppercase hex no colon)
   └── 按客户端 UA 注入对应格式的证书固定参数
```

### 两种 SHA-256 算法

| 名称 | 输入 | 输出格式 | 用途 |
| --- | --- | --- | --- |
| `cert_fingerprint` | SPKI DER | Base64 (44 字符) | DB 存储；Surge/Surfboard/ClashMeta 字段 |
| `CertSha` / `computeCertSha256` | Full cert DER | 大写 hex 无冒号 (64 字符) | v2rayN 的 `CertSha`；v2rayNG 的 `pcs`/`pinSHA256` |

### UA 分流策略（General.php）

| UA 关键词 | 分流逻辑 |
| --- | --- |
| `v2rayn`（不含 `v2rayng`） | v2rayn:// 格式：JSON 含 `CertSha` + `Cert` PEM |
| `v2rayng` / `general` / `passwall` / `ssrplus` / `sagernet` | 标准 URI + `pcs` / `pinSHA256` 参数 |

---

## 3. 前置条件

脚本在**面板服务器本机**执行（运行 Xboard docker 容器的那台机器），要求：

- `root`（或 `sudo`）权限
- `docker` CLI 可用
- Xboard 容器正在运行（默认名 `xboard-xboard-1`，可用 `--container` 覆盖）
- 能访问 `raw.githubusercontent.com` / `api.github.com`（或用 `--bundle` 离线部署）

**部署前请确认 Node 侧补丁已先部署到所有上报 cert 的节点。** 否则面板 DB 没有 `cert_fingerprint` / `cert_pem` 字段，订阅仍然输出 `insecure: true`。

> Node 侧补丁：<https://github.com/pandanetworkgroup/xboard-node-key>

---

## 4. 快速部署

### 4.1 一行命令部署（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh \
  | sudo bash -s -
```

脚本会自动完成：

1. 从 GitHub Release 下载 `cert-deploy-bundle.tar.gz`
2. 把容器内当前 8 个 PHP 文件备份到 `/root/php_pre_cert_deploy/`（仅当该目录为空时；已存在则跳过以保护初始备份）
3. 将 8 个补丁版 PHP 文件 `docker cp` 进容器 `/www/app/...`
4. 容器内 `sed` 防御性剥除 UTF-8 BOM（幂等）
5. 对 8 个文件逐个执行 `php -l` 语法检查；任一失败**自动回滚**后退出
6. `docker exec ... php /www/artisan optimize:clear` 清 Laravel 缓存
7. `docker restart <容器>` 重启容器使新字节码生效（OPcache 必须重启才更新）
8. 对 `http://127.0.0.1/` 和 `http://127.0.0.1:7001/` 做健康自检
9. 打印 60-90 秒后的 DB 验证命令

### 4.2 交互式部署（先下载再跑）

```bash
curl -fsSL https://raw.githubusercontent.com/pandanetworkgroup/xboard-panel-key/main/install-panel.sh -o install-panel.sh
sudo bash install-panel.sh
sudo bash install-panel.sh --help
```

### 4.3 离线部署（无外网环境）

把 `install-panel.sh` 和 `cert-deploy-bundle.tar.gz` 都拷到面板服务器，然后：

```bash
sudo bash install-panel.sh --bundle ./cert-deploy-bundle.tar.gz
```

### 4.4 非默认容器名

```bash
sudo bash install-panel.sh --container my-xboard-1
```

---

## 5. 回滚

### 5.1 默认回滚（同时清空 DB cert 字段）

恢复原始 8 个 PHP 文件，**并** 把 `v2_server` 表的 `cert_fingerprint` / `cert_pem` 字段置 NULL。客户端下次拉订阅会立刻回退到 `insecure: true`。

```bash
sudo bash install-panel.sh --rollback
```

### 5.2 软回滚（保留 DB cert 字段）

只恢复 PHP 文件，DB 字段保留不动。适合只想回退代码、保留 cert 数据供查看的场景。

```bash
sudo bash install-panel.sh --rollback --keep-db
```

> 若 `/root/php_pre_cert_deploy/` 不存在或里面没有可用 PHP 文件（扁平 / 嵌套布局都行），回滚会拒绝执行。

---

## 6. CLI 参数

```
Xboard panel-side cert-fingerprint installer (deploy / rollback)

Args:
  --rollback               回滚到部署前备份（默认同时清空 DB cert 字段）
  --keep-db                仅回滚 PHP 文件，保留 DB cert 字段
  --container NAME         Xboard docker 容器名（默认 xboard-xboard-1）
  --backup-dir DIR         宿主机备份目录（默认 /root/php_pre_cert_deploy）
  --work-dir DIR           宿主机解包工作目录（默认 /root/cert-deploy-work）
  --health-url URL         健康检查 URL（可重复；默认 http://127.0.0.1/ , http://127.0.0.1:7001/）
  --bundle PATH            使用本地 tar.gz 包（跳过 GitHub 下载）
  --release-tag TAG        指定 GitHub Release tag（默认 latest）
  --force-rebackup         强制重新取备份（即使已有也覆盖）
  --skip-selftest          跳过最后的 HTTP 自检
  -h, --help               显示帮助
```

---

## 7. 部署后验证

等待 60-90 秒（让 Node 通过 WebSocket 重新上报 cert），然后查 DB：

```bash
# 统计 DB 里多少 server 有 cert_fingerprint
docker exec xboard-xboard-1 php /www/artisan tinker --execute \
  'use App\Models\Server; echo "with-cert: " . Server::whereNotNull("cert_fingerprint")->count() . " / total: " . Server::count() . "\n";'
```

再用各客户端的 UA 拉订阅，grep 证书固定字段：

```bash
# sing-box: 应该出现 certificate_public_key_sha256
curl -fsSL -A 'sing-box/1.8' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep certificate_public_key_sha256

# Clash Meta: 应该出现 fingerprint: 和 skip-cert-verify:false
curl -fsSL -A 'clash.meta' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep -E 'fingerprint:|skip-cert-verify'

# Surge: 应该出现 server-cert-fingerprint-sha256
curl -fsSL -A 'Surge/4' 'https://your-panel-domain.com/api/v1/client/subscribe?token=YOUR_TOKEN' | grep server-cert-fingerprint-sha256
```

---

## 8. 运维注意事项

### 8.1 UTF-8 BOM

Windows 编辑过的 PHP 文件常带 UTF-8 BOM（`EF BB BF`）。PHP 会报 `Fatal error: Namespace declaration statement has to be the very first statement`。本仓库发布的 tar.gz 已剥除 BOM，脚本在 `docker cp` 之后还会**幂等地**再剥一次作为防御，对无 BOM 文件无害。

### 8.2 OPcache

`php -l` 和 `artisan optimize:clear` **不会**清 OPcache。脚本总是 `docker restart` 容器让新字节码生效，不要跳过这一步。

### 8.3 php -l 失败自动回滚

脚本在 8 个文件全部 `docker cp` 进容器后立即逐个 `php -l`。任一文件语法错误，脚本**自动从 `$BACKUP_DIR` 恢复全部 8 个文件**，清缓存、退出码非 0。容器回到部署前状态。

### 8.4 备份保留策略

首次成功部署会在 `/root/php_pre_cert_deploy/` 写入扁平布局的 8 个文件。后续部署**保留**这份备份不动，确保随时能回到**初始**状态（不是中间状态）。需要覆盖时传 `--force-rebackup`——仅当你确认"初始版"本身确实是要回滚到的目标时才用。

### 8.5 兼容手动 docker cp 备份

如果之前手动 `docker cp xboard:/www/app/Protocols/ /root/php_pre_cert_deploy/` 创建了**嵌套布局**（`Protocols/Clash.php` 这种），脚本同样能识别。回滚时优先扁平，找不到则查 `Protocols/` 和 `Services/` 子目录。

---

## 9. 8 个 PHP 文件改动明细

### 9.1 文件清单

| 文件 | 改动量 | 核心改动 |
| --- | --- | --- |
| `Protocols/General.php` | +20 KB | 新增 `shouldUseV2rayNFormat()` / `computeCertSha256()` / `buildV2rayNFormat()` 三个方法；8 种 `buildXxx` 方法注入 cert；修复 tuic v2rayn 格式中 Username 缺失问题；v2rayNG `pcs` / `pinSHA256` 注入；buildTuic 非 v2rayn 分支补 cert pinning |
| `Protocols/SingBox.php` | +960 B | 新增 `applyCertFingerprint()` 方法；7 处调用注入 `certificate` + `certificate_public_key_sha256` |
| `Protocols/ClashMeta.php` | +852 B | 新增 `applyCertFingerprint()` + `computeCertSha256()`；8 处调用注入 `fingerprint` + `skip-cert-verify:false` |
| `Protocols/Stash.php` | +624 B | 同 ClashMeta |
| `Protocols/Clash.php` | +357 B | 4 处内联 `ca-pem` + `skip-cert-verify:false` |
| `Protocols/Surge.php` | +357 B | 新增 `computeCertSha256()`；6 处调用注入 `server-cert-fingerprint-sha256` |
| `Protocols/Surfboard.php` | +257 B | 同 Surge，3 处调用 |
| `Services/ServerService.php` | +1130 B | `getAvailableServers()` 返回 `cert_fingerprint` + `cert_pem`；`ServerService` 持久化（仅在值变化时写库，避免每次 WebSocket 上报都触发 UPDATE） |

### 9.2 General.php 关键设计

**v2rayn:// JSON 字段顺序**：
```
ConfigType → ConfigVersion(4) → Remarks → Address → Port → Password
          → [Username] → [Network] → StreamSecurity("tls") → AllowInsecure("false")
          → Sni → [Alpn] → [Fingerprint] → [AlterId]
          → CertSha → [Cert] → [ProtoExtraObj] → [TransportExtraObj]
```

**tuic Username 修复**：v2rayn:// tuic JSON 中 `Username = $password`（与 `Password` 同值），修复 tuic v5 UUID 缺失导致的握手失败。

**anytls/tuic Cert PEM 双保险**：sing-box 路径的协议同时下发 `CertSha` + `Cert PEM`。sing-box 内核忽略 `CertSha` 只读 `Cert`；Xray 内核忽略 `Cert` 只读 `CertSha`。

**v2rayNG pcs 注入**：
- vless / trojan / vmess：`$config['pcs']` / `$array['pcs']`
- hysteria2：`$params['pinSHA256']`
- tuic：`$queryParams['pinSHA256']`

### 9.3 buildTuic cert pinning 修复（后续补丁）

**问题**：原版 `buildTuic` 非 v2rayn 格式分支（v2rayNG / sing-box 等客户端的 `tuic://` 标准输出）只有 `insecure=1`，没有 cert pinning 注入逻辑。

**修复前后对比**：

```php
// 修复前
if (data_get($protocol_settings, 'tls.allow_insecure')) {
    $queryParams['insecure'] = '1';
}

// 修复后
if (!$useV2rayNFormat && data_get($server, 'cert_pem')) {
    $certSha = self::computeCertSha256(data_get($server, 'cert_pem'));
    if ($certSha) {
        $queryParams['pinSHA256'] = $certSha;
        $queryParams['insecure'] = '0';
    } elseif (data_get($protocol_settings, 'tls.allow_insecure')) {
        $queryParams['insecure'] = '1';
    }
} elseif (data_get($protocol_settings, 'tls.allow_insecure')) {
    $queryParams['insecure'] = '1';
}
```

**验证**：
- 修复前：`tuic://...?sni=...&insecure=1#...`
- 修复后：`tuic://...?sni=...&pinSHA256=7565118EFDDD7411...&insecure=0#...`

---

## 10. 已知限制

### 10.1 tuic pinSHA256 客户端兼容性

tuic 的 `pinSHA256` 客户端支持有限：sing-box tuic outbound 原生只认 `certificate` (PEM)，不读 `pinSHA256`。若实测 v2rayNG / sing-box 因 `insecure=0` + 自签验证失败而连不上，可回退为 `insecure=1` 或改用 `certificate` PEM 方案。

### 10.2 Reality vless 的 insecure

Reality 协议本身不需要 cert pinning。如果某节点 `protocol_settings.tls_settings.allow_insecure=true`，sing-box 订阅会输出 `insecure:true`——这是配置问题，不是 cert 补丁问题。建议把 Reality 节点的 `allow_insecure` 改为 `false`。

### 10.3 CDN 节点

走 CDN 的 vless 节点（Cloudflare / 其他）没有可固定的源站证书。这类节点仍然输出 `insecure: true` 是预期的，不要回滚整个部署来"解决"它。

---

## 11. 与 Node 侧补丁配合

面板订阅只在 DB 有 `cert_fingerprint` + `cert_pem` 时才注入 cert pinning 字段。这两个字段由 **Node 侧补丁二进制** 通过 WebSocket 上报。

部署顺序：

1. **先**部署 Node 侧补丁到所有节点：<https://github.com/pandanetworkgroup/xboard-node-key>
2. **再**部署本面板侧补丁
3. 等 60-90 秒让 Node WebSocket 上报 cert
4. 验证 DB 字段已填充
5. 用各客户端 UA 拉订阅验证 cert pinning 字段

回滚顺序反过来：先回滚面板侧（让订阅不再要求 cert），再回滚 Node 侧（停止上报 cert）。

---

## 12. 仓库资产

| 资产 | 路径 | 说明 |
| --- | --- | --- |
| 主脚本 | `install-panel.sh` | 部署 + 回滚一体化脚本（纯 ASCII，bash） |
| 英文说明 | `README.md` | 英文版使用指南 |
| 中文指南 | `GUIDE.zh-CN.md` | 本文件 |
| 离线包 | Release `cert-deploy-bundle.tar.gz` | 8 个补丁 PHP 文件，BOM 已剥，POSIX 路径 |

### Release 包内容

```
Protocols/Clash.php
Protocols/ClashMeta.php
Protocols/General.php
Protocols/SingBox.php
Protocols/Stash.php
Protocols/Surfboard.php
Protocols/Surge.php
Services/ServerService.php
```

---

## 13. License

同上游 Xboard 项目。详见 Xboard 仓库。
