const PORTAL_FIELD_LIFECYCLE = Object.freeze({
  title: 'DRAFT',
  shortDescription: 'SOURCE_ONLY',
  longDescription: 'DRAFT',
  productType: 'DRAFT',
  category: 'DRAFT',
  subcategory: 'DRAFT',
  tags: 'DRAFT',
  includedFormat: 'DRAFT',
  engineVersions: 'DRAFT',
  platforms: 'DRAFT',
  license: 'DRAFT',
  personalPriceUsd: 'DRAFT',
  professionalPriceUsd: 'DRAFT',
  matureContent: 'DRAFT',
  generatedWithAi: 'DRAFT',
  allowsUsageWithAi: 'DRAFT',
  promotionalContent: 'DRAFT',
  forumPost: 'DRAFT',
  activation: 'SUBMIT_TIME',
  documentationUrl: 'DRAFT',
  supportUrl: 'DERIVED',
  technicalInformationFile: 'DRAFT',
  media: 'DRAFT',
});

export function portalFieldLifecycle(manifestJsonPath) {
  if (/^packages\[\d+\]\.projectFileLink$/.test(manifestJsonPath)) return 'DRAFT';
  return PORTAL_FIELD_LIFECYCLE[manifestJsonPath] ?? null;
}

export function assertSubmitActivationDecision(decision, expectedManifestActivation = null) {
  const allowed = new Set(['Automatic activation', 'Manual activation']);
  if (!allowed.has(decision)) {
    throw new Error('Submit for review requires an explicit activation decision: Automatic activation or Manual activation.');
  }
  if (expectedManifestActivation !== null && decision !== expectedManifestActivation) {
    throw new Error(`Submit activation decision ${decision} does not match manifest activation ${expectedManifestActivation}.`);
  }
  return decision;
}

export { PORTAL_FIELD_LIFECYCLE };
