# Project website / 项目主页

The bilingual project website is a buildless static site in `site/`. It uses
relative asset paths so it works at the GitHub Pages project path `/CATunnel/`.
The app, local settings, SSH connections, and Swift build are independent of it.

中英文主页位于 `site/`，使用原生 HTML、CSS 和 JavaScript，无需 npm 构建。
`?lang=zh` 与 `?lang=en` 可分享指定语言；语言偏好保存在浏览器本地，
禁用本地存储时仍可切换。不添加分析、遥测、第三方字体或运行时依赖。

## Preview and check

From the repository root:

```bash
python3 scripts/check-site.py
python3 -m http.server 8000 --bind 127.0.0.1 --directory site
```

Open `http://127.0.0.1:8000/`. Browser QA should also cover the `/CATunnel/` base
path, both languages, 320px and desktop layouts, mobile navigation, screenshot
dialogs, copy success/fallback, and disabled JavaScript/local storage. No-JS
visitors retain the Chinese content, navigation, screenshots and download links.

With an existing Playwright Python installation and its Chromium browser, run
the reusable interaction checks against that preview:

```bash
python3 scripts/check-site-browser.py --url http://127.0.0.1:8000/ \
  --output verification/homepage-browser
```

These browser checks cover the request/response animation, playback controls,
language switching, offscreen pausing, reduced motion, responsive layouts and
the existing screenshot/copy controls. Document visibility is simulated in the
test; it does not put the Mac to sleep or touch application connections.

The static check uses only Python's standard library. It verifies local resources
and fragments, responsive image candidates, image loading hints, translation
attributes, WebP integrity and byte budgets. It never contacts public websites.

## Image preparation

Original artwork and offline screenshots remain in `docs/assets/`. The site
loads only the derived WebP assets in `site/assets/images/`.

```bash
# Requires Pillow with WebP support, only when regenerating images.
python3 scripts/prepare-site-images.py
python3 scripts/check-site.py
```

- Cover: 640, 1280 and 1920px variants; WebP quality 82.
- The cover is centered and displayed at no more than 1000 CSS pixels wide;
  `sizes` matches that layout, including the smaller margins on mobile.
- Screenshots: lossless WebP, preserving transparency and source ICC profiles.
- Every image declares dimensions. The cover uses `fetchpriority="high"`;
  screenshots use `loading="lazy"` and `decoding="async"`.
- `srcset` and `sizes` let the browser choose a variant for the viewport and pixel
  density. High-density phones can legitimately request the 1280px cover.
- The enlarged image is requested only when its dialog opens. No third-party
  image hosting or CDN script is required.
- `manifest.json` records source/derived hashes, dimensions, encoders and bytes.
  Regeneration with another encoder version may change the file hashes; commit
  the regenerated manifest together with its assets.

Measured for the initial website assets: the original cover is 3,489,642 bytes;
the 1280px variant is 193,360 bytes (94.46% smaller), and the 640px variant is
52,580 bytes. These are file-size comparisons, not guarantees about load time on
a particular network. GitHub Pages controls its HTTP caching; a `_headers` file
would not configure Pages response headers.

图片优化不覆盖原 PNG。优先加载封面、延迟加载下方截图；不要将 `loading="lazy"`
用于首屏主图，也不要重新引入外部字体、追踪脚本或原始多 MB 封面。

## Traffic illustration / 工作原理动画

The inline SVG/CSS illustration follows one request to the destination and its
response back to the remote tool in nine steps. It represents traffic over an
already-established connection, not the direction of SSH setup. The Mac starts
SSH. No network probe or actual model request runs from this illustration.

Playback pauses when the diagram leaves the viewport or the document is hidden.
Pause preserves the current step; Next step pauses automatic playback; Replay
starts again at the remote tool. Language changes retain the current step.
With `prefers-reduced-motion`, initial autoplay and packet movement are disabled;
manual steps and an explicit Play action remain available. Without JavaScript,
the static five-node route and its explanatory caption remain readable.

动画用两种颜色展示请求和响应，并同步中英文步骤说明。支持暂停、单步和重新播放；
离屏自动暂停，遵循系统“减少动态效果”偏好，不增加动画库或外部资源。

## GitHub Pages

`.github/workflows/pages.yml` checks pull requests and publishes `site/` for
matching changes pushed to `main`, or a manual dispatch on `main`. PRs never
deploy. Only the deployment job receives Pages/OIDC write permissions. The
existing macOS validation workflow is unchanged.

The repository's Pages source must be **GitHub Actions**. No custom domain is
configured. The intended URL is `https://yusenhou519.github.io/CATunnel/`.

Keep release claims accurate: preview download links target a specific tag and
architecture. Current-source features are labelled separately; update both
languages and the links when a new public release actually includes them.

更新内容时同时维护两种语言，并保持“公开预览下载包”与“当前源码功能”的区别。
界面截图只使用仓库内的离线示例，避免上传真实主机、地址或账号信息。
