# GlassesPlayer — 开发者文档

## 项目结构

```
GlassesPlayer/
├── GlassesPlayerApp.swift     # App 入口，菜单裁剪
├── ContentView.swift          # SwiftUI 主界面：控制栏、拖拽、键盘
├── VideoPlayerModel.swift     # @Observable 状态模型，Swift↔C 桥接层
├── MetalRenderer.swift        # PlayerMetalView — Metal 渲染 + 输入事件
├── Shaders.metal              # 等距柱状投影顶点/片段着色器
├── SettingsView.swift         # 设置面板（FOV、交互偏好）
├── MPVPlayer.h                # C API 头文件
├── MPVPlayer.c                # mpv 封装：播放控制、MP4 修复、IOSurface
├── BridgingHeader.h           # Swift↔C 桥接
└── Assets.xcassets/           # 图标、颜色资源

vendor/
├── lib/*.dylib                # 自包含动态库（mpv, ffmpeg 等）
└── include/mpv/               # mpv C headers

scripts/
└── collect_vendor.sh          # 一次性脚本：从 Homebrew 收集 dylib
```

## 构建

### 前置条件

- Xcode 15+
- macOS 14+
- `vendor/` 目录已提交到仓库（含 libmpv、ffmpeg 等 ~42 个 dylib）

### 构建步骤

```bash
# 直接构建（vendor/ 已在仓库中）
xcodebuild -project GlassesPlayer.xcodeproj -scheme GlassesPlayer -configuration Debug

# 如需重新收集 dylib（仅维护者）
bash scripts/collect_vendor.sh
```

### vendor/ 维护

`scripts/collect_vendor.sh` 从 `/opt/homebrew` 收集 libmpv 及其依赖：

1. 递归 `otool -L` 收集所有 Homebrew dylib
2. 复制到 `vendor/lib/`，使用 versioned 文件名
3. `install_name_tool -id @rpath/name.dylib` 修改 identity
4. `install_name_tool -change` 修复所有内部引用路径
5. Ad-hoc codesign

项目 `.pbxproj` 的 `HEADER_SEARCH_PATHS` 和 `LIBRARY_SEARCH_PATHS` 指向 `vendor/`，无需安装 Homebrew 即可构建。

## 架构

### 渲染管线

```
MP4 文件
  ↓ mpv (libmpv + ffmpeg)
OpenGL FBO (内部 CGLContext)
  ↓ render_frame()
IOSurface (共享 GPU 纹理)
  ↓ IOSurface → MTLTexture
Metal Render Encoder
  ↓ projectionVertex / projectionFragment
屏幕输出
```

**关键点：**

- mpv 在自己的 OpenGL 上下文中解码并渲染到 FBO
- FBO 绑定 IOSurface 纹理（`CGLTexImageIOSurface2D`）
- Metal 侧通过 `MTLDevice.makeTexture(descriptor:iosurface:plane:)` 零拷贝访问同一块显存
- 每帧 `mpv_player_render_frame()` → `mpv_player_get_surface()` → Metal draw

### 360° 投影

`Shaders.metal` 实现等距柱状投影 (Equirectangular)：

1. 顶点着色器输出全屏四边形 + NDC 坐标
2. 片段着色器：NDC → 相机空间射线 → yaw/pitch 旋转 → 球面坐标 → 纹理采样
3. 支持 SBS 左右 / SBS 上下 / 360° 单目三种布局
4. 双眼模式时拆分为两个 viewport 分别渲染

### 输入系统

| 输入 | 行为 |
|------|------|
| 鼠标移动（指针模式） | 非 360°/非 2D 视频时，位置映射到 yaw/pitch |
| 鼠标拖拽（拖拽模式） | 360° 视频时，增量控制 yaw/pitch |
| 滚轮 | 缩放 FOV（2D 模式下禁用；Option+滚轮 = 音量） |
| 全屏边缘光标换边 | `CGWarpMouseCursorPosition` 实现无缝环视（仅 360°） |
| 拖拽文件 | `.dropDestination(for: URL.self)` |

### 事件模型

mpv 事件通过 30fps Timer 轮询（`pollMPVEvents`）：

```
Timer (30Hz)
  → mpv_player_poll_events()
  → mpv_wait_event(timeout=0) 非阻塞循环
  → 返回 bitmask (MPV_PROP_*)
  → Swift 更新 @Observable 属性
  → SwiftUI 自动刷新
```

属性变更通过 `mpv_observe_property` 注册，在事件循环中回调。

## MP4 时间轴修复

### 问题

HLS 直播录制（如 hls.js）生成的 MP4 文件，`edts/elst` 的 `segment_duration` 只覆盖一个 HLS 片段（~20s），而非完整视频（可能 19+ 分钟）。mpv/ffmpeg 优先使用 elst 计算播放时长，导致视频显示错误时长。

### 解决方案

`MPVPlayer.c` 中的 `fix_broken_mp4()` 实现按需修复：

1. **检测**：读取 moov atom，遍历每个 trak，检查 edts/elst 的 segment_duration 是否远小于 tkhd duration
2. **修复**：将有问题的 edts 转换为 `free` atom（改 type 为 "free"，body 清零）
3. **写入**：APFS `clonefile()` COW 克隆原文件 → 仅覆写 moov section
4. **兜底**：同时设置 mpv 的 `demuxer-lavf-o=use_editlist=0`

**关键设计：**
- edts 位于 trak 末尾，转 free 不改变 atom 大小，stco chunk offset 保持有效
- 原始文件始终不被修改
- 无问题的视频只多一次 moov 读取（几 KB~几 MB），无额外开销

### 临时文件管理

- 修复后的文件存放在 `~/Library/Logs/GlassesPlayer/fixed_<pid>.mp4`
- 正常退出：`cleanup_temp_file()` 在 open/stop/destroy 时删除
- 崩溃后：`ensure_log_dir()` 启动时扫描并删除所有 `fixed_*` 文件

## 多视频轨道

HLS 录制可能生成多个视频轨道（每个 HLS 片段一个）。`record_video_tracks()` 在 `MPV_EVENT_FILE_LOADED` 时扫描，`try_next_video_track()` 在 EOF 时自动切换到下一轨道，实现连续播放。

## 扩展指南

### 添加新的视频格式

无需修改代码 — mpv/ffmpeg 处理所有解码。如需在文件选择器中显示更多类型，修改 `ContentView.swift` 中的 `videoTypes`。

### 添加新的立体布局

1. `VideoPlayerModel.swift` 的 `SourceLayout` enum 添加新 case
2. `Shaders.metal` 的 `projectionFragment` 添加对应 UV 映射分支
3. `ContentView.swift` 的 `sourceSegments` 添加 UI 按钮

### 添加键盘快捷键

在 `ContentView.swift` 的 `KeyboardShortcuts` ViewModifier 中用 `.onKeyPress()` 添加。

### 调试

- 日志文件：`~/Library/Logs/GlassesPlayer/GlassesPlayer_*.log`
- 设置面板 → Advanced → "Open Log Directory" 快速打开
- 构建时 `MPVPlayer.c` 中的 `mpv_log()` 输出到日志文件
- mpv 自身日志级别设为 `all=error`（可通过修改 `msg-level` 调整）
