# 官方应用与工具图标

应用图标从本机相应 `.app/Contents/Resources/*.icns` 提取，仅缩放为 PNG；不重绘、不改变颜色和比例。Web 素材来自工具官方项目。来源、应用包标识、提取时版本与产物 SHA-256 记录在 [sources.json](sources.json)。运行时离线加载，不向图标网站发起请求。

- Maven：[Apache Maven](https://maven.apache.org/)，Apache Software Foundation 的项目标识。
- uv：[astral-sh/uv](https://github.com/astral-sh/uv) 官方站点素材。
- pnpm：[pnpm/pnpm.io](https://github.com/pnpm/pnpm.io) 官方站点素材。
- npm：[npm/logos](https://github.com/npm/logos) 官方方形标识，遵循其商标和留白要求。
- GitHub CLI：使用 [Primer Octicons](https://github.com/primer/octicons) 的官方 GitHub mark，按主题使用单色版本。
- IDE、Android Studio、Xcode / Device Hub、Bruno、Reqable、mitmproxy 等使用其安装包原有图标。

版权和商标仍归各权利人；这些素材不适用本仓库代码的 MIT 授权。它们用于识别本机工具，不表示获得官方背书。未收录独立标识的条目显示通用工具图形，不冒充其官方商标。语言运行时的素材及授权见 [toolchains](../toolchains/README.md)。
