const BLOCK_TYPES = new Set(['paragraph', 'heading', 'unordered_list', 'ordered_list']);
const INLINE_MARKS = new Set(['bold', 'italic', 'underline', 'link']);
export const MARK_ORDER = ['bold', 'italic', 'underline', 'link'];

function fail(field, message) {
  throw new Error(`${field} is invalid: ${message}`);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function exactKeys(value, allowed, field) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(field, `unsupported property ${key}`);
  }
}

function requireText(value, field) {
  if (typeof value !== 'string' || value.trim() === '') fail(field, 'text must be non-blank');
}

function canonicalizeMarks(marks) {
  return [...marks].sort((left, right) => MARK_ORDER.indexOf(left) - MARK_ORDER.indexOf(right));
}

function normalizeHref(value, field) {
  requireText(value, field);
  let url;
  try { url = new URL(value); } catch { fail(field, 'href must be an absolute HTTPS URL'); }
  if (url.protocol !== 'https:') fail(field, 'href must be an absolute HTTPS URL');
  return url.href;
}

function validateRun(run, field) {
  if (!isRecord(run)) fail(field, 'run must be an object');
  exactKeys(run, new Set(['text', 'marks', 'href']), field);
  requireText(run.text, `${field}.text`);
  const marks = run.marks ?? [];
  if (!Array.isArray(marks) || marks.some((mark) => typeof mark !== 'string' || !INLINE_MARKS.has(mark))) {
    fail(`${field}.marks`, 'must contain only supported marks');
  }
  if (new Set(marks).size !== marks.length) fail(`${field}.marks`, 'must not contain duplicates');
  const canonicalMarks = canonicalizeMarks(marks);
  const linked = canonicalMarks.includes('link');
  if (linked) {
    if (!Object.prototype.hasOwnProperty.call(run, 'href')) fail(field, 'link runs require href');
    run.href = normalizeHref(run.href, `${field}.href`);
  } else if (Object.prototype.hasOwnProperty.call(run, 'href')) {
    fail(field, 'href is only allowed on link runs');
  }
  return { text: run.text, ...(canonicalMarks.length ? { marks: canonicalMarks } : {}), ...(linked ? { href: run.href } : {}) };
}

function validateRuns(value, field) {
  if (!Array.isArray(value) || value.length === 0) fail(field, 'must be a non-empty array');
  return value.map((run, index) => validateRun(run, `${field}[${index}]`));
}

export function validateRichText(value, field = 'richText') {
  if (!isRecord(value)) fail(field, 'must be an object');
  exactKeys(value, new Set(['blocks']), field);
  if (!Array.isArray(value.blocks) || value.blocks.length === 0) fail(`${field}.blocks`, 'must be a non-empty array');
  const blocks = value.blocks.map((block, index) => {
    const blockField = `${field}.blocks[${index}]`;
    if (!isRecord(block)) fail(blockField, 'must be an object');
    requireText(block.type, `${blockField}.type`);
    if (!BLOCK_TYPES.has(block.type)) fail(`${blockField}.type`, 'unsupported block type');
    if (block.type === 'heading') {
      exactKeys(block, new Set(['type', 'level', 'runs']), blockField);
      if (!Number.isInteger(block.level) || block.level < 1 || block.level > 6) fail(`${blockField}.level`, 'must be an integer from 1 to 6');
      return { type: block.type, level: block.level, runs: validateRuns(block.runs, `${blockField}.runs`) };
    }
    if (block.type === 'paragraph') {
      exactKeys(block, new Set(['type', 'runs']), blockField);
      return { type: block.type, runs: validateRuns(block.runs, `${blockField}.runs`) };
    }
    exactKeys(block, new Set(['type', 'items']), blockField);
    if (!Array.isArray(block.items) || block.items.length === 0) fail(`${blockField}.items`, 'must be a non-empty array');
    return {
      type: block.type,
      items: block.items.map((item, itemIndex) => validateRuns(item, `${blockField}.items[${itemIndex}]`)),
    };
  });
  return { blocks };
}

function runText(runs) {
  return runs.map((run) => run.text).join('');
}

export function richTextToPlainText(value) {
  const model = validateRichText(value);
  return model.blocks.map((block) => {
    if (block.type === 'paragraph' || block.type === 'heading') return runText(block.runs);
    return block.items.map((item, index) => block.type === 'unordered_list'
      ? `- ${runText(item)}`
      : `${index + 1}. ${runText(item)}`).join('\n');
  }).join('\n\n');
}

export function richTextLinks(value) {
  const model = validateRichText(value);
  const links = [];
  const collect = (runs) => {
    for (const run of runs) if (run.marks?.includes('link')) links.push({ text: run.text, href: run.href });
  };
  for (const block of model.blocks) collect(block.runs ?? block.items.flat());
  return links;
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

export function compareRichText(actual, expected) {
  try {
    const actualModel = validateRichText(actual, 'actual richText');
    const expectedModel = validateRichText(expected, 'expected richText');
    return sameJson(actualModel, expectedModel) && sameJson(
      normalizeVisibleText(richTextToPlainText(actualModel)),
      normalizeVisibleText(richTextToPlainText(expectedModel)),
    ) ? 'MATCH' : 'MISMATCH';
  } catch {
    return 'MISMATCH';
  }
}

function normalizeVisibleText(value) {
  return String(value ?? '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ')
    .split('\n').map((line) => line.replace(/[ \t]+/g, ' ').trim()).join('\n')
    .replace(/\n{3,}/g, '\n\n').trim();
}

function parseEditorDom(root) {
  const unsupported = (message) => ({ unsupported: message });
  const markOrder = ['bold', 'italic', 'underline', 'link'];
  const canonicalize = (marks) => [...marks].sort((left, right) => markOrder.indexOf(left) - markOrder.indexOf(right));
  const same = (left, right) => JSON.stringify(left) === JSON.stringify(right);
  const mergeSemanticRuns = (runs) => {
    const merged = [];
    for (const run of runs) {
      if (run.marks) run.marks = canonicalize(run.marks);
      const previous = merged.at(-1);
      if (previous && same(previous.marks ?? [], run.marks ?? []) && previous.href === run.href) previous.text += run.text;
      else merged.push(run);
    }
    return merged;
  };
  const textFrom = (node, marks = [], href = undefined) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const text = node.nodeValue?.replace(/\u00a0/g, ' ') ?? '';
      return text ? [{ text, ...(marks.length ? { marks: [...marks] } : {}), ...(href ? { href } : {}) }] : [];
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return [];
    const tag = node.tagName.toLowerCase();
    if (tag === 'br') return [{ text: '\n', ...(marks.length ? { marks: [...marks] } : {}), ...(href ? { href } : {}) }];
    let nextMarks = marks;
    let nextHref = href;
    if (tag === 'strong' || tag === 'b') nextMarks = [...marks, 'bold'];
    else if (tag === 'em' || tag === 'i') nextMarks = [...marks, 'italic'];
    else if (tag === 'u') nextMarks = [...marks, 'underline'];
    else if (tag === 'a') {
      nextMarks = [...marks, 'link'];
      try { nextHref = new URL(node.getAttribute('href') ?? '', document.baseURI).href; } catch { return unsupported('link href is not an absolute URL'); }
      if (!nextHref.startsWith('https://')) return unsupported('link href is not HTTPS');
    } else if (!['span'].includes(tag)) return unsupported(`unsupported inline element ${tag}`);
    if (tag === 'span' && node.getAttribute('style')?.trim()) return unsupported('styled spans are outside the contract');
    const values = [];
    for (const child of node.childNodes) {
      const childValue = textFrom(child, nextMarks, nextHref);
      if (childValue?.unsupported) return childValue;
      values.push(...childValue);
    }
    return values;
  };
  const runs = (element) => {
    const values = [];
    for (const child of element.childNodes) {
      const childValue = textFrom(child);
      if (childValue?.unsupported) return childValue;
      values.push(...childValue);
    }
    return mergeSemanticRuns(values);
  };
  const blocks = [];
  for (const child of root.childNodes) {
    if (child.nodeType === Node.TEXT_NODE && child.textContent.trim() === '') continue;
    if (child.nodeType !== Node.ELEMENT_NODE) return unsupported('editor contains a non-semantic top-level node');
    const tag = child.tagName.toLowerCase();
    if (tag === 'p' || /^h[1-6]$/.test(tag)) {
      const value = runs(child);
      if (value?.unsupported) return value;
      blocks.push(tag === 'p' ? { type: 'paragraph', runs: value } : { type: 'heading', level: Number(tag.slice(1)), runs: value });
    } else if (tag === 'ul' || tag === 'ol') {
      const items = [];
      for (const item of child.children) {
        if (item.tagName.toLowerCase() !== 'li') return unsupported('list contains a non-li child');
        const value = runs(item);
        if (value?.unsupported) return value;
        items.push(value);
      }
      if (items.length === 0) return unsupported('empty list');
      blocks.push({ type: tag === 'ul' ? 'unordered_list' : 'ordered_list', items });
    } else return unsupported(`unsupported block element ${tag}`);
  }
  if (blocks.length === 0) return unsupported('editor has no semantic blocks');
  return { blocks };
}

export async function readRichTextFromEditor(locator) {
  const result = await locator.evaluate(parseEditorDom);
  if (result?.unsupported) throw new Error(`Fab rich editor could not be read semantically: ${result.unsupported}`);
  const model = validateRichText(result, 'portal richText');
  return { model, visibleText: richTextToPlainText(model), links: richTextLinks(model) };
}

export const SUPPORTED_BLOCK_FORMATS = ['paragraph', 'heading', 'unordered_list', 'ordered_list'];
export const SUPPORTED_INLINE_FORMATS = ['plain text', 'bold', 'italic', 'underline', 'link'];
export const UNSUPPORTED_FORMATS = ['color', 'quote', 'raw HTML', 'styled spans'];
