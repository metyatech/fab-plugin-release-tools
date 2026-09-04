const STANDARD_LICENSE_LABEL = 'Standard License (Free or Paid)';

async function uniqueVisibleRadio(page) {
  const locator = page.getByRole('radio', { name: STANDARD_LICENSE_LABEL, exact: true });
  const visible = [];
  for (let index = 0; index < await locator.count(); index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) visible.push(locator.nth(index));
  }
  if (visible.length !== 1) throw new Error(`Standard license radio must have exactly one visible match; found ${visible.length}.`);
  return visible[0];
}

export async function persistStandardLicense(page, { guard, contract, onMutation = null } = {}) {
  if (!guard || !contract) throw new Error('A guarded listing license contract is required.');
  const radio = await uniqueVisibleRadio(page);
  if (await radio.isDisabled().catch(() => true)) throw new Error('Standard license radio is disabled.');
  if (await radio.isChecked()) throw new Error('Standard license is already selected; no license mutation is required.');

  const endpoint = `${contract.origin}/i/portal/listings/${contract.listingId}`;
  const requestPromise = page.waitForRequest((request) => request.method().toUpperCase() === 'PATCH' && request.url() === endpoint, { timeout: 5000 }).catch(() => null);
  const responsePromise = page.waitForResponse((response) => response.request().method().toUpperCase() === 'PATCH' && response.url() === endpoint, { timeout: 5000 }).catch(() => null);
  const beforeSummary = guard.summary();
  const before = beforeSummary.networkMutationRequestsObserved;
  const beforeRequestCount = beforeSummary.requests.length;
  guard.setPhase('listing-license-save');
  try {
    await radio.click();
    const request = await requestPromise;
    const response = await responsePromise;
    await page.waitForTimeout(100);
    const summary = guard.summary();
    const requests = summary.requests.slice(beforeRequestCount);
    const delta = summary.networkMutationRequestsObserved - before;
    if (!request || delta !== 1) throw new Error(`Expected exactly one guarded standard-license PATCH; observed ${delta}.`);
    if (summary.networkMutationRequestsBlocked !== 0) throw new Error('Unexpected mutation was blocked during standard-license persistence.');
    if (!response || response.status() < 200 || response.status() >= 300) throw new Error(`Standard-license persistence did not return a successful HTTP response: ${response?.status() ?? 'none'}.`);
    if (!await radio.isChecked()) throw new Error('Standard license radio did not remain selected after persistence.');
    await onMutation?.({ request, response, requests });
    return { mutationCount: delta, responseStatus: response.status(), requests };
  } finally {
    guard.setPhase('stage');
  }
}

export { STANDARD_LICENSE_LABEL };
