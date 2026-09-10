import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { compareObservation } from '../src/comparison.mjs';
import { loadFabPortalObservation } from '../src/observation.mjs';
import { makeManifest, makeManifestInfo } from './helpers.mjs';

const manifest = makeManifest({
  engineVersions: ['5.6', '5.7', '5.8'],
  packages: [
    { engineVersion: '5.6', versionTitle: 'UE 5.6', bundleRelativePath: 'packages/UE5.6/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/5.6.zip' },
    { engineVersion: '5.7', versionTitle: 'UE 5.7', bundleRelativePath: 'packages/UE5.7/package.zip', sha256: 'c'.repeat(64), projectFileLink: 'https://example.com/5.7.zip' },
    { engineVersion: '5.8', versionTitle: 'UE 5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'd'.repeat(64), projectFileLink: 'https://example.com/5.8.zip' },
  ],
});

function field(manifestJsonPath, value, view = manifestJsonPath === 'media' || manifestJsonPath === 'engineVersions' || manifestJsonPath === 'platforms' || manifestJsonPath === 'technicalInformationFile' || manifestJsonPath.startsWith('packages[') ? 'format' : 'listing') {
  return { manifestJsonPath, state: 'OBSERVED', value, view };
}

function makeObservation(manifestInfo, overrides = {}) {
  const values = {
    title: manifest.title,
    shortDescription: manifest.shortDescription,
    longDescription: manifest.longDescription,
    productType: manifest.productType,
    category: manifest.category,
    subcategory: manifest.subcategory,
    tags: manifest.tags,
    includedFormat: manifest.includedFormat,
    engineVersions: ['5.8', '5.6', '5.7'],
    platforms: ['Windows'],
    license: 'Standard License (Free or Paid)',
    personalPriceUsd: '$9.99',
    professionalPriceUsd: 29.99,
    matureContent: manifest.matureContent,
    generatedWithAi: manifest.generatedWithAi,
    allowsUsageWithAi: manifest.allowsUsageWithAi,
    promotionalContent: manifest.promotionalContent,
    forumPost: manifest.forumPost,
    activation: manifest.activation,
    documentationUrl: manifest.documentationUrl,
    supportUrl: manifest.supportUrl,
    technicalInformationFile: manifestInfo.technicalInformationText,
    media: { count: 1, items: [{ order: 1, role: 'thumbnail' }] },
    'packages[0].projectFileLink': manifest.packages[0].projectFileLink,
    'packages[1].projectFileLink': manifest.packages[1].projectFileLink,
    'packages[2].projectFileLink': manifest.packages[2].projectFileLink,
  };
  return {
    schemaVersion: 1,
    source: 'interactive-browser',
    manifestSha256: manifestInfo.manifestSha256,
    observedAtUtc: '2026-09-11T00:00:00.000Z',
    listingId: manifest.listingId,
    listingTitle: manifest.title,
    listingStatus: 'Draft',
    fields: Object.entries({ ...values, ...(overrides.values ?? {}) }).map(([manifestJsonPath, value]) => field(manifestJsonPath, value)),
    ...overrides,
  };
}

async function fixture() {
  const manifestInfo = await makeManifestInfo(manifest);
  const directory = await fsTemp();
  const observationPath = path.join(directory, 'FabPortalObservation.json');
  return { manifestInfo, observationPath };
}

async function fsTemp() {
  const { mkdtemp } = await import('node:fs/promises');
  return mkdtemp(path.join(os.tmpdir(), 'fab-observation-test-'));
}

async function loadFixture(mutator = null) {
  const { manifestInfo, observationPath } = await fixture();
  const observation = makeObservation(manifestInfo);
  if (mutator) mutator(observation);
  await writeFile(observationPath, `${JSON.stringify(observation)}\n`, 'utf8');
  return { manifestInfo, observationPath, observation };
}

test('valid exact observation file loads with its raw SHA', async () => {
  const { manifestInfo, observationPath } = await loadFixture();
  const loaded = await loadFabPortalObservation(observationPath, manifestInfo);
  assert.equal(loaded.observation.source, 'interactive-browser');
  assert.equal(loaded.observationSha256.length, 64);
});

for (const [name, mutator, pattern] of [
  ['invalid schemaVersion', (value) => { value.schemaVersion = 2; }, /schemaVersion/],
  ['malformed listing ID', (value) => { value.listingId = 'NOT-A-UUID'; }, /listingId/],
  ['wrong manifest SHA', (value) => { value.manifestSha256 = 'a'.repeat(64); }, /manifestSha256/],
  ['duplicate field path', (value) => { value.fields.push(structuredClone(value.fields[0])); }, /duplicate manifestJsonPath/],
  ['unknown field path', (value) => { value.fields[0].manifestJsonPath = 'longDescriptionTypo'; }, /unsupported manifestJsonPath/],
  ['OBSERVED without value', (value) => { delete value.fields[0].value; }, /require value/],
  ['wrong field type', (value) => { value.fields.find((item) => item.manifestJsonPath === 'platforms').value = 'Windows'; }, /platforms/],
  ['invalid package index', (value) => { value.fields[0].manifestJsonPath = 'packages[9].projectFileLink'; value.fields[0].view = 'format'; }, /unsupported manifestJsonPath/],
  ['NOT_VISIBLE with authoritative value', (value) => { value.fields[0].state = 'NOT_VISIBLE'; }, /must not provide value/],
  ['missing expected field', (value) => { value.fields = value.fields.slice(1); }, /missing expected field observations/],
]) {
  test(`observation contract rejects ${name}`, async () => {
    const { manifestInfo, observationPath } = await loadFixture(mutator);
    await assert.rejects(() => loadFabPortalObservation(observationPath, manifestInfo), pattern);
  });
}

test('pure comparator matches normalized rich text, USD, Windows, engine sets, URLs, and links', async () => {
  const { manifestInfo } = await fixture();
  const observation = makeObservation(manifestInfo);
  observation.fields.find((item) => item.manifestJsonPath === 'longDescription').value = 'Fixture   long\ndescription';
  const comparison = compareObservation(manifestInfo, observation);
  assert.equal(comparison.mismatchCount, 0);
  assert.equal(comparison.counts.MATCH, 26);
});

test('pure comparator reports changed long description and price as mismatches', async () => {
  const { manifestInfo } = await fixture();
  const observation = makeObservation(manifestInfo);
  observation.fields.find((item) => item.manifestJsonPath === 'longDescription').value = 'Changed description';
  observation.fields.find((item) => item.manifestJsonPath === 'personalPriceUsd').value = '$10.00';
  const comparison = compareObservation(manifestInfo, observation);
  assert.equal(comparison.mismatchCount, 2);
  assert.equal(comparison.fields.find((item) => item.manifestJsonPath === 'longDescription').classification, 'MISMATCH');
  assert.equal(comparison.fields.find((item) => item.manifestJsonPath === 'personalPriceUsd').classification, 'MISMATCH');
});

test('pure comparator preserves explicit unresolved states and detects media order mismatch', async () => {
  const { manifestInfo } = await fixture();
  const observation = makeObservation(manifestInfo);
  const title = observation.fields.find((item) => item.manifestJsonPath === 'title');
  title.state = 'NOT_VISIBLE';
  delete title.value;
  observation.fields.find((item) => item.manifestJsonPath === 'media').value = { count: 1, items: [{ order: 2, role: 'thumbnail' }] };
  const comparison = compareObservation(manifestInfo, observation);
  assert.equal(comparison.fields.find((item) => item.manifestJsonPath === 'title').classification, 'NOT_VISIBLE');
  assert.equal(comparison.fields.find((item) => item.manifestJsonPath === 'media').classification, 'MISMATCH');
  assert.deepEqual(comparison.unresolvedCritical, ['title']);
});

test('missing expected field cannot disappear in the pure comparator', async () => {
  const { manifestInfo } = await fixture();
  const observation = makeObservation(manifestInfo);
  observation.fields = observation.fields.filter((item) => item.manifestJsonPath !== 'supportUrl');
  const comparison = compareObservation(manifestInfo, observation);
  assert.equal(comparison.fields.find((item) => item.manifestJsonPath === 'supportUrl').classification, 'NOT_DISCOVERED');
  assert.equal(comparison.unresolvedCritical.includes('supportUrl'), true);
});
