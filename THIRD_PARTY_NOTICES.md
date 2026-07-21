# Lives 第三方软件声明

Lives 0.1.0 包含或依赖以下主要开源组件。应用本身及 Lives 品牌素材不因这些声明而开放源代码；除第三方许可另有规定外，Copyright © 2026 杨不困，保留所有权利。

| 组件 | 版本 | 许可 | 项目 |
| --- | --- | --- | --- |
| React / React DOM | 19.2.7 | MIT | https://github.com/facebook/react |
| Tauri JavaScript API | 2.11.1 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri | 2.11.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri Dialog Plugin | 2.7.2 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Tauri Shell Plugin | 2.3.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Serde | 1.0.229 | MIT / Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.150 | MIT / Apache-2.0 | https://github.com/serde-rs/json |

构建时使用的完整依赖版本由 `package-lock.json`、`src-tauri/Cargo.lock` 和 Swift Package 清单固定。后续加入或升级依赖时，应同步更新本文件并复核其再分发条件。

## MIT License

Copyright notices belong to the respective upstream authors and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Apache-2.0 的完整条款见：https://www.apache.org/licenses/LICENSE-2.0
