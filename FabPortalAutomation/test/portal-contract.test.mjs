import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  assessDescriptionPreview,
  assessRecordedDescriptionPreview,
  assessPublicationPhase,
  compareTechnicalInformationItems,
  deriveReadiness,
  verifyAdditionalFileIdentity,
} from '../src/portal-contract.mjs';

test('Technical Information compares canonical values by item and marks stale Example Project', () => {
  const result = compareTechnicalInformationItems(
    'Example Project: Included as Fab Additional File (UE5.8).',
    'Example Project: Not applicable — No example project is distributed or required.',
  );
  assert.equal(result.items[0].state, 'STALE');
  assert.equal(result.submissionReady, false);
});

test('Technical Information portal-only items are reported without failing canonical matches', () => {
  const result = compareTechnicalInformationItems('Engine: 5.8', 'Engine: 5.8\nFab note: Seller-only value');
  assert.deepEqual(result.items.map((item) => item.state), ['MATCH', 'PORTAL_ONLY']);
  assert.equal(result.submissionReady, true);
});

test('duplicate Portal Technical Information values cannot hide a stale canonical value', () => {
  const result = compareTechnicalInformationItems(
    'Example Project: Included as Fab Additional File.',
    'Example Project: Not applicable.\nExample Project: Included as Fab Additional File.',
  );
  assert.equal(result.counts.STALE, 1);
  assert.equal(result.submissionReady, false);
});

test('Additional Files contract distinguishes the format route from Media Gallery', () => {
  const mediaOnly = verifyAdditionalFileIdentity({ format: 'Media Gallery', role: 'Image', uploadCompleted: true, expectedSizeBytes: 100, portalSizeBytes: 100, localSha256: 'a'.repeat(64) });
  assert.equal(mediaOnly.state, 'FAIL');
  const additional = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 100, portalSizeBytes: 100, localSha256: 'a'.repeat(64) });
  assert.equal(additional.state, 'PASS');
});

test('Fab normalized display filename does not invalidate verified Additional File identity', () => {
  const result = verifyAdditionalFileIdentity({
    format: 'Additional files', role: 'Additional File', uploadCompleted: true,
    expectedSizeBytes: 2048, portalSizeBytes: 2048, localSha256: 'a'.repeat(64),
    sourceFileName: 'FindInMaterialsDemo_UE5.8.zip', displayFileName: 'findinmaterialsdemo_ue58.zip',
  });
  assert.equal(result.state, 'PASS');
  assert.equal(result.nameNormalized, true);
  assert.equal(result.remoteHashVerified, null);
});

test('Additional File role and size contradictions fail closed', () => {
  const wrongRole = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Media Gallery', uploadCompleted: true, expectedSizeBytes: 100, portalSizeBytes: 100, localSha256: 'a'.repeat(64) });
  const wrongSize = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 100, portalSizeBytes: 99, localSha256: 'a'.repeat(64) });
  assert.equal(wrongRole.state, 'FAIL');
  assert.equal(wrongSize.state, 'FAIL');
});

test('available remote hash is compared and a contradictory hash fails closed', () => {
  const expected = { format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 100, portalSizeBytes: 100, localSha256: 'a'.repeat(64), expectedSha256: 'a'.repeat(64) };
  const match = verifyAdditionalFileIdentity({ ...expected, portalSha256: 'a'.repeat(64) });
  const mismatch = verifyAdditionalFileIdentity({ ...expected, portalSha256: 'b'.repeat(64) });
  assert.equal(match.remoteHashVerified, true);
  assert.equal(mismatch.remoteHashVerified, false);
  assert.equal(mismatch.state, 'FAIL');
});

test('publication mode absent during edit phase is not a failure', () => {
  assert.deepEqual(assessPublicationPhase({ phase: 'edit', expectedMode: 'Automatic publication' }).blocker, false);
  assert.deepEqual(assessPublicationPhase({ phase: 'edit', expectedMode: 'Automatic publication' }).state, 'NOT_APPLICABLE');
});

test('Automatic publication is checked only in submission phase', () => {
  const result = assessPublicationPhase({ phase: 'submission', expectedMode: 'Automatic publication', observedMode: 'Automatic activation' });
  assert.equal(result.state, 'MATCH');
  assert.equal(result.blocker, false);
  assert.equal(assessPublicationPhase({ phase: 'submission', expectedMode: 'Automatic publication' }).blocker, true);
});

test('Description Preview with collapsed paragraphs fails rendered structure verification', () => {
  const expected = { blocks: [{ type: 'paragraph', runs: [{ text: 'One' }] }, { type: 'paragraph', runs: [{ text: 'Two' }] }] };
  const rendered = { blocks: [{ type: 'paragraph', runs: [{ text: 'One Two' }] }] };
  assert.equal(assessDescriptionPreview({ expected, rendered, previewObserved: true }).state, 'FAIL');
});

test('Description structure and content pass despite tight Fab-controlled spacing', () => {
  const expected = { blocks: [{ type: 'heading', level: 2, runs: [{ text: 'Guide' }] }, { type: 'paragraph', runs: [{ text: 'Text' }] }, { type: 'unordered_list', items: [[{ text: 'Item' }]] }] };
  const result = assessDescriptionPreview({ expected, rendered: structuredClone(expected), styleLimitation: true, previewObserved: true });
  assert.equal(result.state, 'PASS_WITH_PLATFORM_STYLE_LIMITATION');
  assert.equal(result.blocker, false);
});

test('Description guidance rejects whitespace and break-tag workarounds', async () => {
  const readme = (await readFile(new URL('../../README.md', import.meta.url), 'utf8')).replace(/\s+/g, ' ').toLowerCase();
  assert.match(readme, /do not add repeated `<br>` elements, spaces, or blank lines to override fab typography/);
});

test('Description Preview without human or Computer Use evidence remains UNKNOWN', () => {
  assert.equal(assessDescriptionPreview({ expected: { blocks: [] }, rendered: { blocks: [] } }).state, 'UNKNOWN');
  assert.equal(assessRecordedDescriptionPreview().state, 'UNKNOWN');
});

test('recorded Preview acceptance allows Fab style limitation only with all structure checks passed', () => {
  const checks = { paragraphsDistinct: true, unorderedListsRendered: true, orderedListsRendered: true, queryExamplesDistinct: true, headingsDistinct: true, linksCorrect: true };
  assert.equal(assessRecordedDescriptionPreview({ ...checks, evidenceSource: 'computer-use', state: 'PASS_WITH_PLATFORM_STYLE_LIMITATION', styleLimitation: true }).state, 'PASS_WITH_PLATFORM_STYLE_LIMITATION');
  assert.equal(assessRecordedDescriptionPreview({ ...checks, paragraphsDistinct: false, evidenceSource: 'human', state: 'FAIL', styleLimitation: false }).blocker, true);
});

test('readiness keeps artifacts, Portal verification, human acceptance, and submission distinct', () => {
  const prepared = deriveReadiness({ artifactReady: true, portalInputsReady: true });
  assert.equal(prepared.artifactReady, true);
  assert.equal(prepared.portalVerified, false);
  assert.equal(prepared.readyToSubmit, false);
  assert.equal(prepared.submitted, false);
  const verified = deriveReadiness({ artifactReady: true, portalInputsReady: true, portalVerified: true, humanVisualAcceptance: 'PASS' });
  assert.equal(verified.readyToSubmit, true);
  assert.equal(verified.submitted, false);
  assert.equal(deriveReadiness({ submitted: true }).submitted, true);
});
