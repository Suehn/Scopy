const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/u;
const ABSOLUTE_HTTP_PREFIX = /^https?:\/\/[^/]/i;
const ASCII_HOSTNAME = /^[a-z0-9.:-]+$/i;
const MAX_EXTERNAL_URL_UTF8_BYTES = 8_192;

export function isValidExternalHTTPURL(value) {
  if (typeof value !== "string"
    || value.length === 0
    || new TextEncoder().encode(value).byteLength > MAX_EXTERNAL_URL_UTF8_BYTES
    || value !== value.trim()
    || !ABSOLUTE_HTTP_PREFIX.test(value)
    || CONTROL_CHARACTERS.test(value)) {
    return false;
  }
  try {
    const decoded = decodeURIComponent(value);
    if (CONTROL_CHARACTERS.test(decoded)) {
      return false;
    }
    const url = new URL(value);
    return (url.protocol === "http:" || url.protocol === "https:")
      && Boolean(url.hostname)
      && ASCII_HOSTNAME.test(url.hostname)
      && /[a-z0-9]/i.test(url.hostname)
      && !url.username
      && !url.password;
  } catch {
    return false;
  }
}
