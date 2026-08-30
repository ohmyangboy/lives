# Lives 自有更新源：服务器操作与客户端开发方案

日期：2026-08-30。状态：服务器补丁已在本地隔离验证，尚未部署；客户端已完成实现，尚未正式发布。

## 已确认范围

- 继续使用 `https://download.1leaf.cc/Lives-latest.dmg`，不新增版本目录或更新清单接口。
- 复用 `https://download.1leaf.cc/lives-download-stats.json`，保留所有下载统计字段和 README badge。
- 客户端优先使用自有源，GitHub 备用。第一版不做断点续传、多线程下载或并行探测安装包。
- 本次不修改 Nginx、DNS、代理、限速、PaperRss 或现有正式版/预发布版同步规则。
- 仅提供服务器操作包和开发方案，不提交、发布或执行远程部署。

## 服务器修改指令

### 1. 在 Mac 本机上传补丁

下面仅上传一个维护脚本，不上传应用源码。地址沿用用户提供的历史部署；若服务器地址已变更，应替换目的地址。

```bash
scp /Users/yangbukun/Desktop/code/swiftAPPs/lives/scripts/server/patch-lives-update-metadata.py \
  root@47.251.82.23:/root/patch-lives-update-metadata.py
```

### 2. 在服务器 root 终端先做只读检查

```bash
python3 /root/patch-lives-update-metadata.py
```

脚本自动查找 `/usr/local/sbin/lives-sync-release` 或 `/usr/local/sbin/sync-lives-release`，从实际文件确认 Lives 专用发布锁与预期 `flock` 使用方式，并检查统计脚本结构。仅当唯一匹配时继续。

如果不能唯一确认，用 `ls -l /usr/local/sbin/*lives*` 查看路径，再通过 `--sync-script /实际路径` 指定。下面应用命令也须传同一个参数。不要为了通过检查删除同步锁或绕过前置检查；结构不匹配时需要按现用脚本重新调整补丁。

### 3. 检查通过后应用并刷新统计

在服务器 root 终端整段执行。会暂时停止统计 timer/service，防止旧进程继续覆盖 JSON；不停止网站、下载服务或 Release 同步。执行结束恢复 timer 原有的运行状态。

```bash
bash <<'SH'
set -euo pipefail

python3 /root/patch-lives-update-metadata.py

LIVES_TIMER_WAS_ACTIVE=$(systemctl is-active lives-download-stats.timer || true)
restore_timer() {
  if [ "$LIVES_TIMER_WAS_ACTIVE" = active ]; then
    systemctl start lives-download-stats.timer
  fi
}
trap restore_timer EXIT

systemctl stop lives-download-stats.timer
systemctl stop lives-download-stats.service

python3 /root/patch-lives-update-metadata.py --apply
systemctl start lives-download-stats.service
journalctl -u lives-download-stats.service -n 15 --no-pager

python3 <<'PY'
import json
import re
from pathlib import Path

p = Path('/var/www/lives-download/lives-download-stats.json')
d = json.loads(p.read_text())
assert d['schemaVersion'] == 1
assert re.fullmatch(r'v?[0-9]+\.[0-9]+\.[0-9]+', d['currentVersion'])
assert d['downloadUrl'] == 'https://download.1leaf.cc/Lives-latest.dmg'
assert re.fullmatch(r'[0-9a-f]{64}', d['sha256'])
assert isinstance(d['size'], int) and d['size'] >= 1024 * 1024
assert all(k in d for k in ('downloads', 'githubDownloads', 'directDownloads'))
print(json.dumps(d, ensure_ascii=False, indent=2))
print('更新元数据字段检查通过。')
PY
SH
```

注意：补丁会在 `/root/lives-update-backups/` 创建带时间与随机后缀的备份目录，并打印回滚命令。如果统计遇到正在同步的发布锁，会安全跳过；此时首次字段检查可能失败，待同步结束后再执行 `systemctl start lives-download-stats.service`，不要重复应用补丁。

### 4. 验证公网返回

```bash
curl -fsS -H 'Cache-Control: no-cache' \
  https://download.1leaf.cc/lives-download-stats.json
```

返回应保留原有字段，并多出实际值：

| 字段 | 含义 |
| --- | --- |
| `schemaVersion` | 更新字段格式版本，当前为 `1` |
| `currentVersion` | 同步落盘的正式版本，允许 `v` 前缀 |
| `downloadUrl` | 固定 `Lives-latest.dmg` 地址 |
| `sha256` | 服务器当前 DMG 的 64 位十六进制 SHA-256 |
| `size` | DMG 字节数 |

不需要重载 Nginx。现有静态接口可以直接返回新增字段。缓存最长约 60 秒；现有统计任务每 5 分钟刷新，因此刚发布可能有约 5 分钟加缓存时间的可见延迟。这一版接受该延迟。

### 5. 回滚

若应用后统计异常，先暂停统计 timer/service，然后执行补丁打印的 `cp -p ...` 命令恢复统计脚本。如果需要立即恢复 JSON，也从同一备份目录复制 `lives-download-stats.json` 到同目录临时文件，再用 `mv` 替换公网文件，避免直接覆盖写入。恢复后启动统计 service，并仅在 timer 原来运行时恢复它。

不要删除 SQLite、salt、安装包或 `.version`。补丁不修改这些文件。重新运行旧版统计脚本会自动恢复旧 JSON 格式，README 的下载数仍保留。

## 补丁行为与边界

1. 默认只检查；`--apply` 才备份并原子替换统计脚本，保留原权限及所有者。
2. 统计任务与发布同步使用同一个 Lives 排他锁。整次统计持锁，避免在安装包与 `.version` 切换中途读取。定时/手工统计之间也互斥；锁忙则跳过本次。
3. 计算文件 SHA-256，每次分块读取 1 MiB；异常小文件、缺失文件、非法正式版号导致本次生成失败，保留旧 JSON。
4. 必须确保所有安装包写入都经过同一同步脚本及发布锁。不要手工覆盖正在服务的 DMG；现有同步应保留临时下载后 `mv` 的发布方式。
5. 锁只能防止生成时读到过渡状态。公网旧 JSON 仍可能遇到已替换的新 DMG，客户端必须处理这种版本切换窗口，不能无校验安装。
6. SHA-256 证明文件与清单一致，不等于开发者身份认证；不能代替客户端的代码签名身份验证。
7. 仍沿用统计脚本的 GitHub 下载数缓存机制。`githubStatus=cached` 只表示计数过期，不代表本地安装包不可用；首次无缓存且 GitHub 失败仍可能不能产出 JSON。
8. 本补丁不证明当前服务器实际部署与历史记录一致；前置检查若失败，应停止并检查，不强制覆盖。

## 客户端开发方案

### 阶段一：检测结果与自有源接入

涉及 `src/releaseUpdate.ts`、`src/nativeBridge.ts`、Swift `EntryPoint.swift` 及请求/响应模型；新增一个范围明确的原生更新元数据请求。

- 将 HTTP 元数据获取统一放到 Swift URLSession，按系统网络配置请求；不硬编码代理端口，不擅自直连绕过用户代理。
- 自有统计 JSON 为首选，验证 schema、正式版本号、HTTPS 地址、SHA-256 格式和正整数字节数。初版仅接受已配置的自有下载地址。
- 区分“合法清单且版本不新”“请求失败”“数据无效”“接口限流”；只有第一种可以显示已是最新版。旧格式缺失哈希视为未就绪，不跳过校验。
- 自有源网络失败或无效时，尝试 GitHub 稳定版接口。有效的自有清单即为发布依据，不为每次成功检测额外查询 GitHub。
- 保留清单来源、版本和摘要作为同一更新候选，不能把自有源版本与 GitHub 另一版本的哈希混用。
- 初始请求预算：每源约 6 秒，总检测上限约 15 秒，待实测调整；协调器看门狗须覆盖整个回退流程，取消要实际终止网络任务。
- 429/403 保留状态和重试信息；尊重 `Retry-After`，超过交互等待预算时返回可重试状态，不阻塞界面等待。

### 阶段二：可靠下载、校验与回退

涉及 Swift `UpdateService.swift`、桥接进度模型、协调器与对应测试。

- 使用 URLSession 下载任务与代理回调替代逐字节循环，按收到数据的时间更新进度心跳和停滞计时；空闲约 60 秒失败，UI 看门狗稍晚兜底。
- 第一版从头下载；不发送 Range，不拼接之前的临时文件。保留服务端限流保护，单用户一次只下载一个安装包。
- 下载前冻结候选版本、摘要、大小；下载完成先校验实际大小和 SHA-256，再暂存安装包。
- 自有源失败时，GitHub 备用包必须匹配同一个版本和摘要；若只能获得另一个版本，则重新形成完整候选，不复用旧元数据。
- `latest.dmg` 校验不匹配时重新请求清单，最多自动重试一次。清单未变化或再次失败则显示“更新源正在同步或校验失败”，保留手动重试入口，不无限重下、不跳过校验。
- 总自动下载尝试设上限（建议不超过 3 次，含切源及元数据刷新后的重试），避免失败组合产生循环。
- 只在用户确认更新/已有自动更新策略触发时下载，不通过安装包 GET 探测可用性，避免额外统计下载次数。

### 阶段三：安装前身份检查

- 暂存 App 的 Bundle ID、版本和架构必须匹配候选与当前产品。
- 验证有效代码签名及预期 Developer ID/Team ID，不能只检查“有签名”。身份依据来自已验证的正式发行配置，开发模式不得静默跳过生产验证。
- 当前已下载暂存恢复和重启安装路径也执行验证，不能仅首次下载时验证。
- 失败不替换运行中的 App，保留可读错误并清理不可信临时包；沿用现有安装回滚逻辑。
- 独立清单签名以后如需加入，必须配套密钥管理；本阶段不得将 SHA-256 宣称为清单签名。

### 阶段四：界面与测试

- 保留现有更新入口、状态机和操作方式；明确区分检测失败、下载失败、正在同步及已是最新版。
- 静默检查失败保持安静，手动检查失败显示原因及重试；切源时只提示必要的状态。
- 最低自动化覆盖：403/429 不误报最新版；自有源成功不访问 GitHub；主源失败回退；旧版/同版/预发布比较；缺失或错误哈希；版本切换窗口；取消与停滞；签名、版本不匹配不得安装。
- 验证使用真实生产解析/协调接口，不以复制算法的测试代替调用链测试。
- 真机矩阵：用户当前 VPN、用户自行关闭 VPN、慢速/断网、自有源失败、旧客户端手工升级引导、已下载恢复。完成一次正式签名测试包到新版的安装重启闭环；不以构建或单测代替 UI 与网络证据。

## 发布顺序与验收门槛

1. 用户先应用服务器补丁，确认公网 JSON 有新增字段；当前旧客户端不受新增字段影响。
2. 按方案开发新客户端并本地验证，提供本地测试包，不自动发布。
3. 获得正式发布授权后再发布支持自有源的版本。旧客户端仍只用 GitHub 检测，遇到限流的用户首次可能需要手动从自有源升级。
4. 正式发布后验证自有源同步、统计 JSON、实际包版本/摘要和应用内升级闭环。
5. 只有大陆不同网络实测改善，才能宣称下载速度优化完成；自有服务器不等于大陆 CDN。现有限速与服务器线路暂不改。

## 本次本地验证记录

隔离目录中使用历史对话里的实际统计脚本验证，替换了所有服务器路径及 GitHub 计数请求，没有执行远程命令：

- 新字段的 SHA-256、大小、版本正确，原统计字段保留。
- 发布锁被占用时跳过，JSON 不变。
- 损坏/异常小安装包、非正式版本时失败，旧 JSON 保留。
- 不匹配脚本拒绝补丁。
- 默认检查不修改；应用后备份原文、保留权限；重复补丁被拒绝。
- 生成的统计代码通过 Python 3.6 语法解析检查；未在服务器真实 Python/Nginx/systemd 环境执行。

客户端实现已完成并保留在当前工作树：自有源优先检测、GitHub 限流/失败回退、候选大小与 SHA-256 校验、URLSession 下载任务、取消与停滞保护、暂存清单恢复及 Bundle ID/版本/arm64/Developer ID Team 校验均已接入。前端测试 63 项、Swift 全量测试 28 项（3 项按环境跳过）和生产构建通过；本地测试 DMG 已生成，但尚未上传或发布。VPN 下、关闭 VPN 后直连、断网/慢网和完整安装重启仍需在真实用户环境验收。
