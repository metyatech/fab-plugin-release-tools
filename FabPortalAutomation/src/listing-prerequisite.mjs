const PREFETCHED_DATA_SELECTOR = '#js-json-data-prefetched-data';
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PRODUCT_TYPE_CODES = new Map([
  ['Tools & Plugins', 'tool-and-plugin'],
]);

export const LISTING_PREREQUISITE_PAYLOAD_KEYS = Object.freeze([
  'category',
  'description',
  'has_promotional_content',
  'intellectual_property_confirmed',
  'is_ai_forbidden',
  'is_ai_generated',
  'licenses',
  'listing_type',
  'seller_provided_maturity_rating',
  'tags',
  'title',
  'use_comment_thread',
].sort());

function unknown(reason) {
  return {
    status: 'unknown',
    source: 'prefetched-listing-data',
    reason,
  };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function listingUpdateSnapshot(listing) {
  return {
    description: listing.description,
    has_promotional_content: listing.hasPromotionalContent,
    intellectual_property_confirmed: listing.intellectualPropertyConfirmed,
    is_ai_forbidden: listing.isAiForbidden,
    is_ai_generated: listing.isAiGenerated,
    licenses: listing.licenses,
    listing_type: listing.listingType,
    seller_provided_maturity_rating: listing.sellerProvidedMaturityRating,
    tags: listing.tags,
    title: listing.title,
    use_comment_thread: listing.useCommentThread,
  };
}

function validSnapshot(snapshot) {
  return typeof snapshot.description === 'string'
    && typeof snapshot.has_promotional_content === 'boolean'
    && typeof snapshot.intellectual_property_confirmed === 'boolean'
    && typeof snapshot.is_ai_forbidden === 'boolean'
    && typeof snapshot.is_ai_generated === 'boolean'
    && Array.isArray(snapshot.licenses)
    && typeof snapshot.listing_type === 'string'
    && typeof snapshot.seller_provided_maturity_rating === 'string'
    && Array.isArray(snapshot.tags)
    && typeof snapshot.title === 'string'
    && typeof snapshot.use_comment_thread === 'boolean';
}

export function inspectPrefetchedListingPrerequisite(data, { listingId, productType, category, title } = {}) {
  if (!UUID_PATTERN.test(String(listingId ?? ''))) return unknown('Target listing UUID is not a lowercase UUID.');
  const listingKey = `/i/portal/listings/${listingId}`;
  if (!isPlainObject(data)) return unknown('Prefetched data was not a JSON object.');
  const listing = data[listingKey];
  if (!isPlainObject(listing) || listing.uid !== listingId) return unknown('The prefetched listing UUID did not exactly match the target UUID.');
  const expectedListingType = PRODUCT_TYPE_CODES.get(productType);
  if (!expectedListingType) return unknown(`Unsupported product type for prerequisite persistence: ${productType}.`);
  if (listing.listingType !== expectedListingType) return unknown('Prefetched listing type did not match the manifest product type.');
  if (listing.title !== title) return unknown('Prefetched listing title did not exactly match the manifest title.');

  const taxonomy = data['/i/taxonomy/categories/tree'];
  const entries = taxonomy?.results?.[expectedListingType];
  if (!Array.isArray(entries)) return unknown('Prefetched category taxonomy was not available for the listing type.');
  const matches = entries.filter((entry) => isPlainObject(entry)
    && entry.name === category
    && typeof entry.uid === 'string'
    && UUID_PATTERN.test(entry.uid));
  if (matches.length !== 1) return unknown(`Prefetched category identity match count was ${matches.length}.`);

  const unchanged = listingUpdateSnapshot(listing);
  if (!validSnapshot(unchanged)) return unknown('Prefetched listing fields required by the observed autosave payload were malformed or missing.');
  return {
    status: 'known',
    source: 'prefetched-listing-data',
    listingId,
    categoryName: category,
    categoryId: matches[0].uid,
    listingType: expectedListingType,
    unchanged,
    payloadKeys: [...LISTING_PREREQUISITE_PAYLOAD_KEYS],
  };
}

export async function readPrefetchedListingPrerequisite(page, options) {
  const data = await page.evaluate((selector) => {
    const source = document.querySelector(selector);
    if (!source) return null;
    try { return JSON.parse(source.textContent ?? ''); } catch { return null; }
  }, PREFETCHED_DATA_SELECTOR);
  return inspectPrefetchedListingPrerequisite(data, options);
}
