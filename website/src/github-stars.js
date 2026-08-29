(function initGitHubStars() {
  const repo = 'ohmyangboy/lives';
  const apiUrl = `https://api.github.com/repos/${repo}`;

  function formatStars(count) {
    if (typeof count !== 'number' || isNaN(count) || count <= 0) {
      return '';
    }
    if (count >= 1000) {
      return (count / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return String(count);
  }

  function applyStars(formattedCount) {
    if (!formattedCount) return;
    const starCounts = document.querySelectorAll('.gh-star-count');
    const starBadges = document.querySelectorAll('.gh-star-badge');
    starCounts.forEach((el) => {
      el.textContent = formattedCount;
    });
    starBadges.forEach((badge) => {
      badge.classList.add('is-visible');
    });
  }

  // 尝试读取本地缓存
  const cacheKey = `gh_stars_${repo}`;
  const cached = localStorage.getItem(cacheKey);
  if (cached) {
    try {
      const { stars, time } = JSON.parse(cached);
      if (Date.now() - time < 3600000 && stars) {
        applyStars(formatStars(stars));
        return;
      }
    } catch {}
  }

  fetch(apiUrl)
    .then((response) => {
      if (!response.ok) throw new Error('GitHub API request failed');
      return response.json();
    })
    .then((data) => {
      if (data && typeof data.stargazers_count === 'number') {
        const count = data.stargazers_count;
        localStorage.setItem(cacheKey, JSON.stringify({ stars: count, time: Date.now() }));
        const formatted = formatStars(count);
        if (formatted) {
          applyStars(formatted);
        }
      }
    })
    .catch(() => {
      // 保持静默
    });
})();
