# Lives MVP

Lives 是一个 macOS 本地工具：从多个 MOV/MP4/M4V 素材中截取不同的 3 秒瞬间，拼贴为一张 Live Photo，并保存到 Apple“照片”或指定文件夹。

当前版本为 `0.1.13`，处于内部测试阶段。完整的产品范围、实现状态、验收门槛和技术约束请从 [docs/项目文档](docs/项目文档/README.md) 开始阅读：

- [PRD](docs/项目文档/PRD-MVP.md)
- [开发计划与验收清单](docs/项目文档/开发计划与验收清单.md)
- [技术现状与架构](docs/项目文档/技术现状与架构.md)

## 开发运行

需要 Xcode、Node.js 和 Rust。首次安装依赖后：

```bash
npm install
npm run tauri:dev
```

网页预览：

```bash
npm run dev
```

测试与构建：

```bash
npm test
swift test --package-path native/LivePhotoService
npm run tauri:build
```

## 真机验收与发布

代码级自动测试不能替代平台链路验证。当前的历史验收记录在 [docs/真机验收记录.md](docs/真机验收记录.md)，新的发布检查以 [开发计划与验收清单](docs/项目文档/开发计划与验收清单.md) 为准。

当前构建使用 ad-hoc 签名，未配置 Developer ID、公证或正式自动更新，仅适合本机开发与内部测试。官网分发和正式发布要求见 [PRD 的待决策项](docs/项目文档/PRD-MVP.md#6-待决策项)。
