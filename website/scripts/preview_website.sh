#!/usr/bin/env bash
# Lives 官网本地预览与断点边界查看。
#
# 构建 website/dist → 启动本地静态服务 → 自动打开浏览器；
# --shots 模式下额外在样式断点（540px / 720px / 900px）两侧宽度截图，
# 并检查是否有元素真正越过视口左右边界，最后生成图集。
#
# 用法（仓库根目录执行）：
#   website/scripts/preview_website.sh                     # 预览（默认 8000 端口，被占用自动递补）
#   website/scripts/preview_website.sh 8010                # 指定起始端口
#   website/scripts/preview_website.sh --shots             # 断点边界截图 + 越界报告 + 图集
#   website/scripts/preview_website.sh --shots --widths 390,900,901 --scale 2
#   website/scripts/preview_website.sh --no-build          # 直接预览现有 website/dist
#   CHROME_BIN="/path/to/chrome" website/scripts/preview_website.sh --shots
#
# 风格对齐 PaperRss 的 scripts/preview_website.sh：单文件 sh + 内联 Python 静态服务。
# 截图与图集位于 .local/website-preview/（本地状态，不进入版本库）。
# 注意：本机 Chrome 无头模式使用全新 --user-data-dir 会挂起，因此复用默认 profile，
# 并用 host-resolver-rules 屏蔽外部请求（GitHub star 接口等），保证截图稳定快速。
set -eo pipefail

CDPATH= cd "$(dirname "$0")/../.."

DIST_DIR="website/dist"
OUT_DIR="$PWD/.local/website-preview"
PORT=8000
BUILD=1
SHOTS=0
OPEN=1
WIDTHS="320,390,540,541,720,721,768,900,901,1280,1440"
HEIGHT=3600
SCALE=1
CHROME_TIMEOUT=45

usage() {
    cat <<'HELP'
用法：website/scripts/preview_website.sh [端口] [选项]

  端口                起始端口，默认 8000，被占用时自动 +1
  --shots             断点边界截图 + 越界报告 + 图集
  --widths <列表>     截图宽度，逗号分隔，默认 320,390,540,541,720,721,768,900,901,1280,1440
  --height <像素>     截图视口高度，默认 3600
  --scale <倍数>      设备像素比，默认 1（2 生成 2x 图）
  --no-build          跳过构建，直接预览现有 website/dist
  --no-open           不自动打开浏览器 / 图集
  --help              显示本说明
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --shots) SHOTS=1 ;;
        --no-build) BUILD=0 ;;
        --no-open) OPEN=0 ;;
        --widths) WIDTHS="$2"; shift ;;
        --height) HEIGHT="$2"; shift ;;
        --scale) SCALE="$2"; shift ;;
        --help|-h) usage; exit 0 ;;
        [0-9]*) PORT="$1" ;;
        *) echo "❌ 未知参数：$1（--help 查看用法）"; exit 1 ;;
    esac
    shift
done

case "$WIDTHS" in
    *[!0-9,]*) echo "❌ 宽度列表只支持数字与逗号：$WIDTHS"; exit 1 ;;
esac
case "$HEIGHT$SCALE" in
    *[!0-9.]*) echo "❌ 高度与缩放只支持数字：$HEIGHT / $SCALE"; exit 1 ;;
esac

find_chrome() {
    for candidate in "${CHROME_BIN:-}" \
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
        "/Applications/Chromium.app/Contents/MacOS/Chromium" \
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    for name in google-chrome chromium chromium-browser microsoft-edge brave-browser; do
        if command -v "$name" >/dev/null 2>&1; then
            command -v "$name"
            return 0
        fi
    done
    echo "❌ 未找到 Chrome / Chromium：安装浏览器或设置 CHROME_BIN 指向可执行文件" >&2
    return 1
}

if [ "$BUILD" = 1 ] || [ ! -f "$DIST_DIR/index.html" ]; then
    echo "🔨 正在构建官网..."
    node website/scripts/build.mjs
fi

mkdir -p "$OUT_DIR"
PORT_FILE="$OUT_DIR/.port"
rm -f "$PORT_FILE"

# 静态服务：同源提供 harness 页面（用于测量越界），其余请求回落到 website/dist
python3 - "$PORT" "$DIST_DIR" "$PORT_FILE" <<'PY' &
import http.server
import socketserver
import sys
from urllib.parse import urlparse

port = int(sys.argv[1])
directory = sys.argv[2]
port_file = sys.argv[3]

HARNESS = r"""<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="utf-8" />
    <title>Lives 官网边界检测</title>
    <style>
      html, body { margin: 0; overflow: hidden; background: #0e0d0b; }
      iframe { display: block; border: 0; }
    </style>
  </head>
  <body>
    <iframe id="frame" title="Lives 官网预览"></iframe>
    <script>
      const params = new URLSearchParams(location.search)
      const width = Number(params.get('width') || '1440')
      const frame = document.getElementById('frame')
      frame.style.width = width + 'px'
      // 超高 iframe 让整个页面都处于“视口”内：懒加载图片全部加载，且页面无可滚动区域
      frame.style.height = '20000px'
      frame.addEventListener('load', () => {
        const doc = frame.contentDocument
        if (!doc.body || doc.body.children.length === 0) return
        const win = frame.contentWindow
        let worst = null
        const measure = () => {
          const html = doc.documentElement
          const body = doc.body
          const clipped = (element) => {
            let node = element.parentElement
            while (node && node !== body) {
              if (win.getComputedStyle(node).overflowX !== 'visible') return true
              node = node.parentElement
            }
            return false
          }
          const offenders = []
          for (const element of body.querySelectorAll('*')) {
            const rect = element.getBoundingClientRect()
            if (rect.width < 1 || rect.height < 1) continue
            if (rect.left >= -1 && rect.right <= width + 1) continue
            if (clipped(element)) continue
            const className = String(element.className || '').replace(/[^\w.-]+/g, '_')
            offenders.push(element.tagName.toLowerCase() + '.' + className +
              '(' + Math.round(rect.left) + ',' + Math.round(rect.right) + ')')
          }
          const overflowX = Math.max(html.scrollWidth, body.scrollWidth) - html.clientWidth
          // 保留多次测量中最差的一次：懒加载图片在 load 前后可能触发不同的布局
          if (!worst || overflowX > worst.overflowX ||
            (overflowX === worst.overflowX && offenders.length > worst.offenders.length)) {
            worst = { overflowX, offenders }
          }
          document.title = 'REPORT ' + worst.overflowX + ' ' + worst.offenders.length + ' ' +
            worst.offenders.slice(0, 5).join(' ')
        }
        // 懒加载图片在 load 之后才完成布局，会触发 min-content 撑开：先给即时报告，再等图片稳定复测
        measure()
        const deadline = Date.now() + 5000
        const settle = () => {
          const pending = Array.from(doc.images).filter((image) => !image.complete)
          if (pending.length > 0 && Date.now() < deadline) {
            setTimeout(settle, 50)
          } else {
            measure()
          }
        }
        setTimeout(settle, 50)
      })
      frame.src = '/'
    </script>
  </body>
</html>"""


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self):
        # 本地预览禁用缓存，避免 Chrome 复用上一次的样式/脚本
        if not getattr(self, 'sent_no_store', False):
            self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def send_html(self, body):
        self.sent_no_store = True
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlparse(self.path).path == '/__preview_harness.html':
            self.send_html(HARNESS.encode('utf-8'))
            return
        super().do_GET()

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    # 无头浏览器会并发拉取整页资源，默认 backlog 5 会导致部分请求被拒
    request_queue_size = 128


while True:
    try:
        httpd = Server(('127.0.0.1', port), Handler)
        break
    except OSError:
        port += 1

with open(port_file, 'w') as handle:
    handle.write(str(port))

httpd.serve_forever()
PY
SERVER_PID=$!

cleanup() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        echo ""
        echo "🛑 预览服务已关闭"
    fi
}
trap cleanup EXIT

for _ in $(seq 1 100); do
    if [ -s "$PORT_FILE" ]; then
        break
    fi
    sleep 0.1
done
if [ ! -s "$PORT_FILE" ]; then
    echo "❌ 本地服务启动失败"
    exit 1
fi
PORT=$(cat "$PORT_FILE")
BASE="http://127.0.0.1:$PORT"

if [ "$SHOTS" = 0 ]; then
    echo "🚀 正在启动 website 静态服务器..."
    echo "📍 预览地址：$BASE"
    echo "📂 网站目录：$DIST_DIR"
    echo "💡 按 Ctrl+C 结束预览"
    if [ "$OPEN" = 1 ]; then
        open "$BASE" 2>/dev/null || true
    fi
    wait "$SERVER_PID"
    exit 0
fi

# --shots：断点边界截图与越界查看
CHROME=$(find_chrome)
GALLERY="$OUT_DIR/index.html"
{
    echo '<!doctype html>'
    echo '<html lang="zh-CN">'
    echo '  <head>'
    echo '    <meta charset="utf-8" />'
    echo '    <title>Lives 官网边界预览</title>'
    echo '    <style>'
    echo '      :root { color-scheme: dark; }'
    echo '      body { margin: 0; padding: 2.5rem 2rem 4rem; background: #0e0d0b; color: #f5f2eb; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; }'
    echo '      h1 { font-size: 1.2rem; margin: 0 0 0.4rem; }'
    echo '      p.lede { color: #a39e93; font-size: 0.85rem; margin: 0 0 2.25rem; }'
    echo '      figure { margin: 0 0 2.75rem; }'
    echo '      figcaption { font-family: ui-monospace, Menlo, monospace; font-size: 0.78rem; letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 0.6rem; }'
    echo '      .ok { color: #79bf91; }'
    echo '      .bad { color: #ff9f6e; }'
    echo '      img { display: block; max-width: 100%; border: 1px solid rgba(245, 242, 235, 0.12); border-radius: 10px; }'
    echo '    </style>'
    echo '  </head>'
    echo '  <body>'
    echo '    <h1>Lives 官网边界预览</h1>'
    echo "    <p class=\"lede\">断点：540 / 720 / 900px · 缩放 ${SCALE}x · 视口高度 ${HEIGHT}px</p>"
} > "$GALLERY"

CHROME_FLAGS=(
    --headless=new
    --incognito
    --disable-gpu
    --hide-scrollbars
    --no-first-run
    --no-default-browser-check
    --disable-extensions
    --disable-background-networking
    --disable-component-update
    --disable-sync
    --mute-audio
    --force-prefers-reduced-motion
    "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1"
)

# 带看门狗执行 Chrome：卡住时强杀，避免外部请求拖住整个脚本
run_chrome() {
    local timeout_seconds="$1"
    local output="$2"
    shift 2
    "$CHROME" "${CHROME_FLAGS[@]}" "$@" >"$output" 2>/dev/null &
    local chrome_pid=$!
    local waited=0
    while kill -0 "$chrome_pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout_seconds" ]; then
            kill -9 "$chrome_pid" 2>/dev/null || true
            wait "$chrome_pid" 2>/dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$chrome_pid"
}

# 无头 Chrome 偶尔会卡住，失败时重试一次
run_chrome_retry() {
    if run_chrome "$@"; then
        return 0
    fi
    echo "  ⚠️ Chrome 首次失败，重试一次..." >&2
    run_chrome "$@"
}

echo "📸 边界查看：断点 540 / 720 / 900px，宽度 ${WIDTHS}，缩放 ${SCALE}x"
FAILED=0
for width in ${WIDTHS//,/ }; do
    printf '→ %-6s ' "${width}px"
    DOM_FILE="$OUT_DIR/.dom-${width}.html"
    SHOT_FILE="$OUT_DIR/w${width}.png"

    # 一次 Chrome 调用同时取得越界报告（DOM）与整页截图，避免多实例互相干扰
    if ! run_chrome_retry "$CHROME_TIMEOUT" "$DOM_FILE" \
        "--window-size=$width,$HEIGHT" \
        "--force-device-scale-factor=$SCALE" \
        --run-all-compositor-stages-before-draw \
        --virtual-time-budget=8000 \
        "--screenshot=$SHOT_FILE" \
        --dump-dom \
        "$BASE/__preview_harness.html?width=$width"; then
        echo "⚠️ 边界报告与截图失败（Chrome 超时或异常）"
        FAILED=1
        echo "        <figure><figcaption><span class=\"bad\">${width}px · 边界报告失败</span></figcaption></figure>" >> "$GALLERY"
        continue
    fi

    REPORT_LINE=$(sed -n 's#.*<title>REPORT \([^<]*\)</title>.*#\1#p' "$DOM_FILE" | head -1)
    rm -f "$DOM_FILE"

    if [ -z "$REPORT_LINE" ]; then
        echo "⚠️ 未能取得边界报告"
        FAILED=1
        echo "        <figure><figcaption><span class=\"bad\">${width}px · 边界报告缺失</span></figcaption></figure>" >> "$GALLERY"
        continue
    fi

    read -r OVERFLOW COUNT DETAILS <<<"$REPORT_LINE"

    if [ "$OVERFLOW" -gt 0 ] || [ "$COUNT" -gt 0 ]; then
        echo "溢出 ${OVERFLOW}px · 越界 ${COUNT} 个 ${DETAILS}"
        FAILED=1
        echo "        <figure><figcaption><span class=\"bad\">${width}px · 横向溢出 ${OVERFLOW}px，越界 ${COUNT} 个</span></figcaption><img src=\"w${width}.png\" alt=\"${width}px 视口下的 Lives 官网\" /></figure>" >> "$GALLERY"
    else
        echo "无横向溢出"
        echo "        <figure><figcaption><span class=\"ok\">${width}px · 无横向溢出</span></figcaption><img src=\"w${width}.png\" alt=\"${width}px 视口下的 Lives 官网\" /></figure>" >> "$GALLERY"
    fi
done

{
    echo '  </body>'
    echo '</html>'
} >> "$GALLERY"

kill "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo ""
if [ "$FAILED" = 0 ]; then
    echo "✅ 边界查看完成：所有宽度均未越界"
else
    echo "⚠️ 边界查看完成：存在越界或报告失败，详见上方明细"
fi
echo "🖼️ 图集：$GALLERY"
if [ "$OPEN" = 1 ]; then
    open "$GALLERY" 2>/dev/null || true
fi

[ "$FAILED" = 0 ]
