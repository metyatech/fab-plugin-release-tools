const TAG_UID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TAG_SEARCH_SELECTOR = 'input[role="combobox"][placeholder="Search a tag"]';

function clean(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

function tagInput(page) {
  return page.locator(TAG_SEARCH_SELECTOR);
}

async function exactVisibleOption(page, label) {
  const options = page.locator('button[role="treeitem"]:visible');
  const matches = [];
  for (let index = 0; index < await options.count(); index += 1) {
    const option = options.nth(index);
    if (clean(await option.innerText().catch(() => '')) === label) matches.push(option);
  }
  if (matches.length !== 1) return { ok: false, reason: `Fab tag ${label} visible exact option count was ${matches.length}.` };
  if (await matches[0].isDisabled().catch(() => false) || await matches[0].getAttribute('aria-disabled') === 'true') {
    return { ok: false, reason: `Fab tag ${label} exact option was disabled.` };
  }
  return { ok: true, locator: matches[0] };
}

async function waitForExactVisibleOption(page, label, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last = { ok: false, reason: `Fab tag ${label} exact option did not become visible.` };
  while (Date.now() < deadline) {
    last = await exactVisibleOption(page, label);
    if (last.ok || /exact option count was [2-9]/.test(last.reason ?? '')) return last;
    await page.waitForTimeout(100);
  }
  return last;
}

async function autocomplete(page, query) {
  return page.evaluate(async (value) => {
    const response = await fetch(`/i/tags/autocomplete?q=${encodeURIComponent(value)}`, { credentials: 'same-origin' });
    let body;
    try { body = await response.json(); } catch { body = null; }
    return { status: response.status, results: Array.isArray(body?.results) ? body.results : [] };
  }, query);
}

export async function resolveFabTagIdentities(page, desiredTags) {
  if (!Array.isArray(desiredTags) || desiredTags.length === 0) return { ok: false, reason: 'Desired Fab tags were empty.' };
  const duplicateNames = desiredTags.filter((value, index) => desiredTags.indexOf(value) !== index);
  if (duplicateNames.length > 0) return { ok: false, reason: `Desired Fab tags contained duplicates: ${[...new Set(duplicateNames)].join(', ')}.` };
  const input = tagInput(page);
  if (await input.count() !== 1) return { ok: false, reason: 'Fab tag Search a tag input was not unique.' };
  if (await input.isDisabled().catch(() => true) || await input.getAttribute('aria-disabled') === 'true') return { ok: false, reason: 'Fab tag Search a tag input was disabled.' };

  const identities = [];
  for (const desired of desiredTags) {
    const label = clean(desired);
    if (!label) return { ok: false, reason: 'A desired Fab tag was blank.' };
    const response = await autocomplete(page, label);
    if (response.status !== 200) return { ok: false, reason: `Fab tag autocomplete for ${label} returned HTTP ${response.status}.` };
    const exactApi = response.results.filter((item) => item?.name === label && TAG_UID_PATTERN.test(String(item?.uid ?? '')));
    if (exactApi.length !== 1) return { ok: false, reason: `Fab tag autocomplete exact identity count for ${label} was ${exactApi.length}.` };
    await input.fill(label);
    const option = await waitForExactVisibleOption(page, label);
    await input.fill('');
    if (!option.ok) return option;
    identities.push({ label, uid: String(exactApi[0].uid), slug: exactApi[0].slug ?? null });
  }
  return { ok: true, identities };
}

function setEqual(left, right) {
  return left.length === right.length && [...left].sort().every((value, index) => value === [...right].sort()[index]);
}

export async function persistListingTags(page, { guard, contract, currentTagIds = [], identities, onMutation = null } = {}) {
  if (!guard || !contract || !Array.isArray(identities) || identities.length === 0) throw new Error('A guarded Fab tag contract and resolved identities are required.');
  if (!Array.isArray(currentTagIds) || currentTagIds.some((id) => !TAG_UID_PATTERN.test(String(id)))) throw new Error('Current Fab tag identities were not proven as UUIDs.');
  const input = tagInput(page);
  if (await input.count() !== 1 || await input.isDisabled().catch(() => true)) throw new Error('Fab tag Search a tag input is not uniquely writable.');
  const endpoint = `${contract.origin}/i/portal/listings/${contract.listingId}`;
  const requests = [];
  let selected = [...currentTagIds];
  const before = guard.summary().networkMutationRequestsObserved;
  const beforeRequestCount = guard.summary().requests.length;
  guard.setPhase('listing-tags-save');
  try {
    for (const identity of identities) {
      if (selected.includes(identity.uid)) continue;
      const next = [...selected, identity.uid];
      contract.expectedTagIds = next;
      const requestPromise = page.waitForRequest((request) => request.method().toUpperCase() === 'PATCH' && request.url() === endpoint, { timeout: 5000 }).catch(() => null);
      const responsePromise = page.waitForResponse((response) => response.request().method().toUpperCase() === 'PATCH' && response.url() === endpoint, { timeout: 5000 }).catch(() => null);
      await input.fill(identity.label);
      const option = await waitForExactVisibleOption(page, identity.label);
      if (!option.ok) throw new Error(option.reason);
      await option.locator.click();
      const request = await requestPromise;
      const response = await responsePromise;
      if (!request || !response || response.status() < 200 || response.status() >= 300) throw new Error(`Fab tag ${identity.label} did not produce a successful exact PATCH.`);
      requests.push({ request, response, expectedTagIds: [...next] });
      selected = next;
      contract.expectedTagIds = null;
      await page.waitForTimeout(120);
      const countText = clean(await page.locator('#tagsCount').textContent().catch(() => ''));
      if (countText !== `${selected.length} / 25`) throw new Error(`Fab tag count did not read back as ${selected.length} / 25.`);
      await onMutation?.({ request, response, expectedTagIds: [...selected] });
    }
    const summary = guard.summary();
    const delta = summary.networkMutationRequestsObserved - before;
    const deltaRecords = summary.requests.slice(beforeRequestCount);
    const allowed = deltaRecords.filter((item) => item.intent === 'listing-tags-save' && !item.blocked);
    const blocked = deltaRecords.filter((item) => item.blocked);
    if (delta !== identities.filter((item) => !currentTagIds.includes(item.uid)).length || allowed.length !== delta || blocked.length !== 0) {
      throw new Error(`Fab tag mutation count was not exact: observed=${delta}, allowed=${allowed.length}, blocked=${blocked.length}.`);
    }
    if (!setEqual(selected, identities.map((item) => item.uid))) throw new Error('Fab tag selection did not equal the exact resolved desired identity set.');
    return { mutationCount: delta, allowedMutationCount: allowed.length, blockedMutationCount: blocked.length, requests: deltaRecords, finalTagIds: selected };
  } finally {
    contract.expectedTagIds = null;
    guard.setPhase('stage');
  }
}

export { TAG_SEARCH_SELECTOR, TAG_UID_PATTERN };
