// Scientific source repairs temporarily replace protected syntax with collision-free tokens.
// An outer island can only refer to islands already registered, so resolve those references
// when storing it. Restoring a document then takes one scan, independent of its island count.
export function createSourcePlaceholders(source, marker, saltWidth = 0) {
  let salt = 0;
  let prefix;
  do {
    prefix = marker + String(salt).padStart(saltWidth, "0");
    salt += 1;
  } while (source.includes(prefix));

  const originals = [];
  const tokenPattern = new RegExp(`${prefix}(0|[1-9]\\d*)X`, "g");
  const restore = (text) => text.replace(tokenPattern, (token, index) => originals[Number(index)] ?? token);

  return {
    protect(original) {
      const token = `${prefix}${originals.length}X`;
      originals.push(restore(original));
      return token;
    },
    restore
  };
}
