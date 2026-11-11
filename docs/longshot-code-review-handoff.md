# 长截图代码复查与待办交接

> 用途：给下一次会话直接接手用。范围是「长截图（FR-14）」实现后的代码复查结论与待修项，不含 P3 功能。
> 基线：v0.3.0（tag `v0.3.0` → `d2cfd1d`）；本交接文档提交 `e364911`。复查轮次未改任何产品代码。

## 结论摘要

核心拼接算法是健康的：73 个断言全绿，受控窗口以 120.5px 平滑滚动可完整拼接（700×1765，BAND 连续、头部仅一次），抓屏排除自身也实测通过。普通截图 / OCR / 贴图路径未受影响。

但存在 1 个高风险的匹配脆弱点、1 个性能风险、1 个生命周期缺口，以及若干死代码与边界问题。建议按下列顺序处理。

## 复现与验证环境

```bash
./scripts/run-tests.sh          # 73 断言
./scripts/build-app.sh          # 编译 + 组装 + 签名，产物 dist/iCut.app
open dist/iCut.app              # 必须从 .app 启动（TCC 身份）
```

临时探针（`tmp/` 不入库，可随时重建）：

- `tmp/verify/ui/main.swift`：受控窗口端到端（固定头部 + 可滚正文 + 右侧滚动条；步长 120.5px 模拟平滑滚动），输出 `tmp/verify/e2e-longshot.png`
- `tmp/verify/perf/main.swift`：指纹提取与最坏匹配耗时
- `tmp/verify/anchor/main.swift`：锚点行脆弱性验证
- `tmp/verify/analyze/main.swift`：读取调试帧（`~/Library/Caches/longshot-debug/`）做错位扫描

调试抓帧开关（默认关）：

```bash
defaults write com.icut.app debug.longCaptureDump -bool YES
```

## P1（建议先修）

### P1-1 匹配依赖单行锚点，末行异常会导致整帧丢弃

- 定位：`src/iCut/Core/RollingStitcher.swift` → `match()` 用 `existing.last` 过滤候选
- 现象：把已拼接内容的最后一行替换为异常值后，`findOverlap` 直接返回 `nil`（已用 `tmp/verify/anchor` 实证；正常情况下能匹配 300 行重叠）
- 影响：某帧底边一行被浮层遮挡、光标闪烁或动画覆盖时，出现「明明在滚却提示未找到重叠区域」
- 建议：容忍档不再依赖单行锚点——改为「采样 8~16 行做预筛 + 命中后整段核对」，或对多个候选锚点（如末行、末行前 N 行）依次尝试
- 验收：`anchor` 探针在末行异常时仍能返回正确重叠；73 断言保持全绿；E2E 探针通过
- 备注：严格档可以保留锚点，容忍档必须去掉

### P1-2 大选区主线程开销导致掉帧

- 定位：`src/iCut/Feature/LongCapture/LongCaptureController.swift` → `tick()` 在主线程做 `rowSignatures` + `findOverlap`
- 实测（最坏情况，完全无重叠）：

  | 选区 | 指纹提取 | 最坏匹配 |
  | --- | --- | --- |
  | 725×562 | 3.7 ms | 5.6 ms |
  | 1400×900 | 13.1 ms | 24.0 ms |
  | 2800×1800 | 48.9 ms | 65.4 ms |

- 影响：Retina 全屏选区单帧 ~114ms，而定时器间隔 150ms，`isTicking` 会丢帧，滚动越快越容易漏拼
- 建议（二选一或组合）：
  1. 把「抓帧 + 指纹」放到后台串行队列，主线程只更新面板（`CGWindowListCreateImage` 线程安全）
  2. 大图先按 1/2 降采样再算指纹（行分辨率仍足够定位）
- 验收：2800×1800 单帧总耗时降到 < 40ms；E2E 探针步进滚动仍能完整拼接

### P1-3 缺少屏幕参数变化处理

- 定位：`LongCaptureController` 没有监听 `NSApplication.didChangeScreenParametersNotification`；冻结路径有（`SelectionOverlayController`）
- 影响：拔插显示器或改分辨率后 `quartzRect` 失效，持续抓帧失败
- 建议：监听通知后结束会话并提示「屏幕变化，长截图已取消」，同时恢复被隐藏的贴图
- 验收：模拟拔屏（或改分辨率）时会话安全结束，无残留面板 / 蓝框

## P2（边界与体验）

### P2-1 帧宽必须严格相等

- 定位：`src/iCut/Core/StitchAccumulator.swift` → `guard image.width == width`
- 问题：任一帧宽差 1px 就返回「画面尺寸变化」并永久跳过，会话卡死
- 建议：允许 ±2px，按首帧宽度裁齐

### P2-2 高度上限按整帧拒绝

- 定位：`StitchAccumulator.append` → `guard height + added <= maxHeight`
- 问题：永远到不了 20000px（差一帧就整帧丢弃）；面板提示文案硬编码「20000px」，与 `maxHeight` 参数脱耦
- 建议：裁到剩余容量；文案用注入的 `maxHeight`

### P2-3 底部固定悬浮条未处理（已结案，仅记录）

- 现象：顶部粘性导航已处理（`skipRows`），底部固定条（页脚、悬浮客服按钮）会重复拼进长图
- 状态：Kevin 已于 2026-11-12 决定结案不处理（见 `_pm/track/roadmap.md`「已知限制」），本项仅作记录，不列入修复范围

### P2-4 抓帧失败日志无节流

- 定位：`LongCaptureController.tick()` → 失败时每 0.15s 一条 `NSLog`
- 建议：每秒最多一条，面板状态保留

### P2-5 Esc / 回车是死代码

- 定位：`src/iCut/Feature/LongCapture/LongCapturePanel.swift` → `keyDown`、`canBecomeKey`
- 问题：面板 `becomesKeyOnlyIfNeeded = true` 且无输入控件，永远不会成为 key window，`keyDown` 走不到
- 建议：要么点击面板时 `makeKey`（让 Esc/回车生效），要么删掉这段；二选一并同步 README

### P2-6 `.longShot` 仍走 `crop()`

- 定位：`src/iCut/Feature/Capture/SelectionOverlayController.swift` → 所有 outcome 统一先 `crop(...)`
- 问题：长截图只用 frame/rect，却把标注渲染成一张用不到的整图；裁切失败还会直接取消长截图
- 建议：`.longShot` 分支跳过 `crop`，直接回传 frame/rect

### P2-7 焦点恢复有缺口

- 定位：`src/iCut/App/AppDelegate.swift` → `appBeforeCapture`
- 问题：从菜单触发时 frontmost 可能是 iCut 自己，会沿用旧值；目标 App 已退出时 `activate` 失败且不回退
- 建议：记录时过滤自身；恢复失败时回退 `NSApp.deactivate()`；目标已终止则跳过

### P2-8 调试落盘代码留在产品里

- 定位：`LongCaptureController.dumpDebugFrame`（默认关，仅写 `~/Library/Caches/longshot-debug/`）
- 建议：保留但在 README「调试」段说明，或后续收敛到内部构建

## P3（整洁度，可随时顺手）

- `RollingStitcher.quantizationShift = 0` 是无效参数，可删
- 测试注释仍称「行哈希」，与「块平均指纹」实现有轻微漂移
- `tmp/verify` 下 4 个探针与 `build/` 产物都是临时资产，不入库

## 建议顺序与拆分（对应 WBS F-23）

1. P1-1 锚点（改动最小、风险最高）
2. P1-2 性能（可能与 P1-1 同批改 `RollingStitcher`）
3. P1-3 屏幕变化
4. P2-1 / P2-2 边界
5. P2-4 日志、P2-5 死代码、P2-6 crop、P2-7 焦点
6. P2-3 已结案（不处理）；P2-8 文档说明、P3 清理

## 改动时必须守住的约束

- 不要回退成「整行精确哈希」：触控板平滑滚动会产生亚像素偏移，精确哈希会重演「怎么滚都不动」
- 不要移除粘性头部跳过（`maxStickyRows`）与左右边缘避让（滚动条）
- 每步都要跑：`./scripts/run-tests.sh`、`./scripts/build-app.sh`、受控 E2E 探针（120.5px 步进），并记录到 `_pm/track/checklist.md` 新增的 L 系列条目
- 改完更新：`_pm/track/wbs.md` 状态、`_pm/track/roadmap.md`、`_pm/log/changelog.md`、`_pm/log/contents.md`
