# ACME DNS 验证配置指南

## 问题解决

您遇到的 DNS 验证失败是因为 Cloudflare API 密钥没有正确加载。

## 快速解决方案

### 1. 修复当前权限问题

```bash
sudo bash acme-fix-dns.sh
```

### 2. 重新配置 DNS API（推荐）

```bash
sudo bash acme-dns-setup.sh
```

这个脚本会引导您配置各种 DNS 提供商的 API 密钥，包括：
- Cloudflare
- 阿里云 DNS
- 腾讯云 DNS
- DNSPod
- 华为云 DNS
- AWS Route53

### 3. 重新申请证书

```bash
sudo acme-add biubiuniu.com dns
```

## 手动配置方法

如果您想手动配置 Cloudflare API：

1. **修复权限**：
   ```bash
   sudo chmod 644 /etc/acme/dns-config
   ```

2. **验证配置文件内容**：
   ```bash
   sudo cat /etc/acme/dns-config
   ```
   
   应该包含：
   ```bash
   export CF_Token="TDSYt1qY66F3HT8W7X-l0IYDOdke4eQgnvTLUjNZ"
   export CF_Account_ID="08982882ca1428a8a058cc8d21fc1e00"
   ```

3. **测试配置**：
   ```bash
   source /etc/acme/dns-config
   echo $CF_Token
   ```

## 获取 Cloudflare API Token

1. 访问：https://dash.cloudflare.com/profile/api-tokens
2. 点击 "Create Token"
3. 使用 "Custom token" 模板
4. 权限设置：
   - Zone:Zone:Read
   - Zone:DNS:Edit
5. Zone Resources: Include All zones
6. 复制生成的 Token

## DNS 验证的优势

- 支持泛域名证书 (`*.example.com`)
- 不需要 Web 服务器运行
- 可以为内网域名申请证书
- 续期时更稳定

## 支持的域名示例

```bash
# 单个域名
sudo acme-add example.com dns

# 多个域名
sudo acme-add example.com www.example.com dns

# 泛域名
sudo acme-add example.com '*.example.com' dns

# 多级泛域名
sudo acme-add '*.example.com' '*.api.example.com' dns
```

## 故障排查

如果仍然失败：

1. **检查 API Token 权限**：确保 Token 有正确的区域和 DNS 权限
2. **检查域名解析**：确保域名使用 Cloudflare DNS
3. **查看详细日志**：`sudo tail -f /var/lib/acme/config/issue-biubiuniu.com.log`
4. **验证网络连接**：确保服务器可以访问 Cloudflare API

## 其他 DNS 提供商

如果不使用 Cloudflare，可以配置其他提供商：

- **阿里云**：需要 AccessKey ID 和 Secret
- **腾讯云**：需要 SecretId 和 SecretKey
- **DNSPod**：需要 Token ID 和 Token
- **AWS Route53**：需要 Access Key 和 Secret Key

运行 `sudo bash acme-dns-setup.sh` 获取详细的配置步骤。
