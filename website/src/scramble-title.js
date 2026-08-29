/**
 * Lives — 3-Second Blur-to-Clear Live Focus Slogan
 * 模拟 Apple Live Photo 从 3 秒动态模糊/对焦到柔和定格为锐利封面的过程（无乱码）
 */

class LiveFocusSlogan {
  constructor(element, reduceMotion) {
    this.element = element;
    this.reduceMotion = reduceMotion;
    this.targetText = this.element.getAttribute('data-text') || this.element.textContent.trim();
    this.durationMs = 3000; // 3 秒实况时长
    this.startTime = null;
    this.animFrameId = null;
    this.titleContainer = this.element.closest('.scramble-title') || this.element;

    this.init();
  }

  init() {
    this.element.textContent = this.targetText;
    this.titleContainer.style.cursor = 'pointer';
    this.titleContainer.setAttribute('title', '点击重新播放 3 秒实况定格动效');

    this.titleContainer.addEventListener('click', () => this.play());
    this.titleContainer.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        this.play();
      }
    });

    // 初始加载时播放一次
    this.play();
  }

  play() {
    if (this.reduceMotion) {
      this.settle();
      return;
    }

    cancelAnimationFrame(this.animFrameId);
    this.startTime = performance.now();

    this.titleContainer.classList.remove('is-settled');
    this.titleContainer.classList.add('is-focusing');

    this.update();
  }

  update() {
    const now = performance.now();
    const elapsed = now - this.startTime;
    const progress = Math.min(elapsed / this.durationMs, 1);

    // 计算模糊度：从 7px 随着时间平滑衰减到 0px (easeOutCubic)
    const easeOutProgress = 1 - Math.pow(1 - progress, 3);
    const blurPx = Math.max(0, (1 - easeOutProgress) * 7.5).toFixed(2);
    const opacity = (0.7 + easeOutProgress * 0.3).toFixed(2);
    const letterSpacing = ((1 - easeOutProgress) * 0.04 - 0.035).toFixed(3);

    this.element.style.filter = `blur(${blurPx}px)`;
    this.element.style.opacity = opacity;
    this.element.style.letterSpacing = `${letterSpacing}em`;

    if (progress < 1) {
      this.animFrameId = requestAnimationFrame(() => this.update());
    } else {
      this.settle();
    }
  }

  settle() {
    this.element.style.filter = 'none';
    this.element.style.opacity = '1';
    this.element.style.letterSpacing = '-0.035em';

    this.titleContainer.classList.remove('is-focusing');
    this.titleContainer.classList.add('is-settled');
  }
}

document.addEventListener('DOMContentLoaded', () => {
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const targetEl = document.querySelector('.scramble-target');

  if (targetEl) {
    new LiveFocusSlogan(targetEl, reduceMotion);
  }
});
