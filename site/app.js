(() => {
  'use strict';
  const root = document.documentElement;
  const languageButton = document.getElementById('language-button');
  const menuButton = document.getElementById('menu-button');
  const nav = document.getElementById('main-nav');
  const copyButton = document.getElementById('copy-button');
  const dialog = document.getElementById('image-dialog');
  const dialogImage = document.getElementById('dialog-image');
  const dialogTitle = document.getElementById('dialog-title');
  const textNodes = [...document.querySelectorAll('[data-en]')];
  const altNodes = [...document.querySelectorAll('[data-alt-en]')];
  const ariaNodes = [...document.querySelectorAll('[data-aria-en]')];
  const linkNodes = [...document.querySelectorAll('[data-href-en]')];
  const originalText = new Map(textNodes.map(node => [node, node.textContent]));
  const originalAlt = new Map(altNodes.map(node => [node, node.alt]));
  const originalAria = new Map(ariaNodes.map(node => [node, node.getAttribute('aria-label')]));
  const originalHref = new Map(linkNodes.map(node => [node, node.getAttribute('href')]));
  let language = 'zh';
  let lastFigure = null;
  let toastTimer;
  let traffic;

  function setMenu(open) {
    nav.classList.toggle('open', open);
    menuButton.setAttribute('aria-expanded', String(open));
    menuButton.setAttribute('aria-label', language === 'en' ? (open ? 'Close navigation' : 'Open navigation') : (open ? '关闭导航' : '打开导航'));
  }

  function setLanguage(next, save = false) {
    language = next === 'en' ? 'en' : 'zh';
    root.lang = language === 'en' ? 'en' : 'zh-CN';
    for (const node of textNodes) node.textContent = language === 'en' ? node.dataset.en : originalText.get(node);
    for (const node of altNodes) node.alt = language === 'en' ? node.dataset.altEn : originalAlt.get(node);
    for (const node of ariaNodes) node.setAttribute('aria-label', language === 'en' ? node.dataset.ariaEn : originalAria.get(node));
    for (const node of linkNodes) node.setAttribute('href', language === 'en' ? node.dataset.hrefEn : originalHref.get(node));
    languageButton.textContent = language === 'en' ? '中文' : 'EN';
    languageButton.setAttribute('aria-label', language === 'en' ? '切换至中文' : 'Switch to English');
    document.querySelector('meta[name="description"]').content = language === 'en'
      ? 'CATunnel is a native macOS menu bar SSH tunnel app that connects remote coding agents to an existing local proxy on your Mac.'
      : 'CATunnel 是原生 macOS 菜单栏 SSH 隧道工具，让远端 Coding Agent 使用 Mac 上已有的本地代理。';
    if (dialog.open && lastFigure) updateFigure(lastFigure);
    traffic?.render();
    setMenu(menuButton.getAttribute('aria-expanded') === 'true');
    if (save) {
      try { localStorage.setItem('catunnel-site-language', language); } catch { /* Storage can be disabled. */ }
      const url = new URL(location.href);
      url.searchParams.set('lang', language);
      history.replaceState(null, '', url);
    }
  }

  function updateFigure(link) {
    const image = link.querySelector('img');
    dialogTitle.textContent = language === 'en' ? link.dataset.captionEn : link.dataset.caption;
    dialogImage.alt = image.alt;
    dialogImage.width = Number(image.getAttribute('width'));
    dialogImage.height = Number(image.getAttribute('height'));
  }

  root.classList.add('js');
  languageButton.hidden = false;
  menuButton.hidden = false;
  copyButton.hidden = false;
  let savedLanguage;
  try { savedLanguage = localStorage.getItem('catunnel-site-language'); } catch { /* Use the browser preference. */ }
  const queryLanguage = new URL(location.href).searchParams.get('lang');
  const initialLanguage = ['en', 'zh'].includes(queryLanguage) ? queryLanguage
    : ['en', 'zh'].includes(savedLanguage) ? savedLanguage
    : navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
  setLanguage(initialLanguage);

  languageButton.addEventListener('click', () => setLanguage(language === 'en' ? 'zh' : 'en', true));
  menuButton.addEventListener('click', () => setMenu(menuButton.getAttribute('aria-expanded') !== 'true'));
  nav.addEventListener('click', event => { if (event.target.closest('a')) setMenu(false); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape') setMenu(false); });

  document.querySelectorAll('[data-lightbox]').forEach(link => {
    link.addEventListener('click', event => {
      if (typeof dialog.showModal !== 'function' || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      lastFigure = link;
      updateFigure(link);
      dialogImage.src = link.href;
      dialog.showModal();
      document.body.classList.add('dialog-open');
    });
  });
  document.getElementById('dialog-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    const rect = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close();
  });
  dialog.addEventListener('close', () => {
    document.body.classList.remove('dialog-open');
    dialogImage.removeAttribute('src');
    lastFigure?.focus({ preventScroll: true });
  });

  copyButton.addEventListener('click', async () => {
    const status = document.getElementById('copy-status');
    try {
      await navigator.clipboard.writeText(document.getElementById('proxy-command').textContent);
      status.textContent = language === 'en' ? 'Command copied' : '命令已复制';
    } catch {
      const range = document.createRange();
      range.selectNodeContents(document.getElementById('proxy-command'));
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = language === 'en' ? 'Select and copy the command manually' : '已选中命令，请手动复制';
    }
    status.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => status.classList.remove('visible'), 2800);
  });

  function setupTrafficDemo() {
    const demo = document.getElementById('traffic-demo');
    const map = document.getElementById('traffic-map');
    const nodes = [...map.querySelectorAll('.route li')];
    const packet = map.querySelector('.traffic-packet');
    const status = document.getElementById('traffic-status');
    const toggle = document.getElementById('traffic-toggle');
    const motion = matchMedia('(prefers-reduced-motion: reduce)');
    const steps = [
      { node: 0, zh: ['远端工具发出请求', '例如向模型 API 发送一次请求；工具已配置为使用服务器本地的代理入口。'], en: ['The remote tool sends a request', 'For example, a model API request. The tool is configured to use the proxy entry on its own server.'] },
      { node: 1, zh: ['请求进入服务器入口', '请求先到达服务器自己的 127.0.0.1:17892，再进入已建立的反向转发通道。'], en: ['The request reaches the server entry', 'It arrives at 127.0.0.1:17892 on the server and enters the established reverse-forwarding path.'] },
      { node: 2, zh: ['通过 SSH 隧道', 'SSH 将这段流量加密传输到 Mac，无需将服务器入口暴露到公网。'], en: ['Across the SSH tunnel', 'SSH carries this traffic to the Mac over an encrypted connection. The server entry stays on loopback.'] },
      { node: 3, zh: ['交给 Mac 本地代理', 'Mac 上已有的 HTTP 或 mixed 代理接收流量，再按自己的代理规则连接目标服务。'], en: ['Through the Mac’s local proxy', 'Your existing HTTP or mixed proxy receives the traffic and connects onward according to its own rules.'] },
      { node: 4, zh: ['到达目标服务', '目标服务处理请求并返回响应。这里演示一次正常往返，不代表实际服务可用或请求成功。'], en: ['The destination responds', 'The service processes the request and returns a response. This illustrates a round trip, not a live availability or success check.'] },
      { node: 3, zh: ['响应回到 Mac 代理', '目标服务的响应沿已建立的连接返回，先由 Mac 本地代理接收。'], en: ['The response returns to the Mac', 'The response travels back over the established connection to the Mac’s local proxy.'] },
      { node: 2, zh: ['沿 SSH 隧道返回', 'SSH 把响应传回服务器；同一条隧道可以双向传输数据。'], en: ['Back through the SSH tunnel', 'SSH carries the response back to the server. The same tunnel carries traffic in both directions.'] },
      { node: 1, zh: ['回到服务器入口', '响应经服务器上的本地入口连接，继续返回给发出请求的工具。'], en: ['Back at the server entry', 'The response passes through the server’s local entry connection on its way to the requesting tool.'] },
      { node: 0, zh: ['远端工具收到响应', '一次请求往返完成。演示会继续循环，你也可以暂停或逐步查看。'], en: ['The remote tool receives the response', 'The round trip is complete. The illustration repeats; pause it or step through at your own pace.'] }
    ];
    let step = 0;
    let playing = !motion.matches;
    let visible = false;
    let timer = null;
    let packetMotion = null;
    let positioned = false;

    function positionPacket(animate = false) {
      const bounds = map.getBoundingClientRect();
      const points = nodes.map(node => {
        const rect = node.querySelector('.route-marker').getBoundingClientRect();
        return { x: rect.left + rect.width / 2 - bounds.left - map.clientLeft, y: rect.top + rect.height / 2 - bounds.top - map.clientTop };
      });
      const path = values => values.map((point, i) => `${i ? 'L' : 'M'}${point.x},${point.y}`).join(' ');
      map.querySelector('.wire-base').setAttribute('d', path(points));
      const nodeIndex = steps[step].node;
      map.querySelector('.wire-progress').setAttribute('d', path(step < 5 ? points.slice(0, nodeIndex + 1) : points.slice(nodeIndex).reverse()));
      const from = getComputedStyle(packet).transform;
      const target = `translate(${points[nodeIndex].x}px, ${points[nodeIndex].y}px)`;
      packetMotion?.cancel();
      packetMotion = null;
      packet.style.transform = target;
      if (animate && positioned && !motion.matches && typeof packet.animate === 'function') {
        packetMotion = packet.animate([{ transform: from }, { transform: target }], { duration: 700, easing: 'ease-in-out' });
      }
      positioned = true;
    }

    function render() {
      const current = steps[step];
      const words = current[language];
      demo.dataset.step = String(step);
      demo.dataset.playing = String(playing);
      demo.dataset.direction = step < 5 ? 'request' : 'response';
      nodes.forEach((node, index) => {
        if (index === current.node) node.setAttribute('aria-current', 'step');
        else node.removeAttribute('aria-current');
      });
      status.setAttribute('aria-live', playing ? 'off' : 'polite');
      document.getElementById('traffic-count').textContent = `${String(step + 1).padStart(2, '0')} / 09`;
      document.getElementById('traffic-title').textContent = words[0];
      document.getElementById('traffic-description').textContent = words[1];
      toggle.textContent = language === 'en' ? (playing ? 'Pause' : 'Play') : (playing ? '暂停演示' : '播放演示');
      toggle.setAttribute('aria-pressed', String(playing));
    }

    function syncPlayback() {
      const running = playing && visible && !document.hidden;
      demo.dataset.running = String(running);
      if (!running) {
        clearTimeout(timer);
        timer = null;
        if (packetMotion?.playState === 'running') packetMotion.pause();
        return;
      }
      if (packetMotion?.playState === 'paused') packetMotion.play();
      if (timer === null) {
        timer = setTimeout(() => {
          timer = null;
          step = (step + 1) % steps.length;
          render();
          // The loop starts a new request; it does not send a packet backwards.
          positionPacket(step !== 0);
          syncPlayback();
        }, 2200);
      }
    }

    function resetTimer() {
      clearTimeout(timer);
      timer = null;
    }

    toggle.addEventListener('click', () => {
      playing = !playing;
      render();
      syncPlayback();
    });
    document.getElementById('traffic-next').addEventListener('click', () => {
      playing = false;
      resetTimer();
      step = (step + 1) % steps.length;
      render();
      positionPacket();
      syncPlayback();
    });
    document.getElementById('traffic-restart').addEventListener('click', () => {
      step = 0;
      playing = true;
      resetTimer();
      render();
      positionPacket();
      syncPlayback();
    });
    document.addEventListener('visibilitychange', syncPlayback);
    motion.addEventListener('change', () => {
      if (motion.matches) playing = false;
      render();
      positionPacket();
      syncPlayback();
    });
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(entries => {
        visible = entries[0].isIntersecting;
        syncPlayback();
      }, { threshold: 0 }).observe(map);
    } else visible = true;
    if ('ResizeObserver' in window) new ResizeObserver(() => positionPacket()).observe(map);
    else window.addEventListener('resize', () => positionPacket());
    status.hidden = false;
    demo.querySelector('.traffic-controls').hidden = false;
    packet.hidden = false;
    render();
    positionPacket();
    syncPlayback();
    return { render: () => { render(); positionPacket(); } };
  }

  traffic = setupTrafficDemo();
})();
