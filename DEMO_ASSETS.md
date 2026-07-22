# Lives 官网演示素材说明

官网中的产品截图和操作演示均来自真实 Lives 开发版界面，但只导入公开测试视频。仓库不保存这些源视频，只保存由应用窗口生成的截图和无声演示视频。

## 当前素材来源

| 用途 | 作者 | 来源 | 页面标注 |
| --- | --- | --- | --- |
| 夜景画格 | Mustapha ELKHOMSY | [Video of a City at Night](https://www.pexels.com/video/video-of-a-city-at-night-6412356/) | Free to use |
| 狗狗画格 | Coverr | [Walking With the Dog at the Park](https://www.pexels.com/video/walking-with-the-dog-at-the-park-853810/) | Free to use (CC0) |
| 骑行画格 | Alin Serban | [Running](https://www.pexels.com/video/running-20207603/) | Free to use |

使用或重新制作官网演示前，应再次打开来源页面，确认素材仍可使用，并遵守 [Pexels License](https://www.pexels.com/license/)。不要从来源页面移除作者信息后把源视频当作 Lives 自有素材重新分发。

## 脱敏规则

重新录制官网演示时必须同时满足：

1. 只录制 Lives 单个应用窗口，不录制整块桌面；
2. 不显示通知、菜单栏账号、浏览器、终端、编辑器或访达侧边栏；
3. 项目名和素材文件名只能使用公开测试名称；
4. 不显示用户视频、私人照片、真实目录路径、Apple ID、邮箱或其他身份信息；
5. 录制完成后逐帧抽查，再把最终截图和无声视频放入 `src/assets/`；
6. 任何误录的原始文件必须立即删除，不得进入 Git 历史。

## 已提交产物

- `src/assets/lives-editor-home.jpg`：真实 Lives 完整编辑界面截图；
- `src/assets/lives-feature-*.jpg`：经用户确认的标准功能区域截图；
- `src/assets/lives-demo.mp4`：真实 Lives 窗口操作演示，无音轨。

如果替换了测试素材或重新录制，请同步更新本文件和官网中的来源链接。
