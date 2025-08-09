#!/bin/bash
# shellcheck disable=SC2155
# mobile-cloud-sync.sh - ChimeraOS移动云盘同步脚本

set -e

# 配置变量
ALIST_URL="http://localhost:5244"
STORAGE_MOUNT_PATH="/移动云盘"
TARGET_FOLDER="Public/img"  # 目标文件夹路径

# 文件过滤规则 - 支持多种规则类型
# 格式: "type:pattern" 多个规则用逗号分隔
# 类型:
#   prefix:xxx    - 前缀匹配
#   suffix:xxx    - 后缀匹配
#   contains:xxx  - 包含匹配
#   regex:xxx     - 正则表达式匹配
#   size_min:xxx  - 最小文件大小 (MB)
#   size_max:xxx  - 最大文件大小 (MB)
#   exclude:xxx   - 排除规则 (支持 prefix/suffix/contains/regex)
#
# 示例配置:
#   "prefix:chimeraos-"                          # 只下载chimeraos-开头的文件
#   "prefix:chimeraos-,exclude:suffix:.txt"     # 下载chimeraos-开头但排除.txt文件
#   "suffix:.img.xz,size_min:100"               # 下载.img.xz结尾且大于100MB的文件
#   "contains:kde,exclude:contains:nv"          # 包含kde但不包含nv的文件
#   "regex:.*-(kde|gnome)\..*"                  # 正则匹配包含kde或gnome的文件
FILE_FILTER_RULES="prefix:chimeraos-,exclude:contains:hyprland,exclude:contains:cosmic,exclude:contains:cinnamon"
TIMEOUT_SECONDS=1800
CHECK_INTERVAL=5

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# 获取当前时间戳
get_timestamp() {
    date '+%H:%M:%S'
}

log_info() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}ℹ️  $1${NC}" >&2
}

log_success() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${GREEN}✅ $1${NC}" >&2
}

log_warning() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${YELLOW}⚠️  $1${NC}" >&2
}

log_error() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${RED}❌ $1${NC}" >&2
}

# 进度日志 (带时间戳)
log_progress() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}⏳ $1${NC}" >&2
}

# 检查API响应是否为有效JSON
check_api_response() {
    local response="$1"
    local operation="$2"
    
    log_info "调试: $operation 原始响应: '$response'"
    log_info "调试: 响应长度: ${#response} 字符"
    
    if [ -z "$response" ]; then
        log_error "$operation API响应为空"
        return 1
    fi
    
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log_error "$operation API响应不是有效JSON"
        log_error "原始响应内容: '$response'"
        log_error "响应的十六进制: $(echo "$response" | xxd -l 100)"
        return 1
    fi
    return 0
}



# 获取release信息
get_release_info() {
    local tag_name="$1"
    local github_token="$2"
    
    # 检查GitHub仓库环境变量
    if [ -z "$GITHUB_REPOSITORY" ]; then
        log_warning "GITHUB_REPOSITORY环境变量未设置，使用默认值"
        export GITHUB_REPOSITORY="ChimeraOS/chimeraos"
    fi
    
    log_info "获取release信息..."
    log_info "仓库: $GITHUB_REPOSITORY"
    
    if [ -n "$tag_name" ]; then
        log_info "指定标签: $tag_name"
        echo "$tag_name"
    else
        log_info "获取最新release (包括prerelease)..."
        log_info "调试: 请求releases列表 URL: https://api.github.com/repos/$GITHUB_REPOSITORY/releases"
        
        local releases_response=$(curl -s -H "Authorization: Bearer $github_token" \
            "https://api.github.com/repos/$GITHUB_REPOSITORY/releases?per_page=10")
        
        log_info "调试: releases API响应长度: ${#releases_response} 字符"
        
        # 检查API响应
        if ! echo "$releases_response" | jq . > /dev/null 2>&1; then
            log_error "releases API响应不是有效JSON: $releases_response"
            exit 1
        fi
        
        # 获取第一个release（最新的，包括prerelease）
        local latest_tag=$(echo "$releases_response" | jq -r '.[0].tag_name')
        
        if [ "$latest_tag" = "null" ] || [ -z "$latest_tag" ]; then
            log_error "未找到有效的release"
            log_error "API响应: $releases_response"
            exit 1
        fi
        
        # 检查是否为prerelease
        local is_prerelease=$(echo "$releases_response" | jq -r '.[0].prerelease')
        if [ "$is_prerelease" = "true" ]; then
            log_info "检测到prerelease: $latest_tag"
        else
            log_info "检测到正式release: $latest_tag"
        fi
        
        log_success "最新release: $latest_tag"
        echo "$latest_tag"
    fi
}

# 文件过滤函数
filter_file() {
    local filename="$1"
    local filesize="$2"  # 字节为单位
    local rules="$3"
    
    # 如果没有规则，默认通过
    if [ -z "$rules" ]; then
        return 0
    fi
    
    local size_mb=$((filesize / 1024 / 1024))
    local should_include=1  # 默认包含
    local has_include_rule=0  # 是否有包含规则
    
    # 分割规则
    local IFS=','
    for rule in $rules; do
        local rule_type=$(echo "$rule" | cut -d: -f1)
        local rule_pattern=$(echo "$rule" | cut -d: -f2-)
        
        case "$rule_type" in
            "prefix")
                has_include_rule=1
                if [[ "$filename" == "$rule_pattern"* ]]; then
                    should_include=0
                fi
                ;;
            "suffix")
                has_include_rule=1
                if [[ "$filename" == *"$rule_pattern" ]]; then
                    should_include=0
                fi
                ;;
            "contains")
                has_include_rule=1
                if [[ "$filename" == *"$rule_pattern"* ]]; then
                    should_include=0
                fi
                ;;
            "regex")
                has_include_rule=1
                if echo "$filename" | grep -qE "$rule_pattern"; then
                    should_include=0
                fi
                ;;
            "size_min")
                if [ "$size_mb" -lt "$rule_pattern" ]; then
                    return 1  # 文件太小，排除
                fi
                ;;
            "size_max")
                if [ "$size_mb" -gt "$rule_pattern" ]; then
                    return 1  # 文件太大，排除
                fi
                ;;
            "exclude")
                # 排除规则，支持子类型
                local exclude_type=$(echo "$rule_pattern" | cut -d: -f1)
                local exclude_pattern=$(echo "$rule_pattern" | cut -d: -f2-)
                
                case "$exclude_type" in
                    "prefix")
                        if [[ "$filename" == "$exclude_pattern"* ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "suffix")
                        if [[ "$filename" == *"$exclude_pattern" ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "contains")
                        if [[ "$filename" == *"$exclude_pattern"* ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "regex")
                        if echo "$filename" | grep -qE "$exclude_pattern"; then
                            return 1  # 排除
                        fi
                        ;;
                esac
                ;;
        esac
    done
    
    # 如果有包含规则但没匹配到，则排除
    if [ "$has_include_rule" -eq 1 ] && [ "$should_include" -eq 1 ]; then
        return 1
    fi
    
    return 0
}

# 获取下载链接
get_download_urls() {
    local tag_name="$1"
    local github_token="$2"
    local output_file="$3"
    
    log_info "获取下载链接列表..."
    
    # 获取release详细信息
    log_info "调试: 请求URL: https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name"
    local release_response=$(curl -s -H "Authorization: Bearer $github_token" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name")
    
    log_info "调试: Release API响应长度: ${#release_response} 字符"
    
    # 检查API响应是否有效
    if ! echo "$release_response" | jq . > /dev/null 2>&1; then
        log_error "Release API响应不是有效JSON: $release_response"
        exit 1
    fi
    
    # 显示所有assets用于调试
    local all_assets=$(echo "$release_response" | jq -r '.assets[]?.name // empty')
    log_info "调试: 该release的所有文件:"
    echo "$all_assets" | while read -r asset; do
        if [ -n "$asset" ]; then
            echo "  📄 $asset" >&2
        fi
    done
    
    # 提取下载链接和文件信息，使用新的过滤系统
    echo "$release_response" | jq -r '.assets[] | "\(.browser_download_url)|\(.name)|\(.size)"' | while IFS='|' read -r url name size; do
        if [ -n "$url" ] && filter_file "$name" "$size" "$FILE_FILTER_RULES"; then
            echo "$url|$name|$size"
        fi
    done > "$output_file"
    
    local file_count=$(cat "$output_file" | wc -l)
    
    # 检查是否找到了匹配的文件
    if [ "$file_count" -eq 0 ]; then
        log_warning "未找到符合过滤规则的文件"
        log_info "过滤规则: $FILE_FILTER_RULES"
        log_info "该release可能不包含符合条件的文件，跳过同步"
        return 1
    fi
    
    # 计算总大小
    local total_size=0
    while IFS='|' read -r url name size; do
        if [ -n "$size" ]; then
            total_size=$((total_size + size))
        fi
    done < "$output_file"
    local total_size_gb=$((total_size / 1024 / 1024 / 1024))
    
    log_success "找到 $file_count 个符合过滤规则的文件，总大小: ${total_size_gb}GB"
    log_info "过滤规则: $FILE_FILTER_RULES"
    
    # 显示文件列表
    log_info "文件列表:"
    while IFS='|' read -r url name size; do
        if [ -n "$url" ]; then
            local size_mb=$((size / 1024 / 1024))
            echo "  📄 $name (${size_mb}MB)" >&2
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
        xhofe/alist:latest >/dev/null
    
    # 等待启动完成
    log_info "等待Alist启动..."
    for i in {1..30}; do
        if curl -s "$ALIST_URL/ping" > /dev/null 2>&1; then
            log_success "Alist服务启动成功"
            break
        fi
        log_info "等待服务启动... ($i/30)"
        sleep 3
        
        if [ $i -eq 30 ]; then
            log_error "Alist启动超时"
            docker logs temp-alist
            exit 1
        fi
    done
    
    # 设置固定管理员密码
    local admin_password="temp123456"
    log_info "设置管理员密码..."
    
    docker exec temp-alist ./alist admin set "$admin_password" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "设置管理员密码失败"
        exit 1
    fi
    
    log_success "管理员密码设置成功"
    echo "$admin_password"
}

# 获取Alist token
get_alist_token() {
    local admin_password="$1"
    
    log_info "获取管理员Token..."
    log_info "调试: 使用密码: $admin_password"
    log_info "调试: 尝试连接: $ALIST_URL/api/auth/login"
    
    # 先测试基本连通性
    local ping_result=$(curl -s -w "%{http_code}" -o /dev/null "$ALIST_URL/ping" || echo "000")
    log_info "调试: ping测试状态码: $ping_result"
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"admin\",
            \"password\": \"$admin_password\"
        }")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: HTTP状态码: $http_code"
    log_info "调试: 响应体: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "HTTP请求失败，状态码: $http_code"
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "登录"; then
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    local token=$(echo "$response_body" | jq -r '.data.token // empty')
    
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        log_success "Token获取成功"
        echo "$token"
    else
        log_error "Token获取失败: $response_body"
        local error_msg=$(echo "$response_body" | jq -r '.message // "未知错误"')
        log_error "错误信息: $error_msg"
        exit 1
    fi
}

# 挂载移动云盘
mount_mobile_cloud() {
    local alist_token="$1"
    local mobile_authorization="$2"
    
    log_info "挂载移动云盘..."
    log_info "调试: 使用token: ${alist_token:0:20}..."
    
    if [ -z "$mobile_authorization" ]; then
        log_error "未找到移动云盘认证信息"
        exit 1
    fi
    
    local mount_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/admin/storage/create" \
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
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mount_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mount_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: 挂载HTTP状态码: $http_code"
    
    if [ "$http_code" != "200" ]; then
        log_error "挂载HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "挂载移动云盘"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local storage_id=$(echo "$response_body" | jq -r '.data.id')
        log_success "移动云盘挂载成功 (ID: $storage_id)"
        echo "$storage_id"
    else
        log_error "移动云盘挂载失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 创建目标目录
create_target_directory() {
    local alist_token="$1"
    local tag_name="$2"
    
    local target_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"
    
    log_info "创建目标目录: $target_path"
    
    local mkdir_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/mkdir" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mkdir_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mkdir_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: 创建目录HTTP状态码: $http_code"
    log_info "调试: 创建目录响应: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "创建目录HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "创建目录"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null || echo "$response_body" | jq -r '.message' | grep -q "already exists"; then
        log_success "目标目录准备完成"
        echo "$target_path"
    else
        log_error "目标目录创建失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 检查已存在文件
check_existing_files() {
    local alist_token="$1"
    local target_path="$2"
    local force_sync="$3"
    local download_list_file="$4"
    
    log_info "检查已存在的文件..."
    
    local list_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$list_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$list_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: 列出文件HTTP状态码: $http_code"
    log_info "调试: 列出文件响应: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "列出文件HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "列出文件"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local existing_files=$(echo "$response_body" | jq -r '.data.content[]?.name // empty')
        local existing_count=$(echo "$existing_files" | wc -w)
        
        log_info "云盘中已存在 $existing_count 个文件"
        
        # 获取要同步的文件列表
        local sync_files=""
        if [ -f "$download_list_file" ]; then
            sync_files=$(awk -F'|' '{print $2}' "$download_list_file" | tr '\n' ' ')
        fi
        
        # 检查要同步的文件是否已存在
        local conflicted_files=""
        if [ -n "$sync_files" ] && [ "$existing_count" -gt 0 ]; then
            for sync_file in $sync_files; do
                if echo "$existing_files" | grep -q "^$sync_file$"; then
                    conflicted_files="$conflicted_files $sync_file"
                fi
            done
        fi
        
        local conflict_count=$(echo "$conflicted_files" | wc -w)
        
        if [ "$conflict_count" -gt 0 ] && [ "$force_sync" != "true" ]; then
            log_warning "检测到 $conflict_count 个文件已存在，且未启用强制同步"
            for file in $conflicted_files; do
                echo "  📄 $file"
            done
            echo "如需重新同步，请启用 force_sync 参数"
            return 1
        fi
        
        if [ "$force_sync" = "true" ] && [ "$conflict_count" -gt 0 ]; then
            log_info "强制同步模式，清理冲突的文件..."
            for file in $conflicted_files; do
                if [ -n "$file" ]; then
                    echo "删除: $file"
                    curl -s -X POST "$ALIST_URL/api/fs/remove" \
                        -H "Authorization: $alist_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"names\":[\"$target_path/$file\"]}" > /dev/null
                fi
            done
            log_success "已清理冲突文件"
        fi
        
        if [ "$conflict_count" -eq 0 ] && [ "$existing_count" -gt 0 ]; then
            log_info "云盘中的文件与当前同步任务无冲突，继续执行"
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
                log_progress "等待任务开始... (${progress}%)"
            elif [ "$current_undone" = "1" ]; then
                log_progress "正在下载到云盘... (${progress}%)"
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
        log_info "[$file_index/$total_files] 处理文件: $filename (${size_mb}MB)"
        
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
        log_info "提交离线下载任务到Alist..."
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
            log_success "离线下载任务已提交，开始传输到云盘"
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
                log_warning "[$file_index] $filename 下载未完成，最终状态: $result"
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
    echo "  🎯 过滤规则: $FILE_FILTER_RULES"
    
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
                    echo "  📄 $file - $file_info" >&2
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
    
    # 清理临时文件（使用sudo处理权限问题）
    if [ -d "/tmp/alist-data" ]; then
        sudo rm -rf /tmp/alist-data || rm -rf /tmp/alist-data || log_warning "无法删除 /tmp/alist-data，可能需要手动清理"
    fi
    rm -f /tmp/download_list.txt || true
    
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
    log_info "调试: 传入的tag_name参数: '$tag_name'"
    local release_tag=$(get_release_info "$tag_name" "$github_token")
    
    # 获取下载链接
    if ! get_download_urls "$release_tag" "$github_token" "/tmp/download_list.txt"; then
        log_warning "没有需要同步的文件，退出"
        return 0
    fi
    
    # 部署Alist
    local admin_password=$(deploy_alist)
    
    # 获取token
    local alist_token=$(get_alist_token "$admin_password")
    
    # 挂载移动云盘
    local storage_id=$(mount_mobile_cloud "$alist_token" "$mobile_authorization")
    
    # 创建目标目录
    local target_path=$(create_target_directory "$alist_token" "$release_tag")
    
    # 检查已存在文件
    if ! check_existing_files "$alist_token" "$target_path" "$force_sync" "/tmp/download_list.txt"; then
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
    log_success "🎯 文件过滤: $FILE_FILTER_RULES"
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
