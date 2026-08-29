const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// 1. 元素进入视口淡入显现 (Scroll Reveal)
if (!reduceMotion && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -6% 0px', threshold: 0.08 }
  );

  document.querySelectorAll('[data-reveal]').forEach((element) => observer.observe(element));
} else {
  document.querySelectorAll('[data-reveal]').forEach((element) => element.classList.add('is-visible'));
}

// 2. 页面内平滑滚动导航
document.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener('click', (event) => {
    const href = link.getAttribute('href');
    if (!href || href === '#' || href === '#top') {
      event.preventDefault();
      window.scrollTo({ top: 0, behavior: reduceMotion ? 'auto' : 'smooth' });
      return;
    }
    const target = document.querySelector(href);
    if (!target) return;
    event.preventDefault();
    target.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
  });
});

// 3. 真实操作演示视频控制 (Demo Player)
const demoVideo = document.querySelector('#product-demo-video');
const demoToggle = document.querySelector('.demo-toggle');

if (demoVideo && demoToggle) {
  const syncDemoButton = () => {
    const paused = demoVideo.paused;
    demoToggle.setAttribute('aria-label', paused ? '播放演示视频' : '暂停演示视频');
    demoToggle.setAttribute('aria-pressed', paused ? 'true' : 'false');
    const iconSpan = demoToggle.querySelector('span');
    if (iconSpan) {
      iconSpan.textContent = paused ? '▶' : 'Ⅱ';
    }
  };

  demoToggle.addEventListener('click', async () => {
    if (demoVideo.paused) {
      try {
        await demoVideo.play();
      } catch {
        syncDemoButton();
      }
    } else {
      demoVideo.pause();
    }
  });

  demoVideo.addEventListener('play', syncDemoButton);
  demoVideo.addEventListener('pause', syncDemoButton);

  if (reduceMotion) {
    demoVideo.pause();
  }
  syncDemoButton();
}

// 4. FAQ 手风琴互斥展开或优化体验
const faqDetails = document.querySelectorAll('.faq-list details');
faqDetails.forEach((targetDetail) => {
  targetDetail.addEventListener('toggle', () => {
    if (targetDetail.open) {
      faqDetails.forEach((otherDetail) => {
        if (otherDetail !== targetDetail && otherDetail.open) {
          otherDetail.removeAttribute('open');
        }
      });
    }
  });
});
