# Lives 产品网站

[![Release smoke](https://github.com/ohmyangboy/lives/actions/workflows/release-smoke.yml/badge.svg)](https://github.com/ohmyangboy/lives/actions/workflows/release-smoke.yml)

纯静态、无第三方运行时依赖的产品介绍站。构建脚本会把 `src/` 复制到 `dist/`，并注入版本号和下载链接。

## 本地构建

```bash
npm run build
python3 -m http.server 4173 --directory dist
```

可选环境变量：

- `LIVES_VERSION`：公开版本号，默认 `0.1.0`。
- `LIVES_DOWNLOAD_URL`：下载按钮地址，默认指向本仓库的 latest GitHub Release 页面。

## GitHub Pages

此目录会作为独立的公开网站仓库发布；`.github/workflows/pages.yml` 会在网站仓库 `main` 分支变更后构建并部署。首次使用需在 GitHub 仓库的 **Settings → Pages → Build and deployment** 中将 Source 设为 **GitHub Actions**。

推荐在仓库 **Settings → Secrets and variables → Actions → Variables** 添加：

- `LIVES_VERSION=0.1.0`
- `LIVES_DOWNLOAD_URL=<DMG 的 GitHub Release 下载地址或 Release 页面>`

发布前务必确认下载页中提供的 DMG 与网站版本一致，并同时公布 SHA-256。
