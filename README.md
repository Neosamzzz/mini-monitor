# MiniMonitor

极简的 macOS 菜单栏系统监视器。原生 Swift + SwiftUI,单个源文件，无需 Xcode 工程。

A minimal macOS menu bar monitor for CPU, temperature and memory. Single Swift file, no Xcode project.

## 功能

- **菜单栏**:两行小字常显 `CPU 23%  52°` / `MEM 11.7G`,自动适配深浅色
- **面板**(点击图标):
  - CPU 使用率、CPU 温度、内存已用量
  - 内存进度条表示**内存压力**而不是已用比例(Mac 会尽量用满内存，用得多不代表不够用),并显示 Swap
  - 占用最高的 4 个 App,可按 CPU / 内存切换;Helper、WebContent 等子进程归到所属 App,带图标;包含系统进程
- **预警**(系统通知，持续超阈值才提醒，回落后才会再次提醒):
  - CPU ≥ 90% 持续 1 分钟
  - 温度 ≥ 95°C 持续 30 秒
  - 内存压力偏高持续 1 分钟 / 紧张
  - 单个进程持续占用 CPU ≥ 90%,或内存 ≥ 物理内存 25%
- **右键菜单**:开机自启、退出
- 省资源：面板关闭时 CPU 占用约 1%

## 构建

需要 macOS 14+ 和 Xcode Command Line Tools(`xcode-select --install`)。

```bash
./build.sh            # 编译并打包成 MiniMonitor.app(ad-hoc 签名)
open MiniMonitor.app
```

首次运行图标可能被收进菜单栏的折叠区，按住 ⌘ 拖出来即可。首次触发预警时系统会询问是否允许通知。

自检命令：

```bash
MiniMonitor.app/Contents/MacOS/MiniMonitor --dump   # 终端打印一次读数和占用最高的 App
```

## 说明

- **温度**通过 IOKit 的非公开 HID 传感器接口读取，仅在 Apple 芯片上测试过;系统升级后可能失效，失效时显示 `—`
- **系统进程**的数据来自 `/bin/ps`(普通 App 无法直接读取 root 进程)。系统进程的内存只能拿到 RSS,会比活动监视器显示的偏小;`kernel_task` 不在列表中
- App 内存是其所有进程相加，共享内存会重复计算，略偏大

## License

[MIT](LICENSE)
