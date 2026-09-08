// Narrow product DTO extraction: no HAR, cookies, headers or arbitrary API URLs.
function purchaseUrl(value) {
  try {
    const url = new URL(value, 'https://www.target.com');
    if (url.protocol !== 'https:' || !['www.target.com', 'target.com'].includes(url.hostname) ||
        url.username || url.password || url.port || !/^\/p\/(?:[^/]+\/)?-\/A-\d+\/?$/.test(url.pathname)) return null;
    return url.href;
  } catch { return null; }
}
function imageUrl(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.hostname !== 'target.scene7.com' || url.username || url.password ||
        url.port || !url.pathname.startsWith('/is/image/Target/')) return null;
    return url.href;
  } catch { return null; }
}
function extractProducts(value) {
  const products = new Map();
  let visited = 0;
  function walk(node, depth) {
    if (++visited > 10000 || depth > 12 || products.size >= 50 || !node || typeof node !== 'object') return;
    if (Array.isArray(node)) { for (const item of node) walk(item, depth + 1); return; }
    const item = node.item;
    if (item?.product_description && !JSON.stringify(node.labels ?? []).toLowerCase().includes('sponsored')) {
      const images = item.enrichment?.images;
      const rawImage = images?.primary_image_url ?? images?.primary_image ??
        (images?.primary_image_id ? 'https://target.scene7.com/is/image/Target/' +
          (String(images.primary_image_id).startsWith('GUEST_') ? images.primary_image_id : 'GUEST_' + images.primary_image_id) : null);
      add(item.product_description.title, item.buy_url, rawImage, node.price?.current_retail);
    }
    const type = node['@type'];
    if (type === 'Product' || (Array.isArray(type) && type.includes('Product'))) {
      const offer = Array.isArray(node.offers) ? node.offers[0] : node.offers;
      const image = Array.isArray(node.image) ? node.image[0] : node.image;
      if (!offer?.priceCurrency || offer.priceCurrency === 'USD') add(node.name, node.url ?? offer?.url,
        typeof image === 'object' ? image?.url : image, offer?.price);
    }
    for (const child of Object.values(node)) walk(child, depth + 1);
  }
  function add(name, rawUrl, rawImage, rawPrice) {
    const targetUrl = purchaseUrl(rawUrl), image = imageUrl(rawImage);
    if (typeof name !== 'string' || !name.trim() || name.length > 500 || !targetUrl || !image) return;
    const price = Number(rawPrice);
    products.set(targetUrl, {name: name.trim(), target_url: targetUrl, image_url: image,
      price: Number.isFinite(price) && price > 0 && price <= 100000 ? price : 0});
  }
  walk(value, 0);
  return [...products.values()];
}
module.exports = {purchaseUrl, imageUrl, extractProducts};
