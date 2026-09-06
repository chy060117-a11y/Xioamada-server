# 账号服务部署指南（三选一，从免费到专业）

> 部署完成后你会得到一个公网地址（如 https://api.你的域名.com），
> 把它填入 App 构建命令即可让所有用户正常注册登录。

## 方案一：Railway（免费额度，最简单，5 分钟）

1. 注册 railway.app（GitHub 账号登录）
2. New Project → Deploy from GitHub repo（先把 server/ 目录推到 GitHub）
3. Railway 自动识别 Dart 项目并部署
4. Settings → Networking → Generate Domain → 得到公网 URL
5. 数据自动持久化（挂载 /app/data 卷）

## 方案二：Fly.io（免费额度，全球节点）

```bash
# 安装 flyctl 后：
cd server
fly launch --no-deploy        # 创建应用
fly volumes create data --size 1
fly deploy                    # 部署
fly status                    # 查看公网地址
```

## 方案三：国内 VPS（推荐正式运营，¥30-60/月）

推荐阿里云/腾讯云轻量服务器（最低配即可，选离你用户近的地域）：

```bash
# 1. 装 Dart SDK
ssh root@你的VPS
curl -fsSL https://dart.dev/get-dart | sh

# 2. 上传 server 目录（scp 或 git clone）
scp -r server/ root@你的VPS:/opt/xiaomada/

# 3. 启动（nohup 后台运行）
cd /opt/xiaomada/server/bin
nohup dart server.dart 8080 &

# 4. Nginx 反代 + HTTPS（Let's Encrypt 免费证书）
# Nginx 配置：
# location / { proxy_pass http://127.0.0.1:8080; }
```

## 部署后必做

1. **HTTPS**：商店上架要求 + 密码传输安全，用 Let's Encrypt 免费证书
2. **备份**：定期备份 data/ 目录（accounts.json + codes.json + secret.key）
3. **构建 App**：
   ```bash
   flutter build apk --release \
     --dart-define=XMD_API_BASE=https://api.你的域名.com \
     --split-per-abi --obfuscate --split-debug-info=build/symbols
   ```

## Docker 部署（任选）

server/Dockerfile 已备好：
```bash
cd server
docker build -t xiaomada-server .
docker run -d -p 8080:8080 -v $(pwd)/data:/app/data xiaomada-server
```
