function expressionFor(strategy, value) {
  const quoted = JSON.stringify(value);
  if (strategy === 'getByRole') return `page.getByRole(${quoted})`;
  if (strategy === 'getByLabel') return `page.getByLabel(${quoted}, { exact: true })`;
  if (strategy === 'getByText') return `page.getByText(${quoted}, { exact: true })`;
  return `page.locator(${quoted})`;
}

function defaultDescriptor(strategy, value) {
  if (strategy === 'getByLabel') return { strategy, name: value, exact: true };
  if (strategy === 'getByRole') {
    const separator = String(value).indexOf(':');
    return separator < 0
      ? { strategy, role: value, name: null, exact: true }
      : { strategy, role: String(value).slice(0, separator), name: String(value).slice(separator + 1), exact: true };
  }
  if (strategy === 'getByText') return { strategy, text: value, exact: true };
  if (strategy === 'contenteditable') return { strategy, selector: '[contenteditable="true"]' };
  if (strategy === 'testId') return { strategy, value };
  if (strategy === 'css') return { strategy, selector: value };
  return { strategy, value };
}

export function candidate(strategy, value, create, { confidence = 'high', reason = 'Approved semantic locator.', expression = null, locator = null } = {}) {
  return { strategy, value, create, expression: expression ?? expressionFor(strategy, value), locator: locator ?? defaultDescriptor(strategy, value), confidence, reason };
}

export function resolveLocatorDescriptor(page, descriptor) {
  if (!descriptor || typeof descriptor !== 'object' || typeof descriptor.strategy !== 'string') return null;
  if (descriptor.strategy === 'getByLabel' && typeof descriptor.name === 'string') return page.getByLabel(descriptor.name, { exact: descriptor.exact !== false });
  if (descriptor.strategy === 'getByRole' && typeof descriptor.role === 'string' && (descriptor.name === null || typeof descriptor.name === 'string')) return page.getByRole(descriptor.role, { name: descriptor.name ?? undefined, exact: descriptor.exact !== false });
  if (descriptor.strategy === 'getByText' && typeof descriptor.text === 'string') return page.getByText(descriptor.text, { exact: descriptor.exact !== false });
  if (descriptor.strategy === 'testId' && typeof descriptor.value === 'string') return page.getByTestId(descriptor.value);
  if (descriptor.strategy === 'contenteditable' && descriptor.selector === '[contenteditable="true"]') return page.locator('[contenteditable="true"]');
  if (descriptor.strategy === 'css' && ['[data-testid="media-upload"]', '[data-testid="media-gallery"]'].includes(descriptor.selector)) return page.locator(descriptor.selector);
  return null;
}

export async function resolveCandidate(page, candidates) {
  for (const item of candidates) {
    const locator = item.create(page);
    const matchCount = await locator.count();
    const visibleIndexes = [];
    for (let index = 0; index < matchCount; index += 1) {
      if (await locator.nth(index).isVisible().catch(() => false)) visibleIndexes.push(index);
    }
    if (visibleIndexes.length === 1) {
      return {
        locator: locator.nth(visibleIndexes[0]),
        candidate: item,
        metadata: {
          strategy: item.strategy,
          expression: item.expression,
          matchCount: 1,
          unique: true,
          confidence: item.confidence,
          reason: item.reason,
        },
      };
    }
  }
  const first = candidates[0];
  return {
    locator: first?.create(page) ?? page.locator('does-not-exist'),
    candidate: first ?? null,
    metadata: first ? {
      strategy: first.strategy,
      expression: first.expression,
      matchCount: await (async () => {
        const locator = first.create(page);
        let visibleCount = 0;
        for (let index = 0; index < await locator.count(); index += 1) {
          if (await locator.nth(index).isVisible().catch(() => false)) visibleCount += 1;
        }
        return visibleCount;
      })(),
      unique: false,
      confidence: 'low',
      reason: 'No approved candidate uniquely matched the current DOM.',
    } : null,
  };
}

const role = (name, type) => candidate('getByRole', `${type}:${name}`, (page) => page.getByRole(type, { name, exact: true }), { expression: `page.getByRole("${type}", { name: ${JSON.stringify(name)}, exact: true })`, locator: { strategy: 'getByRole', role: type, name, exact: true } });
const label = (name) => candidate('getByLabel', name, (page) => page.getByLabel(name, { exact: true }), { locator: { strategy: 'getByLabel', name, exact: true } });
const text = (name, confidence = 'medium') => candidate('getByText', name, (page) => page.getByText(name, { exact: true }), { confidence, reason: 'Visible static value locator; not a generated CSS selector.', locator: { strategy: 'getByText', text: name, exact: true } });
const contentEditable = () => candidate('contenteditable', '[contenteditable="true"]', (page) => page.locator('[contenteditable="true"]'), { expression: 'page.locator(\'[contenteditable="true"]\')', reason: 'Stable semantic contenteditable locator uniquely matches the visible editor.', locator: { strategy: 'contenteditable', selector: '[contenteditable="true"]' } });

export function fieldCandidates(field, manifest = {}) {
  switch (field) {
    case 'title': return [label('Title *'), label('Title'), role('Title *', 'textbox'), role('Title', 'textbox'), text(manifest.title)];
    case 'shortDescription': return [label('Short description *'), label('Short description'), role('Short description *', 'textbox')];
    case 'longDescription': return [label('Description *'), label('Description'), role('Description *', 'textbox'), contentEditable()];
    case 'productType': return [label('Product type *'), label('Product type'), role('Product type *', 'combobox'), text(manifest.productType)];
    case 'category': return [role('Category selection', 'combobox'), label('Category *'), label('Category')];
    case 'tags': return [label('Tags *'), label('Tags'), role('Tags *', 'combobox')];
    case 'includedFormat': return [role('Unreal Engine', 'button')];
    case 'platforms': return [label('Supported development platforms *'), label('Supported development platforms')];
    case 'license': return [role('Standard License (Free or Paid)', 'radio'), label('Standard License (Free or Paid)')];
    case 'personalPriceUsd': return [label('Personal price *'), label('Personal price')];
    case 'professionalPriceUsd': return [label('Professional price *'), label('Professional price')];
    case 'matureContent': return [role('No, this listing does not contain mature content.', 'radio'), label('No, this listing does not contain mature content.')];
    case 'generatedWithAi': return [role('Yes, it was partly or fully created with generative AI', 'radio'), label('Yes, it was partly or fully created with generative AI')];
    case 'allowsUsageWithAi': return [role('Do not allow this product to be used by Generative AI Programs.', 'checkbox'), role('Do not allow this product to be used by Generative AI Programs.', 'radio'), label('Do not allow this product to be used by Generative AI Programs.')];
    case 'promotionalContent': return [role('Includes promotional content', 'checkbox'), label('Includes promotional content'), role('Includes promotional content', 'radio')];
    case 'forumPost': return [role('No, do not create a forum post', 'radio'), label('No, do not create a forum post')];
    case 'activation': return [label('Activation'), role('Activation', 'combobox'), role('Activation', 'textbox')];
    case 'documentationUrl': return [label('Documentation'), role(manifest.documentationUrl ?? '', 'link')];
    case 'supportUrl': return [label('Support'), role(manifest.supportUrl ?? '', 'link')];
    case 'technicalInformationFile': return [label('Technical Information'), label('Technical Details'), text('Technical Information')];
    case 'projectFileLink': return [label('Project file'), label('Project File Link'), text(manifest.projectFileLink ?? '')];
    default: return [];
  }
}

export function mediaCandidates({ fixture = false } = {}) {
  if (!fixture) return [];
  return [
    candidate('testId', 'media-gallery', (page) => page.getByTestId('media-gallery'), { expression: 'page.getByTestId("media-gallery")', locator: { strategy: 'testId', value: 'media-gallery' } }),
    candidate('css', '[data-testid="media-gallery"]', (page) => page.locator('[data-testid="media-gallery"]')),
  ];
}

export function saveCandidates() {
  return [role('Save', 'button'), role('Save draft', 'button'), role('Save Draft', 'button')];
}

export function submitCandidates() {
  return [role('Submit for review', 'button'), role('Submit for Review', 'button')];
}

export function listingEditUrl(listingId, origin = 'https://www.fab.com') {
  return `${origin.replace(/\/$/, '')}/portal/listings/${listingId}/edit`;
}

export function dangerousActionCandidates() {
  return [
    ['cancelSubmission', /cancel submission/i],
    ['deleteListing', /^delete listing$/i],
    ['unlist', /^unlist$/i],
    ['deleteFormat', /^delete product format$/i],
    ['upload', /^upload$/i],
    ['remove', /^remove$/i],
    ['replace', /^replace$/i],
    ['publish', /^publish$/i],
  ];
}
