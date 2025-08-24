# SkorionOS Fastfetch Logo Package

简化的SkorionOS fastfetch logo包，适用于系统镜像预装或制作pkg包。

## 📁 文件结构

```
fastfetch-logo-pkg/
├── PKGBUILD           # Arch Linux 包构建文件
├── config.jsonc       # Fastfetch 默认配置
├── skorionos-logo.txt # SkorionOS ASCII logo
├── install.sh         # 安装脚本
└── README.md          # 说明文档
```

## 🚀 使用方法

### 方法1: 制作 Arch Linux 包

```bash
cd fastfetch-logo-pkg/
makepkg -si
```

### 方法2: 直接安装到系统（用于镜像预装）

```bash
cd fastfetch-logo-pkg/
sudo ./install.sh
```

### 方法3: 手动安装

```bash
# 复制文件到系统目录
sudo cp skorionos-logo.txt /usr/share/fastfetch/logos/skorionos.txt
sudo cp config.jsonc /etc/xdg/fastfetch/config.jsonc
```

## 📋 安装后使用

```bash
# 使用系统默认配置（包含SkorionOS logo）
fastfetch --config /etc/xdg/fastfetch/config.jsonc

# 明确指定使用SkorionOS logo
fastfetch --logo skorionos.txt
```

## 🎨 颜色方案

- 主色调: Arch Linux 青色 (Cyan)
- 强调色: 蓝色 (Blue)

## 📦 包信息

- 包名: `skorionos-fastfetch-logo`
- 版本: 1.0.0
- 依赖: `fastfetch`
- 架构: `any`
