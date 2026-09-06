# 小马达能量营 · 账号与订阅服务端

轻量自建后端：邮箱注册/登录 + 激活码开通会员。纯 Dart 实现，仅需 Dart SDK（无其他依赖），
可部署到任何 VPS / 云主机。

## 数据边界（与 App 隐私承诺一致）

服务器只存三样东西：**邮箱、密码哈希（PBKDF2-HMAC-SHA256，5 万次迭代 + 随机盐）、会员到期时间**。
儿童的测评/训练/打卡数据永远只存在用户手机里，不经过本服务。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /health | 健康检查 |
| POST | /auth/register | `{email, password}` → `{token, email, vipExpire}` |
| POST | /auth/login | `{email, password}` → `{token, email, vipExpire}` |
| GET | /me | Header `Authorization: Bearer <token>` → `{email, vipExpire}` |
| POST | /sub/redeem | `{code}` → 激活会员，续费叠加时长 |

令牌为 HMAC 签名的 30 天有效凭证；登录/注册按 IP 限速（连错 10 次锁 10 分钟）。

## 本地运行

```bash
cd server
dart pub get
dart run bin/server.dart 8080
# 另开终端测试：
curl http://127.0.0.1:8080/health
```

## 生成激活码（真实订阅的开卡方式）

```bash
dart run bin/admin.dart gen month 10      # 生成 10 张月卡
dart run bin/admin.dart gen year 5        # 生成 5 张年卡
dart run bin/admin.dart list              # 查看账号与码的使用情况
```

运营流程：用户付款（微信/支付宝收款码，由你线下完成）→ 你把激活码发给用户 →
用户在 App「我的 → 我的账号」输入激活码 → 服务端写入会员到期时间 → 该账号所有设备即时生效。
续费叠加时长（未到期就续，时长累加）。

## 正式部署（任选其一）

- **VPS（推荐）**：装 Dart SDK → 拷贝 server/ 目录 → `nohup dart run bin/server.dart 8080 &`
  → Nginx 反代 + Let's Encrypt 免费证书（务必 HTTPS）→ 域名如 `api.你的域名.com`；
- **Docker 云**（fly.io/railway 等）：Dart 官方镜像 `dart:stable`，启动命令同上；
- 定期备份 `server/data/` 目录（accounts.json + codes.json + secret.key）。

## App 端指向服务器

构建 App 时注入地址（替换为你的域名）：

```bash
flutter build apk --release --dart-define=XMD_API_BASE=https://api.你的域名.com ...
```

不注入时 App 使用 `lib/config.dart` 中的默认值（开发指向本机 10.0.2.2:8080）。

## 已知边界（诚实声明）

- 邮箱验证/找回密码：当前版本未接邮件服务（需要 SMTP 发件账号）。找回密码的兜底方案：
  用户用注册邮箱联系客服，管理员核实后用 `admin.dart` 重置（后续可加 reset 命令）或删号重注册；
- 支付本身：激活码模式需要你线下收款后发码；接入 App Store / Google Play 官方内购后，
  由 IAP 回调自动写 `vipExpire`（App 内 `InAppPurchaseAdapter` 接口已预留）；
- JSON 文件存储适合当前规模（数千账号）；账号量大后换 SQLite/Postgres，接口不变。
