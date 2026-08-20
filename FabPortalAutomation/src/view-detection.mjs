const FORMAT_VIEW = 'format';
const LISTING_MAIN_VIEW = 'listing';

async function isVisibleUnique(locator) {
  if (await locator.count() !== 1) return false;
  return await locator.isVisible().catch(() => false);
}

async function hasVisibleUniqueFormatEvidence(page) {
  const evidence = [
    page.getByRole('heading', { name: 'Manage format', exact: true }),
    page.getByRole('button', { name: 'Back to listing', exact: true }),
    page.getByRole('button', { name: 'Delete product format', exact: true }),
    page.getByRole('combobox', { name: 'Supported development platforms', exact: true }),
    page.getByRole('textbox', { name: 'Project File Link', exact: true }),
  ];
  for (const locator of evidence) {
    if (await isVisibleUnique(locator)) return true;
  }
  return false;
}

export async function classifyFabView(page) {
  const projectVersions = page.getByRole('heading', { name: 'Project Versions*', exact: true });
  if (!await isVisibleUnique(projectVersions)) return LISTING_MAIN_VIEW;
  return await hasVisibleUniqueFormatEvidence(page) ? FORMAT_VIEW : LISTING_MAIN_VIEW;
}

export async function isFormatView(page) {
  return await classifyFabView(page) === FORMAT_VIEW;
}

export const FAB_VIEW = Object.freeze({ FORMAT_VIEW, LISTING_MAIN_VIEW });
