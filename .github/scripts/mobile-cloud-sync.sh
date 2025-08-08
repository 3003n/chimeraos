#!/bin/bash
# shellcheck disable=SC2155
# mobile-cloud-sync.sh - ChimeraOS移动云盘同步脚本

set -e

# 配置变量
ALIST_URL="http://localhost:5244"
STORAGE_MOUNT_PATH="/移动云盘"
TARGET_FOLDER="Public/img"  # 目标文件夹路径
FILE_PREFIX="chimeraos-"    # 只下载此前缀的文件
TIMEOUT_SECONDS=1800
CHECK_INTERVAL=15

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# 获取release信息
get_release_info() {
    local tag_name="$1"
    local github_token="$2"
    
    log_info "获取release信息..."
    
    if [ -n "$tag_name" ]; then
        log_info "指定标签: $tag_name"
        echo "$tag_name"
    else
        log_info "获取最新release..."
        local latest_tag=$(curl -s -H "Authorization: Bearer $github_token" \
            "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/latest" | \
            jq -r '.tag_name')
        
        if [ "$latest_tag" = "null" ] || [ -z "$latest_tag" ]; then
            log_error "未找到有效的release"
            exit 1
        fi
        
        log_success "最新release: $latest_tag"
        echo "$latest_tag"
    fi
}

# 获取下载链接
get_download_urls() {
    local tag_name="$1"
    local github_token="$2"
    local output_file="$3"
    
    log_info "获取下载链接列表..."
    
    # 获取release详细信息
    local release_response=$(curl -s -H "Authorization: Bearer $github_token" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name")
    
    # 提取下载链接和文件信息，只保留指定前缀的文件
    echo "$release_response" | jq -r --arg prefix "$FILE_PREFIX" '.assets[] | select(.name | startswith($prefix)) | "\(.browser_download_url)|\(.name)|\(.size)"' > "$output_file"
    
    local file_count=$(cat "$output_file" | wc -l)
    local total_size=$(echo "$release_response" | jq --arg prefix "$FILE_PREFIX" '[.assets[] | select(.name | startswith($prefix)) | .size] | add // 0')
    local total_size_gb=$((total_size / 1024 / 1024 / 1024))
    
    log_success "找到 $file_count 个 $FILE_PREFIX 开头的文件，总大小: ${total_size_gb}GB"
    
    # 显示文件列表
    log_info "文件列表:"
    while IFS='|' read -r url name size; do
        if [ -n "$url" ]; then
            local size_mb=$((size / 1024 / 1024))
            echo "  📄 $name (${size_mb}MB)"
        fi
    done < "$output_file"
}

# 部署Alist
deploy_alist() {
    log_info "部署临时Alist服务..."
    
    # 创建临时目录
    mkdir -p /tmp/alist-data
    
    # 启动Alist容器
    docker run -d \
        --name=temp-alist \
        -p 5244:5244 \
        -v /tmp/alist-data:/opt/alist/data \
        xhofe/alist:latest
    
    # 等待启动完成
    log_info "等待Alist启动..."
    for i in {1..30}; do
        if curl -s "$ALIST_URL/ping" > /dev/null; then
            log_success "Alist服务启动成功"
            break
        fi
        echo "⏳ 等待服务启动... ($i/30)"
        sleep 3
    done
    
    # 获取管理员密码
    local admin_info=$(docker exec temp-alist ./alist admin random)
    local admin_password=$(echo "$admin_info" | grep -oP 'password: \K\S+' || echo "$admin_info" | awk '/password/{print $NF}')
    
    echo "$admin_password"
}

# 获取Alist token
get_alist_token() {
    local admin_password="$1"
    
    log_info "获取管理员Token..."
    
    local response=$(curl -s -X POST "$ALIST_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"admin\",
            \"password\": \"$admin_password\"
        }")
    
    local token=$(echo "$response" | jq -r '.data.token')
    
    if [ "$token" != "null" ] && [ -n "$token" ]; then
        log_success "Token获取成功"
        echo "$token"
    else
        log_error "Token获取失败: $response"
        exit 1
    fi
}

# 挂载移动云盘
mount_mobile_cloud() {
    local alist_token="$1"
    local mobile_authorization="$2"
    
    log_info "挂载移动云盘..."
    
    if [ -z "$mobile_authorization" ]; then
        log_error "未找到移动云盘认证信息"
        exit 1
    fi
    
    local mount_response=$(curl -s -X POST "$ALIST_URL/api/admin/storage/create" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d @- << EOF
{
    "mount_path": "$STORAGE_MOUNT_PATH",
    "driver": "139Yun", 
    "order": 0,
    "remark": "ChimeraOS Release同步",
    "addition": "{\"authorization\":\"${mobile_authorization}\",\"root_folder_id\":\"/\",\"type\":\"personal_new\",\"cloud_id\":\"\",\"custom_upload_part_size\":0,\"report_real_size\":true,\"use_large_thumbnail\":false}"
}
EOF
    )
    
    if echo "$mount_response" | jq -e '.code == 200' > /dev/null; then
        local storage_id=$(echo "$mount_response" | jq -r '.data.id')
        log_success "移动云盘挂载成功 (ID: $storage_id)"
        echo "$storage_id"
    else
        log_error "移动云盘挂载失败: $(echo "$mount_response" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 创建目标目录
create_target_directory() {
    local alist_token="$1"
    local tag_name="$2"
    
    local target_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"
    
    log_info "创建目标目录: $target_path"
    
    local mkdir_response=$(curl -s -X POST "$ALIST_URL/api/fs/mkdir" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    if echo "$mkdir_response" | jq -e '.code == 200' > /dev/null || echo "$mkdir_response" | jq -r '.message' | grep -q "already exists"; then
        log_success "目标目录准备完成"
        echo "$target_path"
    else
        log_error "目标目录创建失败: $(echo "$mkdir_response" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 检查已存在文件
check_existing_files() {
    local alist_token="$1"
    local target_path="$2"
    local force_sync="$3"
    
    log_info "检查已存在的文件..."
    
    local list_response=$(curl -s -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    if echo "$list_response" | jq -e '.code == 200' > /dev/null; then
        local existing_files=$(echo "$list_response" | jq -r '.data.content[]?.name // empty')
        local existing_count=$(echo "$existing_files" | wc -w)
        
        log_info "已存在 $existing_count 个文件"
        
        if [ "$existing_count" -gt 0 ] && [ "$force_sync" != "true" ]; then
            log_warning "目标目录已有文件，且未启用强制同步"
            echo "$existing_files" | while read -r file; do
                echo "  📄 $file"
            done
            echo "如需重新同步，请启用 force_sync 参数"
            return 1
        fi
        
        if [ "$force_sync" = "true" ] && [ "$existing_count" -gt 0 ]; then
            log_info "强制同步模式，清理已存在的文件..."
            echo "$existing_files" | while read -r file; do
                if [ -n "$file" ]; then
                    echo "删除: $file"
                    curl -s -X POST "$ALIST_URL/api/fs/remove" \
                        -H "Authorization: $alist_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"names\":[\"$target_path/$file\"]}" > /dev/null
                fi
            done
            log_success "文件清理完成"
        fi
    fi
    
    return 0
}

# 监控下载任务
monitor_download_task() {
    local alist_token="$1"
    local filename="$2"
    
    local max_wait=$TIMEOUT_SECONDS
    local wait_time=0
    
    while [ $wait_time -lt $max_wait ]; do
        # 检查未完成的任务
        local undone_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/undone" \
            -H "Authorization: $alist_token")
        
        # 检查已完成的任务  
        local done_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/done" \
            -H "Authorization: $alist_token")
        
        # 查找我们的任务
        local current_undone=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
            '.data[]? | select(.name | contains($filename)) | .state')
        
        if [ -n "$current_undone" ]; then
            local progress=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .progress // 0')
            
            if [ "$current_undone" = "0" ]; then
                echo "⏳ 等待开始... (${progress}%)"
            elif [ "$current_undone" = "1" ]; then
                echo "⏳ 下载进行中... (${progress}%)"
            fi
        else
            # 检查是否在已完成列表中
            local current_done=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .state')
            
            if [ -n "$current_done" ]; then
                if [ "$current_done" = "2" ]; then
                    echo "success"
                    return 0
                elif [ "$current_done" = "7" ]; then
                    local error_msg=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                        '.data[]? | select(.name | contains($filename)) | .error // "未知错误"')
                    echo "failed:$error_msg"
                    return 1
                else
                    echo "unknown:$current_done"
                    return 1
                fi
            fi
        fi
        
        sleep $CHECK_INTERVAL
        wait_time=$((wait_time + CHECK_INTERVAL))
    done
    
    echo "timeout"
    return 1
}

# 上传文件到移动云盘
upload_files() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "开始上传文件到移动云盘..."
    
    local file_index=0
    local success_count=0
    local fail_count=0
    local total_files=$(cat "$download_list_file" | wc -l)
    
    while IFS='|' read -r download_url filename filesize; do
        if [ -z "$download_url" ]; then
            continue
        fi
        
        file_index=$((file_index + 1))
        local size_mb=$((filesize / 1024 / 1024))
        
        echo ""
        log_info "[$file_index/$total_files] 开始下载: $filename (${size_mb}MB)"
        
        # 检查runner剩余空间
        local available_space=$(df /tmp --output=avail | tail -1)
        local available_gb=$((available_space / 1024 / 1024))
        local file_gb=$((filesize / 1024 / 1024 / 1024 + 1))
        
        echo "💾 可用空间: ${available_gb}GB, 文件大小: ${file_gb}GB"
        
        if [ $available_gb -lt $((file_gb + 2)) ]; then
            log_warning "空间不足，跳过大文件: $filename"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 添加离线下载任务
        log_info "提交下载任务..."
        local download_response=$(curl -s -X POST "$ALIST_URL/api/fs/add_offline_download" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{
                \"path\": \"$target_path\",
                \"urls\": [\"$download_url\"],
                \"tool\": \"SimpleHttp\",
                \"delete_policy\": \"delete_on_upload_succeed\"
            }")
        
        if echo "$download_response" | jq -e '.code == 200' > /dev/null; then
            log_success "下载任务提交成功"
        else
            log_error "下载任务提交失败: $(echo "$download_response" | jq -r '.message // "未知错误"')"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 监控下载进度
        log_info "监控下载进度..."
        local result=$(monitor_download_task "$alist_token" "$filename")
        
        case "$result" in
            "success")
                log_success "[$file_index] $filename 下载成功！"
                success_count=$((success_count + 1))
                ;;
            "failed:"*)
                local error_msg="${result#failed:}"
                log_error "[$file_index] $filename 下载失败: $error_msg"
                fail_count=$((fail_count + 1))
                ;;
            "timeout")
                log_warning "[$file_index] $filename 下载超时"
                fail_count=$((fail_count + 1))
                ;;
            *)
                log_warning "[$file_index] $filename 结束，状态: $result"
                fail_count=$((fail_count + 1))
                ;;
        esac
        
        # 短暂休息避免过载
        sleep 2
        
    done < "$download_list_file"
    
    echo ""
    log_info "上传完成统计:"
    echo "  ✅ 成功: $success_count"
    echo "  ❌ 失败: $fail_count"
    echo "  📁 总计: $total_files"
    echo "  🎯 过滤规则: 只下载 $FILE_PREFIX 开头的文件"
    
    # 返回成功文件数
    echo "$success_count"
}

# 验证上传结果
verify_upload() {
    local alist_token="$1"
    local target_path="$2"
    
    log_info "验证上传结果..."
    
    local result=$(curl -s -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    if echo "$result" | jq -e '.code == 200' > /dev/null; then
        local uploaded_files=$(echo "$result" | jq -r '.data.content[]?.name // empty')
        local uploaded_count=$(echo "$uploaded_files" | wc -w)
        
        log_success "目标目录: $target_path"
        log_success "上传完成文件数: $uploaded_count"
        
        if [ "$uploaded_count" -gt 0 ]; then
            log_info "上传的文件:"
            echo "$uploaded_files" | while read -r file; do
                if [ -n "$file" ]; then
                    local file_info=$(echo "$result" | jq -r --arg name "$file" \
                        '.data.content[] | select(.name == $name) | "大小: \(.size) bytes, 修改时间: \(.modified)"')
                    echo "  📄 $file - $file_info"
                fi
            done
        fi
        
        echo "$uploaded_count"
    else
        log_error "无法获取上传结果: $(echo "$result" | jq -r '.message // "未知错误"')"
        echo "0"
    fi
}

# 清理资源
cleanup() {
    local alist_token="$1"
    local storage_id="$2"
    
    log_info "清理临时资源..."
    
    # 删除移动云盘存储
    if [ -n "$storage_id" ]; then
        log_info "删除临时存储..."
        curl -s -X POST "$ALIST_URL/api/admin/storage/delete" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{\"id\": $storage_id}" > /dev/null || log_warning "存储删除失败"
    fi
    
    # 停止并删除容器
    docker stop temp-alist || true
    docker rm temp-alist || true
    
    # 清理临时文件
    rm -rf /tmp/alist-data /tmp/download_list.txt || true
    
    log_success "清理完成"
}

# 主函数
main() {
    local tag_name="$1"
    local force_sync="$2"
    local github_token="$3"
    local mobile_authorization="$4"
    
    echo "🚀 ChimeraOS移动云盘同步开始"
    echo "================================================"
    
    # 获取release信息
    local release_tag=$(get_release_info "$tag_name" "$github_token")
    
    # 获取下载链接
    get_download_urls "$release_tag" "$github_token" "/tmp/download_list.txt"
    
    # 部署Alist
    local admin_password=$(deploy_alist)
    
    # 获取token
    local alist_token=$(get_alist_token "$admin_password")
    
    # 挂载移动云盘
    local storage_id=$(mount_mobile_cloud "$alist_token" "$mobile_authorization")
    
    # 创建目标目录
    local target_path=$(create_target_directory "$alist_token" "$release_tag")
    
    # 检查已存在文件
    if ! check_existing_files "$alist_token" "$target_path" "$force_sync"; then
        cleanup "$alist_token" "$storage_id"
        log_warning "同步已跳过"
        return 0
    fi
    
    # 上传文件
    local success_count=$(upload_files "$alist_token" "$target_path" "/tmp/download_list.txt")
    
    # 验证结果
    local final_count=$(verify_upload "$alist_token" "$target_path")
    
    # 清理资源
    cleanup "$alist_token" "$storage_id"
    
    echo ""
    echo "================================================"
    log_success "ChimeraOS $release_tag 同步完成！"
    log_success "📱 目标: 中国移动云盘"
    log_success "📁 路径: $target_path"
    log_success "📊 成功文件数: $final_count"
    log_success "🎯 文件过滤: 只同步 $FILE_PREFIX 开头的文件"
    echo "🇨🇳 国内用户现在可以通过移动云盘快速下载了！"
}

# 检查必需参数
if [ $# -lt 4 ]; then
    echo "Usage: $0 <tag_name> <force_sync> <github_token> <mobile_authorization>"
    echo "  tag_name: Release标签 (留空使用最新)"
    echo "  force_sync: 强制重新同步 (true/false)"
    echo "  github_token: GitHub Token"
    echo "  mobile_authorization: 移动云盘认证"
    exit 1
fi

# 执行主函数
main "$1" "$2" "$3" "$4"
