const STANDARD_LICENSE_LABEL = 'Standard License (Free or Paid)';
const PRICE_CURRENCY = 'USD';

function priceLabel(amount, currency = PRICE_CURRENCY) {
  return `${Number(amount).toFixed(2)} (${currency})`;
}

async function uniqueVisible(locator, description) {
  const visible = [];
  for (let index = 0; index < await locator.count(); index += 1) {
    if (await locator.nth(index).isVisible().catch(() => false)) visible.push(locator.nth(index));
  }
  if (visible.length !== 1) throw new Error(`${description} must have exactly one visible match; found ${visible.length}.`);
  return visible[0];
}

function parseLicensePayload(request) {
  try {
    const body = JSON.parse(request.postData() ?? '{}');
    return body && typeof body === 'object' && Array.isArray(body.licenses) ? body.licenses : null;
  } catch {
    return null;
  }
}

async function exactPriceOption(page, amount, currency) {
  const option = await uniqueVisible(
    page.getByRole('option', { name: priceLabel(amount, currency), exact: true }),
    `Price option ${priceLabel(amount, currency)}`,
  );
  const priceTierId = await option.getAttribute('data-value');
  if (!priceTierId) throw new Error(`Price option ${priceLabel(amount, currency)} had no data-value identity.`);
  return { option, priceTierId };
}

async function waitForListingPatch(page, endpoint) {
  return page.waitForRequest(
    (request) => request.method().toUpperCase() === 'PATCH' && request.url() === endpoint,
    { timeout: 5000 },
  ).catch(() => null);
}

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

export async function persistStandardLicensePricing(page, { guard, contract, onMutation = null } = {}) {
  if (!guard || !contract) throw new Error('A guarded listing license pricing contract is required.');
  if (!Array.isArray(contract.licensePayload) || contract.licensePayload.length !== 2) throw new Error('License pricing contract must contain exactly Personal and Professional entries.');
  const radio = await uniqueVisible(page.getByRole('radio', { name: STANDARD_LICENSE_LABEL, exact: true }), 'Standard license radio');
  if (await radio.isDisabled().catch(() => true)) throw new Error('Standard license radio is disabled.');
  if (await radio.isChecked()) throw new Error('Standard license is already selected; no license pricing mutation is required.');

  const endpoint = `${contract.origin}/i/portal/listings/${contract.listingId}`;
  const before = guard.summary();
  const beforeObserved = before.networkMutationRequestsObserved;
  const beforeRequestCount = before.requests.length;
  const requests = [];
  guard.setPhase('listing-license-pricing-save');
  try {
    let requestPromise = waitForListingPatch(page, endpoint);
    await radio.click();
    const licenseOnlyRequest = await requestPromise;
    if (!licenseOnlyRequest) throw new Error('Standard license selection did not produce the expected listing PATCH.');
    requests.push({ request: licenseOnlyRequest, licenses: parseLicensePayload(licenseOnlyRequest) });
    if (!Array.isArray(requests[0].licenses) || requests[0].licenses.length !== 0) throw new Error('Standard license selection produced an unexpected non-empty license payload.');

    const personalInput = await uniqueVisible(page.getByLabel('Personal price *', { exact: true }), 'Personal price control');
    await personalInput.click();
    const personalOption = await exactPriceOption(page, contract.personalPriceUsd, contract.currency ?? PRICE_CURRENCY);
    requestPromise = waitForListingPatch(page, endpoint);
    await personalOption.option.click();
    const personalRequest = await requestPromise;
    if (!personalRequest) throw new Error('Personal price selection did not produce the expected listing PATCH.');
    const personalLicenses = parseLicensePayload(personalRequest);
    requests.push({ request: personalRequest, licenses: personalLicenses });
    const expectedPersonal = contract.licensePayload[0];
    if (!Array.isArray(personalLicenses) || personalLicenses.length !== 1 || JSON.stringify(personalLicenses[0]) !== JSON.stringify(expectedPersonal)) throw new Error('Personal price selection produced an unexpected partial license payload.');

    const professionalInput = await uniqueVisible(page.getByLabel('Professional price *', { exact: true }), 'Professional price control');
    await professionalInput.click();
    const professionalOption = await exactPriceOption(page, contract.professionalPriceUsd, contract.currency ?? PRICE_CURRENCY);
    if (professionalOption.priceTierId !== contract.licensePayload[1].priceTierId) throw new Error('Professional price option identity did not match the pricing contract.');
    if (personalOption.priceTierId !== contract.licensePayload[0].priceTierId) throw new Error('Personal price option identity did not match the pricing contract.');
    requestPromise = waitForListingPatch(page, endpoint);
    const responsePromise = page.waitForResponse(
      (response) => response.request().method().toUpperCase() === 'PATCH' && response.url() === endpoint,
      { timeout: 5000 },
    ).catch(() => null);
    await professionalOption.option.click();
    const completeRequest = await requestPromise;
    const response = await responsePromise;
    const completeLicenses = parseLicensePayload(completeRequest);
    requests.push({ request: completeRequest, response, licenses: completeLicenses });
    if (!completeRequest || !response || response.status() < 200 || response.status() >= 300) throw new Error(`Complete license pricing persistence did not return a successful HTTP response: ${response?.status() ?? 'none'}.`);
    if (!Array.isArray(completeLicenses) || JSON.stringify(completeLicenses) !== JSON.stringify(contract.licensePayload)) throw new Error('Complete license pricing request did not match the exact contract.');

    await page.waitForTimeout(150);
    const summary = guard.summary();
    const delta = summary.networkMutationRequestsObserved - beforeObserved;
    const deltaRecords = summary.requests.slice(beforeRequestCount);
    const allowed = deltaRecords.filter((item) => item.intent === 'listing-license-pricing-save' && !item.blocked);
    const blocked = deltaRecords.filter((item) => item.blocked);
    if (delta !== 3 || allowed.length !== 1 || blocked.length !== 2) throw new Error(`Expected two blocked incomplete requests and one allowed complete request; observed ${delta} mutations.`);
    if (!await radio.isChecked()) throw new Error('Standard license radio did not remain selected after pricing persistence.');
    if (await page.getByPlaceholder(priceLabel(contract.personalPriceUsd, contract.currency ?? PRICE_CURRENCY), { exact: true }).count() !== 1) throw new Error('Personal price did not remain at the contracted value.');
    if (await page.getByPlaceholder(priceLabel(contract.professionalPriceUsd, contract.currency ?? PRICE_CURRENCY), { exact: true }).count() !== 1) throw new Error('Professional price did not remain at the contracted value.');
    await onMutation?.({ request: completeRequest, response, requests, blockedRequests: blocked });
    return { mutationCount: delta, allowedMutationCount: allowed.length, blockedMutationCount: blocked.length, responseStatus: response.status(), requests: deltaRecords };
  } finally {
    guard.setPhase('stage');
  }
}

export { PRICE_CURRENCY, STANDARD_LICENSE_LABEL };
