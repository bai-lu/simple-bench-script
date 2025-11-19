# Simple Bench Script (SBS)

一个简单的 Linux 系统性能基准测试脚本，用于测试 CPU、内存和磁盘性能。

## 功能特性

- ✅ CPU 性能测试 (基于 sysbench)
- ✅ 内存性能测试 (基于 sysbench)
- ✅ 磁盘 I/O 测试 (基于 fio，支持 dd 回退)
- ✅ 显示基本系统信息
- ✅ 支持选择性跳过测试项目
- ✅ 无需公网连接，纯本地运行

## 系统要求

### 必需工具

- **fio** - 用于磁盘性能测试
- **sysbench** - 用于 CPU 和内存性能测试

### 安装依赖

**Debian/Ubuntu:**
```bash
sudo apt-get install fio sysbench
```

**CentOS/RHEL:**
```bash
sudo yum install fio sysbench
```

**Arch Linux:**
```bash
sudo pacman -S fio sysbench
```

### 支持的架构

- x86_64 (x64)
- i386/i686 (x86)
- ARM 64-bit (aarch64)
- ARM 32-bit (arm) - 实验性支持

## 使用方法

### 基本用法

运行完整测试：
```bash
bash sbs.sh
```

### 命令行参数

```bash
bash sbs.sh [-flags]
```

**可用参数:**

- `-c` : 跳过 CPU 基准测试
- `-d` : 跳过磁盘基准测试
- `-m` : 跳过内存基准测试
- `-h` : 显示帮助信息

### 使用示例

仅测试 CPU 和内存（跳过磁盘测试）：
```bash
bash sbs.sh -d
```

仅测试磁盘（跳过 CPU 和内存测试）：
```bash
bash sbs.sh -c -m
```

显示帮助信息：
```bash
bash sbs.sh -h
```

## 测试说明

### 系统信息

脚本会显示以下系统信息：
- 系统运行时间
- CPU 型号和核心数
- AES-NI 支持状态
- 虚拟化支持（VM-x/AMD-V）
- RAM 和 Swap 大小
- 磁盘容量
- 发行版和内核版本
- 虚拟化类型

### CPU 测试

使用 sysbench 进行 CPU 性能测试，自动使用所有可用 CPU 核心。

### 内存测试

使用 sysbench 进行内存带宽和延迟测试，自动使用所有可用 CPU 核心。

### 磁盘测试

使用 fio 进行随机混合读写测试（50% 读 / 50% 写），测试多种块大小：
- 4KB
- 64KB
- 512KB
- 1MB

**测试数据量:**
- x86_64: 2GB
- ARM: 512MB

如果 fio 不可用或测试失败，会自动回退使用 dd 进行顺序读写测试。

### 磁盘空间要求

- **x86_64 架构**: 至少 2GB 可用空间
- **ARM 架构**: 至少 512MB 可用空间

## 注意事项

1. **权限要求**: 脚本需要在有写权限的目录中运行
2. **ZFS 文件系统**: 在 ZFS 上运行时，如果可用空间不足，会显示警告
3. **测试时间**: 完整测试通常需要几分钟时间
4. **测试文件**: 脚本会在当前目录创建临时文件夹，测试完成后自动清理
5. **中断测试**: 可使用 Ctrl+C 安全中断测试，脚本会自动清理临时文件

## 故障排除

### fio 未找到
```
fio not found. Please install fio to run disk tests.
```
**解决方案**: 安装 fio 工具包

### sysbench 未找到
```
sysbench not found. Please install sysbench to run CPU/memory tests.
```
**解决方案**: 安装 sysbench 工具包

### 磁盘空间不足
```
Less than 2GB of space available. Skipping disk test...
```
**解决方案**: 清理磁盘空间或使用 `-d` 参数跳过磁盘测试

### 无写权限
```
You do not have write permission in this directory.
```
**解决方案**: 切换到有写权限的目录或使用 `sudo` 运行

## 版本历史

- **v2024-01-01**: 简化版本
  - 移除网络测试
  - 移除 Geekbench 集成
  - 移除公网依赖
  - 仅保留核心性能测试功能

## 许可证

本脚本基于原 YABS (Yet Another Bench Script) 修改而来。

## 贡献

欢迎提交 Issue 和 Pull Request。
