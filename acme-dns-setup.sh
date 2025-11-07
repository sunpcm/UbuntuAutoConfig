#!/bin/bash

set -euo pipefail

# ============================================================================
# ACME DNS 配置助手脚本
# 功能：帮助配置各种 DNS 提供商的 API 密钥
# 用法：sudo bash acme-dns-setup.sh
# ============================================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# 检查是否 root
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本必须以 root 身份运行"
    exit 1
fi

log_info "========================================"
log_info "ACME DNS 配置助手"
log_info "========================================"

# 创建配置目录
mkdir -p /etc/acme

echo ""
log_step "选择您的 DNS 提供商："
echo "1) Cloudflare"
echo "2) 阿里云 DNS"
echo "3) 腾讯云 DNS" 
echo "4) DNSPod"
echo "5) 华为云 DNS"
echo "6) AWS Route53"
echo "7) 自定义配置"

echo ""
echo -n "请选择 (1-7): "
read -r CHOICE

case "$CHOICE" in
    1)
        log_info "配置 Cloudflare DNS API..."
        echo ""
        echo "获取 Cloudflare API 密钥的步骤："
        echo "1. 访问: https://dash.cloudflare.com/profile/api-tokens"
        echo "2. 点击 'Create Token'"
        echo "3. 使用 'Custom token' 模板"
        echo "4. 权限设置为: Zone:Zone:Read, Zone:DNS:Edit"
        echo "5. Zone Resources: Include All zones"
        echo ""
        
        echo -n "请输入 Cloudflare API Token: "
        read -r CF_TOKEN
        echo -n "请输入 Cloudflare Account ID: "
        read -r CF_ACCOUNT_ID
        
        cat > /etc/acme/dns-config <<EOF
# Cloudflare DNS API 配置
export CF_Token="$CF_TOKEN"
export CF_Account_ID="$CF_ACCOUNT_ID"
EOF
        
        DNS_PROVIDER="dns_cf"
        ;;
        
    2)
        log_info "配置阿里云 DNS API..."
        echo ""
        echo "获取阿里云 DNS API 密钥的步骤："
        echo "1. 访问: https://ram.console.aliyun.com/manage/ak"
        echo "2. 创建 AccessKey"
        echo "3. 确保账户有 DNS 管理权限"
        echo ""
        
        echo -n "请输入 AccessKey ID: "
        read -r ALI_KEY
        echo -n "请输入 AccessKey Secret: "
        read -r ALI_SECRET
        
        cat > /etc/acme/dns-config <<EOF
# 阿里云 DNS API 配置
export Ali_Key="$ALI_KEY"
export Ali_Secret="$ALI_SECRET"
EOF
        
        DNS_PROVIDER="dns_ali"
        ;;
        
    3)
        log_info "配置腾讯云 DNS API..."
        echo ""
        echo "获取腾讯云 API 密钥的步骤："
        echo "1. 访问: https://console.cloud.tencent.com/cam/capi"
        echo "2. 创建密钥"
        echo "3. 确保账户有 DNS 管理权限"
        echo ""
        
        echo -n "请输入 SecretId: "
        read -r TENCENT_ID
        echo -n "请输入 SecretKey: "
        read -r TENCENT_KEY
        
        cat > /etc/acme/dns-config <<EOF
# 腾讯云 DNS API 配置
export Tencent_SecretId="$TENCENT_ID"
export Tencent_SecretKey="$TENCENT_KEY"
EOF
        
        DNS_PROVIDER="dns_tencent"
        ;;
        
    4)
        log_info "配置 DNSPod API..."
        echo ""
        echo "获取 DNSPod API 密钥的步骤："
        echo "1. 访问: https://console.dnspod.cn/account/token/token"
        echo "2. 创建 API Token"
        echo ""
        
        echo -n "请输入 DNSPod Token ID: "
        read -r DP_ID
        echo -n "请输入 DNSPod Token: "
        read -r DP_KEY
        
        cat > /etc/acme/dns-config <<EOF
# DNSPod API 配置
export DP_Id="$DP_ID"
export DP_Key="$DP_KEY"
EOF
        
        DNS_PROVIDER="dns_dp"
        ;;
        
    5)
        log_info "配置华为云 DNS API..."
        echo ""
        echo "获取华为云 API 密钥的步骤："
        echo "1. 访问华为云控制台"
        echo "2. 我的凭证 > 访问密钥"
        echo "3. 创建访问密钥"
        echo ""
        
        echo -n "请输入 Access Key ID: "
        read -r HUAWEI_ID
        echo -n "请输入 Secret Access Key: "
        read -r HUAWEI_KEY
        
        cat > /etc/acme/dns-config <<EOF
# 华为云 DNS API 配置
export HUAWEICLOUD_Username="$HUAWEI_ID"
export HUAWEICLOUD_Password="$HUAWEI_KEY"
export HUAWEICLOUD_DomainName="your-domain-name"
EOF
        
        DNS_PROVIDER="dns_huaweicloud"
        ;;
        
    6)
        log_info "配置 AWS Route53 API..."
        echo ""
        echo "获取 AWS API 密钥的步骤："
        echo "1. 访问 AWS IAM 控制台"
        echo "2. 创建具有 Route53 权限的用户"
        echo "3. 获取 Access Key 和 Secret Key"
        echo ""
        
        echo -n "请输入 AWS Access Key ID: "
        read -r AWS_KEY
        echo -n "请输入 AWS Secret Access Key: "
        read -r AWS_SECRET
        
        cat > /etc/acme/dns-config <<EOF
# AWS Route53 API 配置
export AWS_ACCESS_KEY_ID="$AWS_KEY"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
EOF
        
        DNS_PROVIDER="dns_aws"
        ;;
        
    7)
        log_info "自定义配置..."
        echo ""
        echo "请手动编辑配置文件: /etc/acme/dns-config"
        echo "参考文档: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
        
        if [[ ! -f "/etc/acme/dns-config" ]]; then
            cat > /etc/acme/dns-config <<EOF
# 自定义 DNS API 配置
# 请根据您的 DNS 提供商配置相应的环境变量
# 参考: https://github.com/acmesh-official/acme.sh/wiki/dnsapi

# 示例：Cloudflare
# export CF_Token="your_api_token"
# export CF_Account_ID="your_account_id"
EOF
        fi
        
        nano /etc/acme/dns-config || vim /etc/acme/dns-config || vi /etc/acme/dns-config
        
        echo ""
        echo -n "请输入您使用的 DNS 提供商名称 (如: dns_cf): "
        read -r DNS_PROVIDER
        ;;
        
    *)
        log_error "无效选择"
        exit 1
        ;;
esac

# 设置文件权限
chmod 600 /etc/acme/dns-config
chown root:root /etc/acme/dns-config

log_info "✓ DNS 配置文件已创建: /etc/acme/dns-config"

# 更新 acme-add 脚本的默认 DNS 提供商
if [[ -n "${DNS_PROVIDER:-}" ]]; then
    log_info "更新 acme-add 脚本的默认 DNS 提供商为: $DNS_PROVIDER"
    
    # 检查 acme-add 脚本是否存在
    if [[ -f "/usr/local/bin/acme-add" ]]; then
        # 备份原脚本
        cp /usr/local/bin/acme-add /usr/local/bin/acme-add.backup.$(date +%Y%m%d_%H%M%S)
        
        # 替换默认 DNS 提供商
        sed -i "s/dns_cf/$DNS_PROVIDER/g" /usr/local/bin/acme-add
        log_info "✓ 已更新 acme-add 脚本的默认 DNS 提供商"
    fi
fi

# 测试配置
echo ""
log_step "测试 DNS 配置..."
source /etc/acme/dns-config

# 验证必要的环境变量是否已设置
case "$DNS_PROVIDER" in
    "dns_cf")
        if [[ -n "${CF_Token:-}" && -n "${CF_Account_ID:-}" ]]; then
            log_info "✓ Cloudflare 配置验证通过"
        else
            log_error "✗ Cloudflare 配置不完整"
        fi
        ;;
    "dns_ali")
        if [[ -n "${Ali_Key:-}" && -n "${Ali_Secret:-}" ]]; then
            log_info "✓ 阿里云 DNS 配置验证通过"
        else
            log_error "✗ 阿里云 DNS 配置不完整"
        fi
        ;;
    "dns_tencent")
        if [[ -n "${Tencent_SecretId:-}" && -n "${Tencent_SecretKey:-}" ]]; then
            log_info "✓ 腾讯云 DNS 配置验证通过"
        else
            log_error "✗ 腾讯云 DNS 配置不完整"
        fi
        ;;
    *)
        log_info "配置文件已创建，请确保相关环境变量正确设置"
        ;;
esac

log_info ""
log_info "========================================"
log_info "✅ DNS 配置完成！"
log_info "========================================"
log_info "现在可以使用 DNS 验证申请证书："
log_info "  sudo acme-add example.com dns"
log_info "  sudo acme-add example.com '*.example.com' dns  # 泛域名"
log_info ""
log_info "配置文件位置: /etc/acme/dns-config"
log_info "如需修改配置，可以直接编辑该文件"
