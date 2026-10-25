// film.js - the 24-second product film, drawn in the page instead of a video file so it stays
// sharp at any size and speaks the visitor's language. site/record-film.mjs records the same
// film into docs/media/promo.mp4 and promo.gif for the README.
//
//   const film = TypeLeastFilm.mount(element, "zh");   // or "en"
//   film.play(); film.pause(); film.seek(seconds); film.setLang("en");
//
// Every frame is a pure function of the time, so a recording is exactly what the page shows.
(function () {
  const W = 1280, H = 720, LENGTH = 24;

  const TEXT = {
    zh: {
      c1: "按一下，说话。", c2: "再按一下，就写好了。", c3: "长提示词，聊着就写好了。",
      c4: "说一种语言，写另一种。", c5: "三种整理方式，一键切换。", c6: "你的声音，留在你的电脑上。",
      mail: "新邮件", to: "收件人：项目组", subject: "主题：周会改期",
      raw: [["嗯那个，", 1], ["明天，不对，", 1], ["后天下午三点开会，", 0], ["然后", 1], ["会前把报告发给大家", 0]],
      final: "后天下午三点开会，会前把报告发给大家。", done: "已写入",
      beta: "提示词 Beta", say: "我想给社区羽毛球群做个报名小程序。现在靠群接龙，场地费也是我一个个收……",
      askTitle: "待补充的信息",
      asks: ["场地费按报名人数分，还是按到场人数分？", "报了名没来的人，怎么处理？", "大家平时用什么付款？"],
      answer: "按到场人数分。没来的下次排后面。都用微信。",
      doc: [["## 背景", 1], ["群接龙约场，常有人报名不到；场地费逐个收取。", 0], ["## 目标", 1],
            ["做一个报名小程序，替代群接龙，自动算出每人的场地费。", 0], ["## 要求", 1],
            ["一、按实际到场人数平分。", 0], ["二、报名未到的人，下次排在后面。", 0], ["三、使用微信付款。", 0],
            ["## 待确认", 1], ["每周的场次。", 2]],
      from: "周五之前把方案发我，谢谢。", fromTag: "你说 · 中文",
      to2: "Please send me the proposal by Friday. Thanks.", toTag: "写出 · English",
      langs: ["English", "日本語", "한국어", "Français", "Deutsch", "Español"], target: 0,
      modes: [["自然整理", "删掉口头禅，改通顺。"], ["精简整理", "一次说完，只留要点。"],
              ["提示词 Beta", "多轮追问，写成长提示词。"]],
      dictFrom: "德普西克", dictTo: "DeepSeek", dictTag: "词典",
      facts: ["本机识别", "你自己的模型", "免费"], platforms: "Mac · Windows · 免费",
    },
    en: {
      c1: "Press once. Speak.", c2: "Press again. It's written.", c3: "Long prompts. Just talk them through.",
      c4: "Speak one language. Write another.", c5: "Three ways to clean up. One click to switch.", c6: "Your voice stays on your computer.",
      mail: "New Message", to: "To: Project team", subject: "Subject: Weekly meeting",
      raw: [["Um, so, ", 1], ["tomorrow, no wait, ", 1], ["the meeting is Friday at three, ", 0], ["and uh, ", 1], ["bring the report", 0]],
      final: "The meeting is Friday at three. Please bring the report.", done: "Written",
      beta: "Prompt Beta", say: "I want a sign-up app for our neighborhood badminton group. Right now it's all group chat, and I collect court fees one by one…",
      askTitle: "Information to clarify",
      asks: ["Split court fees by sign-ups or by who shows up?", "What happens to people who sign up and don't come?", "How do people usually pay?"],
      answer: "By who shows up. No-shows go to the back next time. Everyone pays by phone.",
      doc: [["## Background", 1], ["Games are arranged in a group chat. People often sign up and don't show.", 0], ["## Goal", 1],
            ["A sign-up app that replaces the chat and works out each player's court fee.", 0], ["## Requirements", 1],
            ["1. Split fees evenly among the players who show up.", 0], ["2. No-shows go to the back of the list next time.", 0],
            ["3. Payment by phone.", 0], ["## To confirm", 1], ["How many games a week.", 2]],
      from: "Please send me the proposal by Friday. Thanks.", fromTag: "You say · English",
      to2: "金曜日までに企画書を送ってください。", toTag: "Written · 日本語",
      langs: ["中文", "日本語", "한국어", "Français", "Deutsch", "Español"], target: 1,
      modes: [["Natural cleanup", "Removes filler words. Smooths it out."], ["Concise", "Say it once. Keep only the key points."],
              ["Prompt Beta", "Asks questions. Writes a long prompt."]],
      dictFrom: "deep seek", dictTo: "DeepSeek", dictTag: "Dictionary",
      facts: ["On-device recognition", "Your own model", "Free"], platforms: "Mac · Windows · Free",
    },
  };

  const CSS = `
.tlf { position: relative; width: 100%; aspect-ratio: 16 / 9; overflow: hidden; background: #000; color: #f5f5f7;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei", "Noto Sans SC", system-ui, sans-serif; }
.tlf * { box-sizing: border-box; }
.tlf .s { position: absolute; left: 0; top: 0; width: ${W}px; height: ${H}px; transform-origin: 0 0; }
.tlf .a { position: absolute; will-change: opacity, transform; }
.tlf .cap { left: 0; right: 0; top: 70px; text-align: center; font-size: 46px; font-weight: 600; letter-spacing: -.01em; }
.tlf .win { left: 250px; top: 168px; width: 780px; height: 400px; border-radius: 22px; background: #1d1d1f; box-shadow: 0 40px 100px rgba(0,0,0,.6); overflow: hidden; }
.tlf .bar { height: 44px; display: flex; align-items: center; gap: 8px; padding: 0 18px; background: #2a2a2d; font-size: 14px; color: #a1a1a6; }
.tlf .bar i { width: 12px; height: 12px; border-radius: 50%; background: #48484a; display: inline-block; }
.tlf .bar b { margin-left: 14px; color: #f5f5f7; font-weight: 600; }
.tlf .meta { padding: 14px 26px 0; font-size: 15px; color: #86868b; line-height: 1.9; border-bottom: 1px solid rgba(255,255,255,.07); padding-bottom: 10px; }
.tlf .body { position: relative; padding: 22px 26px; font-size: 24px; line-height: 1.6; height: 220px; }
.tlf .raw span.f { color: #6e6e73; position: relative; }
.tlf .raw span.f::after { content: ""; position: absolute; left: 0; right: 0; top: 54%; height: 2px; background: #ff453a; transform-origin: left; transform: scaleX(var(--k, 0)); }
.tlf .caret { display: inline-block; width: 2px; height: 28px; background: #2997ff; vertical-align: -5px; margin-left: 2px; }
.tlf .pill { left: 50%; top: 600px; height: 58px; border-radius: 29px; background: #2c2c2e; display: flex; align-items: center; justify-content: center; gap: 12px; padding: 0 22px;
  box-shadow: 0 16px 40px rgba(0,0,0,.5); transform: translateX(-50%); white-space: nowrap; font-size: 17px; color: #f5f5f7; }
.tlf .dot { width: 10px; height: 10px; border-radius: 50%; background: #ff453a; }
.tlf .wv { display: flex; align-items: center; gap: 4px; height: 34px; }
.tlf .wv i { width: 4px; border-radius: 2px; background: #f5f5f7; display: block; }
.tlf .think i { width: 9px; height: 9px; border-radius: 50%; background: #f5f5f7; display: inline-block; margin: 0 4px; }
.tlf .panel { border-radius: 22px; background: #1d1d1f; padding: 22px 24px; }
.tlf .lbl { font-size: 13px; font-weight: 600; color: #86868b; letter-spacing: .02em; margin-bottom: 10px; }
.tlf .bub { background: #0a84ff; color: #fff; border-radius: 18px 18px 6px 18px; padding: 12px 16px; font-size: 16px; line-height: 1.5; }
.tlf .ask { background: #2c2c2e; border-radius: 12px; padding: 9px 14px; font-size: 15px; margin-top: 8px; }
.tlf .ask b { color: #bf5af2; margin-right: 8px; }
.tlf .doc div { font-size: 15.5px; line-height: 1.55; color: #a1a1a6; }
.tlf .doc div.h { color: #f5f5f7; font-weight: 600; margin-top: 10px; }
.tlf .doc div.h:first-child { margin-top: 0; }
.tlf .doc div.p { color: #ffd60a; }
.tlf .big { left: 90px; right: 90px; text-align: center; font-size: 44px; font-weight: 600; line-height: 1.3; }
.tlf .tag { left: 0; right: 0; text-align: center; font-size: 15px; font-weight: 600; color: #86868b; letter-spacing: .04em; }
.tlf .chips { left: 0; right: 0; top: 560px; display: flex; justify-content: center; gap: 10px; }
.tlf .chips span { font-size: 15px; padding: 7px 16px; border-radius: 999px; background: #1d1d1f; color: #a1a1a6; }
.tlf .chips span.on { background: #f5f5f7; color: #1d1d1f; font-weight: 600; }
.tlf .seg { left: 190px; top: 250px; width: 900px; height: 64px; border-radius: 32px; background: #1d1d1f; display: flex; padding: 6px; }
.tlf .seg span { flex: 1; display: flex; align-items: center; justify-content: center; font-size: 19px; color: #a1a1a6; position: relative; z-index: 1; }
.tlf .seg span.on { color: #1d1d1f; font-weight: 600; }
.tlf .knob { position: absolute; top: 6px; height: 52px; width: 296px; border-radius: 26px; background: #f5f5f7; }
.tlf .desc { left: 0; right: 0; top: 352px; text-align: center; font-size: 26px; color: #f5f5f7; }
.tlf .dict { left: 0; right: 0; top: 470px; display: flex; justify-content: center; align-items: center; gap: 18px; font-size: 24px; }
.tlf .dict s { color: #6e6e73; text-decoration-color: #ff453a; }
.tlf .dict em { font-style: normal; color: #f5f5f7; font-weight: 600; }
.tlf .dict small { font-size: 14px; font-weight: 600; color: #86868b; padding: 5px 12px; border-radius: 999px; background: #1d1d1f; }
.tlf .ring { left: 560px; top: 210px; width: 160px; height: 160px; border-radius: 50%; background: #1d1d1f; display: flex; align-items: center; justify-content: center; gap: 7px; }
.tlf .ring i { width: 9px; border-radius: 5px; background: #30d158; display: block; }
.tlf .facts { left: 0; right: 0; top: 420px; display: flex; justify-content: center; gap: 48px; font-size: 22px; color: #a1a1a6; }
.tlf .facts span::before { content: "✓"; color: #30d158; margin-right: 10px; }
.tlf .end { left: 0; right: 0; top: 230px; text-align: center; }
.tlf .end .ic { width: 120px; height: 120px; margin: 0 auto 26px; border-radius: 28px; background: #111; box-shadow: 0 0 0 1px #2c2c2e; display: flex; align-items: center; justify-content: center; gap: 7px; }
.tlf .end .ic i { width: 9px; border-radius: 5px; background: #fff; display: block; }
.tlf .end h3 { margin: 0; font-size: 64px; font-weight: 700; letter-spacing: -.02em; }
.tlf .end p { margin: 10px 0 0; font-size: 22px; color: #86868b; }
`;

  const clamp = (x) => Math.max(0, Math.min(1, x));
  const ease = (x) => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
  // 0 before a, rises to 1 by a + d, stays until b, gone by b + d.
  const span = (t, a, b, d = .45) => Math.min(ease((t - a) / d), 1 - ease((t - b) / d));
  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const bars = (n) => Array.from({ length: n }, () => "<i></i>").join("");

  function build(L) {
    return `<div class="s">
<div class="a cap" data-k="cap1">${esc(L.c1)}</div><div class="a cap" data-k="cap2">${esc(L.c2)}</div>
<div class="a cap" data-k="cap3">${esc(L.c3)}</div><div class="a cap" data-k="cap4">${esc(L.c4)}</div>
<div class="a cap" data-k="cap5">${esc(L.c5)}</div><div class="a cap" data-k="cap6">${esc(L.c6)}</div>

<div class="a win" data-k="win"><div class="bar"><i></i><i></i><i></i><b>${esc(L.mail)}</b></div>
  <div class="meta">${esc(L.to)}<br>${esc(L.subject)}</div>
  <div class="body"><div class="a raw" data-k="raw" style="left:26px;right:26px;top:22px">${L.raw.map(([s, f]) => `<span class="${f ? "f" : ""}">${esc(s)}</span>`).join("")}</div>
  <div class="a" data-k="final" style="left:26px;right:26px;top:22px"><span data-k="typed"></span><span class="caret" data-k="caret"></span></div></div></div>
<div class="a pill" data-k="rec"><span class="dot"></span><span class="wv" data-k="wv">${bars(26)}</span></div>
<div class="a pill think" data-k="think">${bars(3)}</div>
<div class="a pill" data-k="done"><span style="color:#30d158">✓</span>${esc(L.done)}</div>

<div class="a panel" data-k="chat" style="left:110px;top:170px;width:500px;height:470px">
  <div class="lbl">${esc(L.beta)}</div>
  <div class="a bub" data-k="say" style="position:relative">${esc(L.say)}</div>
  <div data-k="asks" style="margin-top:16px"><div class="lbl" style="margin-bottom:2px">${esc(L.askTitle)}</div>${L.asks.map((q, i) => `<div class="ask" data-k="ask${i}"><b>?</b>${esc(q)}</div>`).join("")}</div>
  <div class="bub" data-k="answer" style="margin-top:14px">${esc(L.answer)}</div></div>
<div class="a panel doc" data-k="doc" style="left:640px;top:170px;width:530px;height:470px">${L.doc.map(([s, h], i) => `<div class="${h === 1 ? "h" : h === 2 ? "p" : ""}" data-k="d${i}">${esc(s)}</div>`).join("")}</div>

<div class="a tag" data-k="fromTag" style="top:250px">${esc(L.fromTag)}</div>
<div class="a big" data-k="from" style="top:290px">${esc(L.from)}</div>
<div class="a tag" data-k="toTag" style="top:250px">${esc(L.toTag)}</div>
<div class="a big" data-k="to2" style="top:290px">${esc(L.to2)}</div>
<div class="a chips" data-k="langs">${L.langs.map((s, i) => `<span data-k="lang${i}">${esc(s)}</span>`).join("")}</div>

<div class="a seg" data-k="seg"><div class="knob" data-k="knob"></div>${L.modes.map(([m], i) => `<span data-k="m${i}">${esc(m)}</span>`).join("")}</div>
${L.modes.map(([, d], i) => `<div class="a desc" data-k="desc${i}">${esc(d)}</div>`).join("")}
<div class="a dict" data-k="dict"><small>${esc(L.dictTag)}</small><s>${esc(L.dictFrom)}</s><span style="color:#86868b">→</span><em>${esc(L.dictTo)}</em></div>

<div class="a ring" data-k="ring">${bars(7)}</div>
<div class="a facts" data-k="facts">${L.facts.map((f) => `<span>${esc(f)}</span>`).join("")}</div>
<div class="a end" data-k="end"><div class="ic">${bars(7)}</div><h3>TypeLeast</h3><p>${esc(L.platforms)}</p></div>
</div>`;
  }

  function mount(root, lang) {
    if (!document.getElementById("tlf-css")) {
      const style = document.createElement("style");
      style.id = "tlf-css"; style.textContent = CSS; document.head.appendChild(style);
    }
    root.classList.add("tlf");
    let L, k = {}, t = 0, playing = false, last = 0, raf = 0;

    function setLang(next) {
      L = TEXT[next] || TEXT.zh;
      root.innerHTML = build(L);
      k = {};
      for (const el of root.querySelectorAll("[data-k]")) k[el.dataset.k] = el;
      fit(); draw();
    }
    function fit() { const s = root.querySelector(".s"); if (s) s.style.transform = `scale(${root.clientWidth / W})`; }

    const show = (el, o, y = 0, s = 1, blur = 0) => {
      el.style.opacity = o.toFixed(3);
      el.style.visibility = o > .001 ? "visible" : "hidden";
      el.style.transform = (el.classList.contains("pill") ? "translateX(-50%) " : "") + `translateY(${y.toFixed(1)}px) scale(${s.toFixed(4)})`;
      el.style.filter = blur > .05 ? `blur(${blur.toFixed(1)}px)` : "none";
    };
    const cap = (el, a, b) => { const o = span(t, a, b, .5); show(el, o, (1 - ease((t - a) / .6)) * 18, 1, (1 - o) * 10); };
    const bar = (el, h) => { el.style.height = h.toFixed(1) + "px"; };

    function draw() {
      if (!L) return;
      // Scene 1: dictate an email (0–8 s).
      cap(k.cap1, .3, 3.6); cap(k.cap2, 4.0, 7.3);
      const w = span(t, .2, 7.4, .6);
      show(k.win, w, (1 - ease((t - .2) / .7)) * 40, .96 + .04 * w);
      const rec = span(t, .8, 3.9, .3);
      show(k.rec, rec, (1 - rec) * 12);
      const bs = k.wv.children;
      for (let i = 0; i < bs.length; i++) {
        const v = .5 + .5 * Math.sin(t * 9 + i * .8) * Math.sin(t * 3.1 + i * .35);
        bar(bs[i], 6 + 26 * Math.abs(v) * rec);
      }
      const think = span(t, 3.9, 5.0, .25);
      show(k.think, think, 0, .9 + .1 * think);
      [...k.think.children].forEach((d, i) => { d.style.opacity = (.35 + .65 * Math.abs(Math.sin(t * 5 - i * .6))).toFixed(2); });
      show(k.done, span(t, 5.1, 6.9, .3), 0);
      const words = k.raw.children;
      let start = 1.0;
      for (let i = 0; i < words.length; i++) {
        words[i].style.opacity = clamp((t - start) / .35).toFixed(2);
        start += .55;
        if (words[i].classList.contains("f")) words[i].style.setProperty("--k", ease((t - 4.1 - i * .12) / .4).toFixed(3));
      }
      show(k.raw, 1 - ease((t - 4.8) / .4), -ease((t - 4.8) / .4) * 10);
      const typedN = Math.round(clamp((t - 5.1) / 1.2) * L.final.length);
      k.typed.textContent = L.final.slice(0, typedN);
      show(k.final, t > 5.0 ? 1 : 0);
      k.caret.style.opacity = t > 6.4 ? (Math.floor(t * 2) % 2 ? 0 : 1) : 1;

      // Scene 2: prompt Beta (8–14 s).
      cap(k.cap3, 8.2, 13.4);
      const c = span(t, 8.3, 13.5, .6), d = span(t, 8.6, 13.5, .6);
      show(k.chat, c, (1 - ease((t - 8.3) / .7)) * 40);
      show(k.doc, d, (1 - ease((t - 8.6) / .7)) * 40);
      show(k.say, clamp((t - 8.7) / .4), (1 - ease((t - 8.7) / .5)) * 10);
      k.asks.style.opacity = clamp((t - 9.6) / .3);
      for (let i = 0; i < 3; i++) show(k["ask" + i], clamp((t - 9.7 - i * .3) / .3), (1 - ease((t - 9.7 - i * .3) / .4)) * 8);
      show(k.answer, clamp((t - 10.9) / .4), (1 - ease((t - 10.9) / .5)) * 10);
      L.doc.forEach((_, i) => show(k["d" + i], clamp((t - 11.5 - i * .17) / .3), (1 - ease((t - 11.5 - i * .17) / .4)) * 6));

      // Scene 3: translate (14–17.5 s).
      cap(k.cap4, 14.1, 17.0);
      const from = span(t, 14.3, 15.6, .4), to = span(t, 15.8, 17.1, .45);
      show(k.fromTag, from); show(k.from, from, -ease((t - 15.6) / .4) * 20, 1, (1 - from) * 12);
      show(k.toTag, to); show(k.to2, to, (1 - ease((t - 15.8) / .5)) * 20, 1, (1 - to) * 12);
      show(k.langs, span(t, 14.4, 17.1, .4));
      L.langs.forEach((_, i) => k["lang" + i].classList.toggle("on", i === L.target && t > 15.8));

      // Scene 4: modes and the dictionary (17.5–21 s).
      cap(k.cap5, 17.6, 20.6);
      show(k.seg, span(t, 17.7, 20.7, .45), (1 - ease((t - 17.7) / .6)) * 20);
      const pick = Math.max(0, Math.min(2, Math.floor((t - 18.0) / .85)));
      const slide = 18.0 + pick * .85, from2 = Math.max(0, pick - 1);
      const at = from2 + (pick - from2) * ease((t - slide) / .3);
      k.knob.style.transform = `translateX(${(296 * at).toFixed(1)}px)`;
      for (let i = 0; i < 3; i++) {
        k["m" + i].classList.toggle("on", i === Math.round(at));
        show(k["desc" + i], i === Math.round(at) ? span(t, slide + .15, 20.6, .25) : 0);
      }
      show(k.dict, span(t, 18.4, 20.7, .4), (1 - ease((t - 18.4) / .5)) * 12);

      // Scene 5: privacy, then the end card (21–24 s).
      cap(k.cap6, 21.0, 22.6);
      const ring = span(t, 21.0, 22.7, .4);
      show(k.ring, ring, 0, .8 + .2 * ease((t - 21) / .6));
      [...k.ring.children].forEach((b, i) => bar(b, 18 + 50 * Math.abs(Math.sin(t * 4 + i * .9)) * (1 - Math.abs(i - 3) / 5)));
      show(k.facts, span(t, 21.3, 22.7, .4), (1 - ease((t - 21.3) / .5)) * 12);
      const end = span(t, 22.9, 23.8, .45);
      show(k.end, end, 0, .94 + .06 * end, (1 - end) * 8);
      [...root.querySelectorAll(".end .ic i")].forEach((b, i) => bar(b, 22 + 44 * (1 - Math.abs(i - 3) / 4) * (.75 + .25 * Math.sin(t * 5 + i))));
    }

    function frame(now) {
      if (!playing) return;
      t = (t + Math.min(.1, (now - last) / 1000)) % LENGTH; last = now;
      draw(); raf = requestAnimationFrame(frame);
    }
    addEventListener("resize", fit);
    setLang(lang);
    return {
      length: LENGTH,
      play() { if (playing) return; playing = true; last = performance.now(); raf = requestAnimationFrame(frame); },
      pause() { playing = false; cancelAnimationFrame(raf); },
      seek(s) { t = ((s % LENGTH) + LENGTH) % LENGTH; draw(); },
      setLang,
    };
  }

  window.TypeLeastFilm = { mount, length: LENGTH };
})();
