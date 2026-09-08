/* Shared by the worker and dependency-free Node tests. */
globalThis.CuratorProtocol = Object.freeze({
  targetUrl(value, productOnly = false) {
    if (typeof value !== 'string' || /[\x00-\x20\x7f]/.test(value)) return null;
    try {
      const url = new URL(value);
      if (url.protocol !== 'https:' || !['target.com', 'www.target.com'].includes(url.hostname) ||
          url.username || url.password || url.port) return null;
      if (productOnly && !/^\/p\/(?:[^/]+\/)?-\/A-\d+\/?$/.test(url.pathname)) return null;
      return url;
    } catch { return null; }
  },
  searchUrl(query) {
    if (typeof query !== 'string' || !query.trim() || query.length > 500) throw new Error('잘못된 검색어입니다.');
    return 'https://www.target.com/s?searchTerm=' + encodeURIComponent(query.trim());
  },
  operationId() {
    return Array.from(crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, '0')).join('');
  },
  nextPending(project, afterId) {
    const index = project.entries.findIndex(e => e.id === afterId);
    const ordered = [...project.entries.slice(index + 1), ...project.entries.slice(0, index + 1)];
    return ordered.find(e => e.status === 'pending') ?? null;
  },
});
