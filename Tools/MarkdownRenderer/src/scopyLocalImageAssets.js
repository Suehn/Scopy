export const BUNDLED_IMAGE_ASSETS = Object.freeze({
  "news-openai-hugging-face": "rich/news-openai-hugging-face.jpg",
  "news-openai-jalapeno": "rich/news-openai-jalapeno.jpg",
  "news-openai-kiro": "rich/news-openai-kiro.jpg",
  "image-group-chatgpt-search-button": "rich/image-group-chatgpt-search-button.jpg",
  "image-group-chatgpt-search-results": "rich/image-group-chatgpt-search-results.jpg",
  "weather-mostly-cloudy-light": "rich/weather-mostly-cloudy-light.png",
  "weather-sun-shower-light": "rich/weather-sun-shower-light.png",
  "favicon-elebank-150": "rich/favicon-elebank-150.png",
  "favicon-hsbc-hk-32": "rich/favicon-hsbc-hk-32.png",
  "favicon-help-openai-32": "rich/favicon-help-openai-32.png",
  "favicon-investing-32": "rich/favicon-investing-32.png",
  "favicon-openai-32": "rich/favicon-openai-32.png",
  "favicon-reuters-32": "rich/favicon-reuters-32.png"
});

const EXACT_REMOTE_IMAGE_ASSETS = Object.freeze({
  "https://images.ctfassets.net/kftzwdyauwt9/1lzvjTVvojn23RPUeYr51u/9e11ca889ec10a05e5601919b98c54d2/Sources_Sidebar.png?fm=webp&q=90&w=3840":
    "image-group-chatgpt-search-results",
  "https://images.ctfassets.net/kftzwdyauwt9/7LzxdzMcijUYHtIES6rmub/1dd3bc9f423a6b1cd5176936dbb029aa/Entry_Point.png?fm=webp&q=90&w=3840":
    "image-group-chatgpt-search-button"
});

const FAVICON_HOSTS = Object.freeze({
  "elebank.com": "favicon-elebank-150",
  "www.elebank.com": "favicon-elebank-150",
  "support.platform.elebank.com": "favicon-elebank-150",
  "hsbc.com.hk": "favicon-hsbc-hk-32",
  "www.hsbc.com.hk": "favicon-hsbc-hk-32",
  "openai.com": "favicon-openai-32",
  "www.openai.com": "favicon-openai-32",
  "help.openai.com": "favicon-help-openai-32",
  "investing.com": "favicon-investing-32",
  "www.investing.com": "favicon-investing-32",
  "reuters.com": "favicon-reuters-32",
  "www.reuters.com": "favicon-reuters-32"
});

export function bundledImagePath(asset) {
  return typeof asset === "string" && Object.hasOwn(BUNDLED_IMAGE_ASSETS, asset)
    ? BUNDLED_IMAGE_ASSETS[asset]
    : null;
}

export function bundledFaviconAssetForHost(host) {
  return typeof host === "string" && Object.hasOwn(FAVICON_HOSTS, host)
    ? FAVICON_HOSTS[host]
    : null;
}

export function bundledImageAssetForExactRemoteURL(url) {
  return typeof url === "string" && Object.hasOwn(EXACT_REMOTE_IMAGE_ASSETS, url)
    ? EXACT_REMOTE_IMAGE_ASSETS[url]
    : null;
}
