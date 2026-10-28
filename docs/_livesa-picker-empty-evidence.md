# 现场补充（2026-10-27 20:48，用户新截图）

路径：`/Users/yangbukun/Desktop/code/lives-workspace/_livesa-qa/photos-picker-empty.png` 与 `/tmp/livesa-photos-picker-empty.png`

现象：Helper 窗口标题「从照片添加...」；内容为空态文案「选择最多 10 张照片。」+ 按钮「选择照片」+ 搜索，没有 Live 缩略图网格。像是 PHPicker/有限访问空态或窗口事件未跑起来导致选择器未真正展开，而不是主 App loading  alone。

请在当前修复（AppKit 事件循环 / 授权异步 / 取消与超时）基础上一并覆盖：
- 有限相册授权时的引导（点「选择照片」扩展权限或明确提示）
- 过滤器 `.livePhotos` 在空库/有限库下的空态文案
- 自验：授权→可见可用的选择器→能选 Live→导入结束清 loading；取消/超时不卡死
