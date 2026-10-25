#!/usr/bin/env python3
"""Generate the animated README artwork (light and dark) as plain SVG.

GitHub shows repository SVGs as images: no scripts run, but CSS animations
inside the file play. Every picture is written twice, *-light.svg and
*-dark.svg, and the README picks one with <picture> + prefers-color-scheme.

    python3 docs/media/readme/make_readme_art.py

Text uses the reader's system font (SF / PingFang on Apple devices, YaHei on
Windows). All example sentences are invented; none comes from a real dictation.
"""
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent
FONT = ("-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'PingFang SC', "
        "'Hiragino Sans GB', 'Microsoft YaHei', 'Helvetica Neue', Arial, sans-serif")

THEMES = {
    "light": dict(ink="#1d1d1f", gray="#6e6e73", faint="#a1a1a6", card="#f5f5f7", card2="#ffffff",
                  line="#e5e5ea", blue="#0071e3", green="#248a3d", red="#ff3b30", icon="#111111",
                  iconEdge="#111111", pill="#2b2b2b", pillInk="#ffffff", glow="#0071e3"),
    "dark": dict(ink="#f5f5f7", gray="#a1a1a6", faint="#6e6e73", card="#1c1c1e", card2="#2c2c2e",
                 line="#3a3a3c", blue="#2997ff", green="#30d158", red="#ff453a", icon="#111111",
                 iconEdge="#48484a", pill="#3a3a3c", pillInk="#ffffff", glow="#2997ff"),
}

BASE_CSS = """
text { font-family: %(font)s; }
.ink { fill: %(ink)s; } .gray { fill: %(gray)s; } .faint { fill: %(faint)s; }
.blue { fill: %(blue)s; } .green { fill: %(green)s; }
.grow { transform-box: fill-box; transform-origin: center; }
.left { transform-box: fill-box; transform-origin: left center; }
@media (prefers-reduced-motion: reduce) { * { animation: none !important; } }
"""


def svg(width, height, body, css, t, label):
    style = BASE_CSS % dict(t, font=FONT) + css
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(label)}">\n'
            f'<title>{escape(label)}</title>\n<style>{style}</style>\n{body}\n</svg>\n')


def text(x, y, s, size, cls="ink", weight=400, anchor="start", extra=""):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" '
            f'text-anchor="{anchor}" class="{cls}" {extra}>{escape(s)}</text>')


def icon_bars(cx, cy, scale, color, animated, prefix="bar"):
    """The app mark: seven rounded bars, tallest in the middle."""
    heights = [0.30, 0.52, 0.74, 0.92, 0.74, 0.52, 0.30]
    width, gap, full = 7 * scale, 11.6 * scale, 58 * scale
    out = []
    for i, h in enumerate(heights):
        x = cx + (i - 3) * gap - width / 2
        hh = full * h
        cls = f'grow {prefix}{i}' if animated else ''
        out.append(f'<rect class="{cls}" x="{x:.1f}" y="{cy - hh / 2:.1f}" width="{width:.1f}" '
                   f'height="{hh:.1f}" rx="{width / 2:.1f}" fill="{color}"/>')
    return "\n".join(out)


def bar_css(prefix, period, low=0.42):
    css = []
    for i in range(7):
        delay = -(i * 0.13 + (0.35 if i % 2 else 0))
        css.append(f'.{prefix}{i} {{ animation: {prefix}Pulse {period}s ease-in-out {delay:.2f}s infinite; }}')
    css.append(f'@keyframes {prefix}Pulse {{ 0%,100% {{ transform: scaleY(1); }} 50% {{ transform: scaleY({low}); }} }}')
    return "\n".join(css)


# ---------------------------------------------------------------- hero
# 8 s loop: listen (0–3 s) -> tidy (3–4.4 s) -> written at the cursor (4.4–7.6 s).
RAW = [("嗯那个，", True), ("明天，不对，", True), ("后天下午三点开会，", False), ("然后", True), ("会前把报告发给大家", False)]
FINAL = "后天下午三点开会，会前把报告发给大家。"


def hero(t):
    W, H = 880, 560
    card_x, card_w = 110, 660
    body = []
    # App icon with listening bars.
    body.append(f'<rect x="392" y="22" width="96" height="96" rx="23" fill="{t["icon"]}" stroke="{t["iconEdge"]}"/>')
    body.append(icon_bars(440, 70, 1.0, "#ffffff", True, "hb"))
    body.append(text(440, 188, "TypeLeast", 62, "ink", 700, "middle", 'letter-spacing="-1.5"'))
    body.append(text(440, 240, "说出来，就写好了。", 32, "ink", 600, "middle", 'letter-spacing="0.5"'))
    body.append(text(440, 276, "按一下说话，再按一下——整理好的文字直接出现在光标处。", 17, "gray", 400, "middle"))

    # The text field the user is typing into.
    body.append(f'<rect x="{card_x}" y="314" width="{card_w}" height="124" rx="24" fill="{t["card"]}"/>')
    body.append(text(card_x + 28, 346, "任意输入框", 13, "faint", 500))
    # What was said (raw), with the filler words struck through while tidying.
    x, y, size = card_x + 28, 398, 17
    raw = ['<g class="raw">']
    cx = x
    for chunk, filler in RAW:
        raw.append(text(cx, y, chunk, size, "faint" if filler else "gray", 400))
        if filler:
            raw.append(f'<rect class="left strike" x="{cx}" y="{y - 6}" width="{len(chunk) * size}" height="1.6" '
                       f'rx="0.8" fill="{t["red"]}"/>')
        cx += len(chunk) * size
    raw.append(text(card_x + card_w - 28, 346, "你说的", 13, "faint", 500, "end"))
    raw.append('</g>')
    body.extend(raw)
    # What is written at the cursor.
    final_size = 21
    body.append('<g class="final">')
    body.append(text(x, y + 1, FINAL, final_size, "ink", 500))
    body.append(text(card_x + card_w - 28, 346, "写进去的", 13, "blue", 600, "end"))
    body.append('</g>')
    caret_x = x + len(FINAL) * final_size + 3
    body.append(f'<rect class="caret" x="{caret_x}" y="{y - 19}" width="2" height="24" rx="1" fill="{t["blue"]}"/>')
    body.append(f'<rect class="caret0" x="{x}" y="{y - 19}" width="2" height="24" rx="1" fill="{t["blue"]}"/>')

    # Floating recording bar, as in the app.
    py = 500
    rec = [f'<g class="rec">',
           f'<rect x="275" y="{py - 26}" width="330" height="52" rx="26" fill="{t["pill"]}"/>',
           f'<circle cx="301" cy="{py}" r="17" fill="#ffffff" fill-opacity="0.12"/>',
           f'<path d="M295 {py - 6} l12 12 M307 {py - 6} l-12 12" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round"/>',
           f'<circle cx="334" cy="{py}" r="4.5" fill="{t["red"]}"/>']
    for i in range(22):
        h = 6 + 18 * abs(((i * 7) % 11) / 10 - 0.5) * 2
        rec.append(f'<rect class="grow wv w{i % 6}" x="{350 + i * 9}" y="{py - h / 2:.1f}" width="3.4" height="{h:.1f}" '
                   f'rx="1.7" fill="#ffffff" fill-opacity="{0.55 + 0.4 * ((i * 3) % 5) / 4:.2f}"/>')
    rec += [f'<circle cx="579" cy="{py}" r="17" fill="#ffffff"/>',
            f'<rect x="573" y="{py - 6}" width="12" height="12" rx="2.5" fill="{t["pill"]}"/>', '</g>']
    body.extend(rec)
    think = [f'<g class="think">', f'<rect x="385" y="{py - 26}" width="110" height="52" rx="26" fill="{t["pill"]}"/>']
    for i in range(3):
        think.append(f'<circle class="grow dot d{i}" cx="{421 + i * 19}" cy="{py}" r="5" fill="#ffffff"/>')
    think.append('</g>')
    body.extend(think)
    body.append(f'<g class="done">{text(440, py + 6, "已写入光标处", 15, "gray", 500, "middle")}</g>')

    css = bar_css("hb", 1.1) + """
.wv { animation: wave 0.9s ease-in-out infinite; }
.w0 { animation-delay: -0.1s; } .w1 { animation-delay: -0.35s; } .w2 { animation-delay: -0.6s; }
.w3 { animation-delay: -0.2s; } .w4 { animation-delay: -0.75s; } .w5 { animation-delay: -0.5s; }
@keyframes wave { 0%,100% { transform: scaleY(1); } 50% { transform: scaleY(0.35); } }
.rec   { animation: rec 8s ease-in-out infinite; }
.think { animation: think 8s ease-in-out infinite; }
.done  { animation: done 8s ease-in-out infinite; }
.raw   { animation: raw 8s ease-in-out infinite; }
.final { animation: final 8s cubic-bezier(.2,.8,.2,1) infinite; }
.strike { animation: strike 8s ease-in-out infinite; }
.caret { animation: caret 8s steps(1) infinite; }
.caret0 { animation: caret0 8s steps(1) infinite; }
.dot { animation: dot 0.9s ease-in-out infinite; }
.d1 { animation-delay: 0.15s; } .d2 { animation-delay: 0.3s; }
@keyframes dot { 0%,100% { opacity: .35; transform: scale(.8); } 50% { opacity: 1; transform: scale(1); } }
@keyframes rec   { 0%,2% { opacity: 0; } 5%,36% { opacity: 1; } 39%,100% { opacity: 0; } }
@keyframes think { 0%,37% { opacity: 0; } 40%,53% { opacity: 1; } 56%,100% { opacity: 0; } }
@keyframes done  { 0%,57% { opacity: 0; } 61%,93% { opacity: 1; } 97%,100% { opacity: 0; } }
@keyframes raw   { 0%,4% { opacity: 0; } 9%,52% { opacity: 1; } 56%,100% { opacity: 0; } }
@keyframes strike { 0%,38% { transform: scaleX(0); } 47%,100% { transform: scaleX(1); } }
@keyframes final { 0%,55% { opacity: 0; transform: translateY(8px); } 62%,93% { opacity: 1; transform: translateY(0); } 97%,100% { opacity: 0; } }
@keyframes caret  { 0%,61% { opacity: 0; } 62%,68% { opacity: 1; } 68.01%,74% { opacity: 0; } 74.01%,80% { opacity: 1; } 80.01%,86% { opacity: 0; } 86.01%,93% { opacity: 1; } 93.01%,100% { opacity: 0; } }
@keyframes caret0 { 0%,3% { opacity: 1; } 3.01%,100% { opacity: 0; } }
"""
    return svg(W, H, "\n".join(body), css, t,
               "TypeLeast：说出来，就写好了。按一下说话，再按一下，整理好的文字直接出现在光标处。")


# ---------------------------------------------------------------- feature grid
def tile(x, y, w, h, t, inner):
    return f'<g transform="translate({x},{y})"><rect width="{w}" height="{h}" rx="28" fill="{t["card"]}"/>{inner}</g>'


def chips(x, y, names, t, size=14, gap=10, cls_prefix=None):
    out, cx = [], x
    for i, name in enumerate(names):
        width = sum(size if ord(c) > 0x2E80 else size * 0.6 for c in name) + 28
        cls = f' class="{cls_prefix}{i}"' if cls_prefix else ''
        out.append(f'<g{cls}><rect x="{cx:.0f}" y="{y}" width="{width:.0f}" height="34" rx="17" fill="{t["card2"]}" '
                   f'stroke="{t["line"]}"/>{text(cx + width / 2, y + 22, name, size, "ink", 500, "middle")}</g>')
        cx += width + gap
    return "\n".join(out), cx


def features(t):
    W, G, ROW = 880, 16, 290
    half = (W - G) / 2
    body = []

    # 1. Standard cleanup (full width).
    inner = [text(36, 58, "自然整理", 15, "blue", 600),
             text(36, 98, "随口说，它来整理。", 32, "ink", 700),
             text(36, 132, "口头禅去掉，改口照办，标点补好。不编造你没说的内容。", 16, "gray")]
    by, x0, size = 196, 36, 18
    inner.append(f'<rect x="24" y="162" width="{W - 48}" height="56" rx="16" fill="{t["card2"]}"/>')
    cx = x0 + 12
    for chunk, filler in RAW:
        cls = "faint" if filler else "ink"
        inner.append(f'<g class="{"fade" if filler else ""}">{text(cx, by, chunk, size, cls, 400)}</g>')
        if filler:
            inner.append(f'<rect class="left cut" x="{cx}" y="{by - 6}" width="{len(chunk) * size}" height="1.8" rx="0.9" fill="{t["red"]}"/>')
        cx += len(chunk) * size
    inner.append(f'<g class="result"><rect x="24" y="228" width="{W - 48}" height="56" rx="16" fill="{t["blue"]}" fill-opacity="0.10"/>'
                 + text(48, 262, "后天下午三点开会，会前把报告发给大家。", 18, "ink", 600)
                 + text(W - 48, 262, "写进去的", 13, "blue", 600, "end") + '</g>')
    body.append(tile(0, 0, W, 310, t, "\n".join(inner)))

    # 2. Local recognition.
    y2 = 310 + G
    lock = [text(32, 52, "本机识别", 15, "green", 600),
            text(32, 88, "音频不出电脑。", 26, "ink", 700),
            text(32, 118, "语音在你自己的电脑上识别，", 15, "gray"),
            text(32, 140, "录音不上传，模型下载一次后离线可用。", 15, "gray"),
            f'<circle class="grow pulse" cx="{half / 2}" cy="218" r="50" fill="{t["green"]}" fill-opacity="0.16"/>',
            f'<circle cx="{half / 2}" cy="218" r="40" fill="{t["green"]}"/>',
            icon_bars(half / 2, 218, 0.56, "#ffffff", True, "lb")]
    body.append(tile(0, y2, half, ROW, t, "\n".join(lock)))

    # 3. Any app, at the cursor.
    apps = ["微信", "邮件", "浏览器", "Word", "VS Code"]
    row, _ = chips(32, 176, apps[:3], t)
    row2, _ = chips(32, 220, apps[3:], t)
    anywhere = [text(32, 52, "随处可用", 15, "blue", 600),
                text(32, 88, "任何输入框，直接写入。", 26, "ink", 700),
                text(32, 118, "Mac 单按 fn，Windows 单按右 Alt。", 15, "gray"),
                text(32, 140, "说话时切换了窗口，就只放进剪贴板。", 15, "gray"),
                row, row2]
    body.append(tile(half + G, y2, half, ROW, t, "\n".join(anywhere)))

    # 4. Concise cleanup.
    y3 = y2 + ROW + G
    lines = ["请写本周周报，发给老板，篇幅简短。", "1. 完成登录页改版。", "2. 修复了几个 bug。"]
    prompt = [text(32, 52, "精简整理", 15, "blue", 600),
              text(32, 88, "说得多，留得少。", 26, "ink", 700),
              text(32, 118, "一次说完，只留要点和条件，", 15, "gray"),
              text(32, 140, "不加你没提的要求。", 15, "gray")]
    prompt.append(f'<rect x="24" y="160" width="{half - 48}" height="106" rx="16" fill="{t["card2"]}"/>')
    for i, line in enumerate(lines):
        prompt.append(f'<g class="pl p{i}">{text(44, 190 + i * 30, line, 14, "ink", 500)}</g>')
    body.append(tile(0, y3, half, ROW, t, "\n".join(prompt)))

    # 5. Four local models.
    models = ["SenseVoice", "FireRedASR2", "Fun-ASR-Nano", "Qwen3-ASR"]
    m1, _ = chips(32, 176, models[:2], t, 13, cls_prefix="m")
    m2, _ = chips(32, 220, models[2:], t, 13, cls_prefix="n")
    asr = [text(32, 52, "识别模型", 15, "blue", 600),
           text(32, 88, "四个本机模型，随时切换。", 26, "ink", 700),
           text(32, 118, "默认小而快；中文方言、中英混说、", 15, "gray"),
           text(32, 140, "多语言都有更大的模型可选。", 15, "gray"), m1, m2]
    body.append(tile(half + G, y3, half, ROW, t, "\n".join(asr)))

    # 6. Your model, your key.
    y4 = y3 + ROW + G
    providers = ["DeepSeek", "智谱 GLM", "Kimi", "通义千问", "OpenRouter", "OpenAI", "本机 Ollama"]
    prow, _ = chips(32, 128, providers, t, 14, 10)
    key = [text(32, 52, "你的模型", 15, "blue", 600),
           text(32, 92, "用你自己的 Key。Key 只存在钥匙串 / 凭据管理器里。", 22, "ink", 700), prow]
    body.append(tile(0, y4, W, 192, t, "\n".join(key)))
    H = y4 + 192

    css = bar_css("lb", 1.2, 0.35) + """
.fade { animation: fade 6s ease-in-out infinite; }
.cut  { animation: cut 6s ease-in-out infinite; }
@keyframes cut  { 0%,15% { transform: scaleX(0); } 35%,85% { transform: scaleX(1); } 95%,100% { transform: scaleX(0); } }
@keyframes fade { 0%,35% { opacity: 1; } 50%,85% { opacity: .35; } 95%,100% { opacity: 1; } }
.pulse { animation: pulse 2.4s ease-out infinite; }
@keyframes pulse { 0% { transform: scale(.8); opacity: 1; } 100% { transform: scale(1.5); opacity: 0; } }
.result { animation: result 6s ease-in-out infinite; }
@keyframes result { 0%,30% { opacity: .25; } 42%,88% { opacity: 1; } 96%,100% { opacity: .25; } }
.pl { animation: pl 6s ease-out infinite; opacity: 0; }
.p0 { animation-delay: 0s; } .p1 { animation-delay: .35s; } .p2 { animation-delay: .7s; } .p3 { animation-delay: 1.05s; } .p4 { animation-delay: 1.4s; }
@keyframes pl { 0% { opacity: 0; transform: translateX(-6px); } 8%,80% { opacity: 1; transform: translateX(0); } 92%,100% { opacity: 0; } }
.m0,.m1,.n0,.n1 { animation: pick 8s ease-in-out infinite; }
.m1 { animation-delay: -6s; } .n0 { animation-delay: -4s; } .n1 { animation-delay: -2s; }
@keyframes pick { 0%,22% { opacity: 1; } 27%,95% { opacity: .5; } 100% { opacity: 1; } }
"""
    return svg(W, H, "\n".join(body), css, t,
               "亮点：自然整理；音频不出电脑；任何输入框直接写入；精简整理；四个本机识别模型；用你自己的 Key。")


# ---------------------------------------------------------------- prompt Beta
# 12 s loop: you talk, it asks only what is missing, you answer, it shows what it understood,
# then writes the long prompt and a review removes what you never said. Invented example.
def prompt_story(t):
    W, H = 880, 560
    violet = "#8e5cf0" if t is THEMES["light"] else "#a77bff"
    body = [f'<rect width="{W}" height="{H}" rx="28" fill="{t["card"]}"/>',
            text(36, 56, "提示词 Beta", 15, "", 600, extra=f'fill="{violet}"'),
            text(36, 98, "长提示词，聊着就写好了。", 32, "ink", 700),
            text(36, 132, "它问，你答。出稿前你核对，出稿后它再审一遍。", 16, "gray")]
    # Left: the conversation.
    L, LW, top = 24, 404, 160
    body.append(f'<rect x="{L}" y="{top}" width="{LW}" height="{H - top - 24}" rx="20" fill="{t["card2"]}"/>')
    body.append(f'<g class="s1">{text(L + 20, top + 30, "你说", 12, "faint", 600)}'
                f'<rect x="{L + 40}" y="{top + 42}" width="{LW - 60}" height="62" rx="16" fill="{t["blue"]}"/>'
                + text(L + 56, top + 68, "我想给社区羽毛球群做个报名小程序，", 14, "", 500, extra='fill="#ffffff"')
                + text(L + 56, top + 90, "接龙太乱，场地费也是我一个个收……", 14, "", 500, extra='fill="#ffffff"') + '</g>')
    qs = ["场地费按报名人数还是到场人数分？", "报了名没来的人，怎么处理？", "大家平时用什么付款？"]
    q = [f'<g class="s2">{text(L + 20, top + 126, "待补充的信息 · 每轮最多 4 问", 12, "faint", 600)}']
    for i, line in enumerate(qs):
        y = top + 136 + i * 32
        q.append(f'<rect x="{L + 20}" y="{y}" width="{LW - 40}" height="28" rx="10" fill="{t["card"]}" stroke="{t["line"]}"/>'
                 + text(L + 34, y + 19, "？", 13, "", 700, extra=f'fill="{violet}"') + text(L + 54, y + 19, line, 13, "ink"))
    body.append("".join(q) + '</g>')
    body.append(f'<g class="s3"><rect x="{L + 40}" y="{top + 240}" width="{LW - 60}" height="38" rx="14" fill="{t["blue"]}"/>'
                + text(L + 56, top + 264, "按到场人数平分；放鸽子的下次排后面；用微信。", 13, "", 500, extra='fill="#ffffff"') + '</g>')
    body.append(f'<g class="s4">{text(L + 20, top + 302, "当前理解，请核对", 12, "faint", 600)}'
                + text(L + 20, top + 324, "✓ 报名小程序替代接龙　✓ 按到场人数平分", 13, "green", 500)
                + f'<rect x="{L + 20}" y="{top + 334}" width="138" height="30" rx="15" fill="{violet}"/>'
                + text(L + 89, top + 354, "结束补充并生成", 13, "", 600, "middle", 'fill="#ffffff"') + '</g>')
    # Right: the long prompt, then the review.
    R, RW = L + LW + 16, W - (L + LW + 16) - 24
    body.append(f'<rect x="{R}" y="{top}" width="{RW}" height="{H - top - 24}" rx="20" fill="{t["card2"]}"/>')
    body.append(f'<g class="s5">{text(R + 20, top + 30, "写好的提示词", 12, "faint", 600)}</g>')
    doc = [("## 背景与现状", True), ("群里接龙约场，常有人不到；场地费逐个收取。", False),
           ("## 目标", True), ("报名小程序，替代接龙，自动计算场地费。", False), ("增加积分排行榜，激励按时到场。", None),
           ("## 要求", True), ("一、按实际到场人数平分　二、未到者下次排后", False),
           ("三、微信付款　四、操作简单，适合中老年人", False), ("## 待确认", True), ("每周的场次尚未说明。", False)]
    y = top + 58
    for i, (line, head) in enumerate(doc):
        if head is None:
            body.append(f'<g class="d{i} bad">{text(R + 20, y, line, 13, "gray")}'
                        f'<rect class="left strike2" x="{R + 20}" y="{y - 5}" width="{len(line) * 13}" height="1.6" fill="{t["red"]}"/>'
                        f'<g class="why">{text(R + RW - 20, y, "你没说过 · 删除", 11, "", 600, "end", extra=f'fill="{t["red"]}"')}</g></g>')
        else:
            cls = "ink" if head else "gray"
            if line.startswith("每周"):
                cls = "faint"
            body.append(f'<g class="d{i}">{text(R + 20, y, line, 14 if head else 13, cls, 700 if head else 400)}</g>')
        y += 30 if head else 26
        if not head and i + 1 < len(doc) and doc[i + 1][1] is True:
            y += 6
    body.append(f'<g class="s6">{text(R + 20, H - 46, "✓ 审查完成：删掉没来源的，补回漏掉的。", 13, "green", 600)}</g>')

    def show(name, start):
        return (f'.{name} {{ animation: {name}K 12s ease-in-out infinite; }}\n'
                f'@keyframes {name}K {{ 0%,{start}% {{ opacity: 0; transform: translateY(6px); }} '
                f'{start + 3}%,94% {{ opacity: 1; transform: none; }} 99%,100% {{ opacity: 0; }} }}')
    css = [show("s1", 2), show("s2", 13), show("s3", 25), show("s4", 34), show("s5", 44), show("s6", 82)]
    for i in range(len(doc)):
        css.append(show(f"d{i}", 46 + i * 2.6))
    css.append(".s1,.s2,.s3,.s4,.s5,.s6," + ",".join(f".d{i}" for i in range(len(doc))) + " { transform-box: fill-box; }")
    css.append(".strike2 { animation: strikeK 12s ease-in-out infinite; } "
               "@keyframes strikeK { 0%,74% { transform: scaleX(0); } 80%,94% { transform: scaleX(1); } 99%,100% { transform: scaleX(0); } }")
    css.append(".why { animation: whyK 12s ease-in-out infinite; } "
               "@keyframes whyK { 0%,76% { opacity: 0; } 80%,94% { opacity: 1; } 99%,100% { opacity: 0; } }")
    return svg(W, H, "\n".join(body), "\n".join(css), t,
               "提示词 Beta：你随口说项目，它只问缺的几个问题，你回答并核对它的理解，然后写成完整的长提示词，再审查一遍，删掉你没说过的内容。")


# ---------------------------------------------------------------- free
def free(t):
    W, H = 880, 330
    body = [f'<rect width="{W}" height="{H}" rx="28" fill="{t["card"]}"/>',
            text(W / 2, 64, "免费", 15, "blue", 600, "middle"),
            f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0" gradientUnits="objectBoundingBox">'
            f'<stop offset="0" stop-color="{t["blue"]}"/><stop offset="0.5" stop-color="#af52de"/><stop offset="1" stop-color="{t["blue"]}"/>'
            f'<animateTransform attributeName="gradientTransform" type="translate" values="-0.5 0; 0.5 0; -0.5 0" dur="6s" repeatCount="indefinite"/>'
            f'</linearGradient></defs>',
            f'<text x="{W / 2}" y="132" font-size="72" font-weight="700" text-anchor="middle" fill="url(#g)" letter-spacing="-1">¥0</text>',
            text(W / 2, 166, "整套框架免费使用：没有订阅，不用注册，不限次数。", 17, "gray", 400, "middle")]
    cols = [("本机识别", "不花钱，", "模型下载一次后离线可用。"), ("文字整理", "用你自己的 Key，", "按服务商用量计费。"),
            ("本机 Ollama", "整理也在本机，", "一分钱都不花。")]
    cw = (W - 64 - 2 * 16) / 3
    for i, (title, a, b) in enumerate(cols):
        x = 32 + i * (cw + 16)
        body.append(f'<rect x="{x:.0f}" y="198" width="{cw:.0f}" height="104" rx="20" fill="{t["card2"]}"/>')
        body.append(text(x + cw / 2, 234, title, 17, "ink", 600, "middle"))
        body.append(text(x + cw / 2, 262, a, 14, "gray", 400, "middle"))
        body.append(text(x + cw / 2, 284, b, 14, "gray", 400, "middle"))
    css = ""
    return svg(W, H, "\n".join(body), css, t,
               "免费：整套框架免费使用，没有订阅，不用注册，不限次数。本机识别不花钱；整理用你自己的 Key 按用量计费；用本机 Ollama 一分钱都不花。")


# ---------------------------------------------------------------- buttons
def button(label, t, primary):
    width = sum(17 if ord(c) > 0x2E80 else 10 for c in label) + 56
    fill, ink, stroke = (t["ink"], t["card2"] if primary else t["ink"], "none") if primary else ("none", t["blue"], t["blue"])
    if primary:
        ink = "#ffffff" if t is THEMES["light"] else "#1d1d1f"
    body = (f'<rect x="1" y="1" width="{width - 2}" height="46" rx="23" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>'
            f'<text x="{width / 2}" y="30" font-size="17" font-weight="600" text-anchor="middle" fill="{ink}">{escape(label)}</text>')
    return svg(int(width), 48, body, "", t, label)


def main():
    for mode, t in THEMES.items():
        for name, make in [("hero", hero), ("prompt", prompt_story), ("features", features), ("free", free)]:
            (OUT / f"{name}-{mode}.svg").write_text(make(t), encoding="utf-8")
        (OUT / f"button-download-{mode}.svg").write_text(button("下载最新版", t, True), encoding="utf-8")
        (OUT / f"button-more-{mode}.svg").write_text(button("看它怎么用 ›", t, False), encoding="utf-8")
    print("written to", OUT)


if __name__ == "__main__":
    main()
