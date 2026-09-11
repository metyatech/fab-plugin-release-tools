const HTTPS_PROTOCOL = 'https:';

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function fail(message, field = 'descriptionLinks') {
  throw new Error(`${field} invalid: ${message}`);
}

function normalizeHref(value) {
  if (typeof value !== 'string' || value.trim() === '') return null;
  try {
    const url = new URL(value);
    if (url.protocol !== HTTPS_PROTOCOL) return null;
    return url.href;
  } catch {
    return null;
  }
}

function countOccurrences(text, needle) {
  let count = 0;
  let offset = 0;
  const urlText = normalizeHref(needle) !== null;
  while (true) {
    const found = text.indexOf(needle, offset);
    if (found < 0) return count;
    const before = found === 0 ? '' : text[found - 1];
    const after = text[found + needle.length] ?? '';
    if (!urlText || (!/[A-Za-z0-9/?#._~%:-]/.test(before) && !/[A-Za-z0-9/?#._~%:-]/.test(after))) count += 1;
    offset = found + needle.length;
  }
}

function hasMarkdownLinkSyntax(text, link) {
  return text.includes(`[${link.text}](${link.href})`);
}

export function validateDescriptionLinkShape(links, field = 'descriptionLinks') {
  if (!Array.isArray(links)) fail('must be an array.', field);
  const seenText = new Set();
  const seenHref = new Set();
  return links.map((link, index) => {
    if (!isRecord(link) || Object.keys(link).some((key) => !['text', 'href'].includes(key)) || !Object.hasOwn(link, 'text') || !Object.hasOwn(link, 'href')) {
      fail(`entry ${index} must contain only text and href.`, field);
    }
    if (typeof link.text !== 'string' || link.text.trim() === '') fail(`entry ${index}.text must be non-blank text.`, field);
    const normalizedHref = normalizeHref(link.href);
    if (!normalizedHref) fail(`entry ${index}.href must be an absolute HTTPS URL.`, field);
    if (seenText.has(link.text)) fail(`entry ${index}.text is duplicated.`, field);
    if (seenHref.has(normalizedHref)) fail(`entry ${index}.href is duplicated.`, field);
    seenText.add(link.text);
    seenHref.add(normalizedHref);
    return { text: link.text, href: normalizedHref };
  });
}

export function validateDescriptionLinks(longDescription, links, field = 'descriptionLinks') {
  if (typeof longDescription !== 'string') fail('longDescription must be text when validating configured links.', field);
  const validated = validateDescriptionLinkShape(links, field);
  for (const link of validated) {
    if (hasMarkdownLinkSyntax(longDescription, link)) fail(`literal Markdown link syntax is not allowed for configured link text: ${link.text}`, field);
    if (countOccurrences(longDescription, link.text) !== 1) fail(`link text must occur exactly once in longDescription: ${link.text}`, field);
  }
  return validated;
}

function comparableLinks(value) {
  if (!Array.isArray(value)) return null;
  try {
    return validateDescriptionLinkShape(value).map(({ text, href }) => `${text}\u0000${href}`).sort();
  } catch {
    return null;
  }
}

export function compareDescriptionLinks(observed, desired) {
  const actual = comparableLinks(observed);
  const expected = comparableLinks(desired);
  if (!actual || !expected) return 'MISMATCH';
  return JSON.stringify(actual) === JSON.stringify(expected) ? 'MATCH' : 'MISMATCH';
}

export { normalizeHref };
