import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadSubmissionManifest } from '../src/manifest.mjs';
import { makeManifest } from './helpers.mjs';

async function writeManifest(manifest) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'fab-manifest-test-'));
  await writeFile(path.join(directory, 'manifest.json'), JSON.stringify(manifest));
  return path.join(directory, 'manifest.json');
}

async function validManifestBundle() {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'fab-manifest-valid-'));
  await mkdir(path.join(directory, 'submission'), { recursive: true });
  await mkdir(path.join(directory, 'media'), { recursive: true });
  await mkdir(path.join(directory, 'packages', 'UE5.8'), { recursive: true });
  const technical = 'Technical information from the bundle.\n';
  const media = Buffer.from('thumbnail');
  const packageBytes = Buffer.from('package');
  await writeFile(path.join(directory, 'submission', 'FabTechnicalInformation.txt'), technical);
  await writeFile(path.join(directory, 'media', '001.jpg'), media);
  await writeFile(path.join(directory, 'packages', 'UE5.8', 'package.zip'), packageBytes);
  const sha = (value) => createHash('sha256').update(value).digest('hex');
  const manifest = makeManifest({
    media: [{ order: 1, role: 'thumbnail', bundleRelativePath: 'media/001.jpg', sha256: sha(media) }],
    packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: sha(packageBytes), projectFileLink: 'https://example.com/package.zip' }],
  });
  const manifestPath = path.join(directory, 'manifest.json');
  await writeFile(manifestPath, JSON.stringify(manifest));
  return { manifest, manifestPath, technical };
}

test('manifest loader exposes Technical Information file content separately', async () => {
  const fixture = await validManifestBundle();
  const loaded = await loadSubmissionManifest(fixture.manifestPath);
  assert.equal(loaded.technicalInformationText, fixture.technical);
  assert.equal(loaded.manifest.technicalInformationFile, 'submission/FabTechnicalInformation.txt');
});

test('verify manifest loading accepts generator-style portal-unready packages', async () => {
  const fixture = await validManifestBundle();
  fixture.manifest.portalReady = false;
  fixture.manifest.packages[0].projectFileLink = null;
  await writeFile(fixture.manifestPath, JSON.stringify(fixture.manifest));
  const loaded = await loadSubmissionManifest(fixture.manifestPath, { requirePortalReady: false });
  assert.equal(loaded.manifest.portalReady, false);
  assert.equal(loaded.packageFiles[0].projectFileLink, null);
  await assert.rejects(() => loadSubmissionManifest(fixture.manifestPath), /portalReady must be true|write-capable/);
});

test('verify manifest loading still enforces package, media, and Technical Information integrity', async () => {
  const packageMismatch = await validManifestBundle();
  packageMismatch.manifest.portalReady = false;
  packageMismatch.manifest.packages[0].projectFileLink = null;
  packageMismatch.manifest.packages[0].sha256 = '0'.repeat(64);
  await writeFile(packageMismatch.manifestPath, JSON.stringify(packageMismatch.manifest));
  await assert.rejects(() => loadSubmissionManifest(packageMismatch.manifestPath, { requirePortalReady: false }), /packages\[0\].bundleRelativePath SHA-256/);

  const mediaMismatch = await validManifestBundle();
  mediaMismatch.manifest.portalReady = false;
  mediaMismatch.manifest.packages[0].projectFileLink = null;
  mediaMismatch.manifest.media[0].sha256 = '0'.repeat(64);
  await writeFile(mediaMismatch.manifestPath, JSON.stringify(mediaMismatch.manifest));
  await assert.rejects(() => loadSubmissionManifest(mediaMismatch.manifestPath, { requirePortalReady: false }), /media\[1\].bundleRelativePath SHA-256/);

  const technicalMissing = await validManifestBundle();
  technicalMissing.manifest.portalReady = false;
  technicalMissing.manifest.packages[0].projectFileLink = null;
  const { unlink } = await import('node:fs/promises');
  await unlink(path.join(path.dirname(technicalMissing.manifestPath), technicalMissing.manifest.technicalInformationFile));
  await writeFile(technicalMissing.manifestPath, JSON.stringify(technicalMissing.manifest));
  await assert.rejects(() => loadSubmissionManifest(technicalMissing.manifestPath, { requirePortalReady: false }), /technicalInformationFile does not exist/);
});

test('non-null project file links remain HTTPS-only', async () => {
  const fixture = await validManifestBundle();
  fixture.manifest.portalReady = false;
  fixture.manifest.packages[0].projectFileLink = 'http://example.com/package.zip';
  await writeFile(fixture.manifestPath, JSON.stringify(fixture.manifest));
  await assert.rejects(() => loadSubmissionManifest(fixture.manifestPath, { requirePortalReady: false }), /projectFileLink must be HTTPS/);
});

test('runtime manifest validation requires non-blank descriptions', async () => {
  for (const mutation of [
    (manifest) => { delete manifest.shortDescription; },
    (manifest) => { manifest.shortDescription = '   '; },
    (manifest) => { delete manifest.longDescription; },
    (manifest) => { manifest.longDescription = ''; },
  ]) {
    const manifest = makeManifest();
    mutation(manifest);
    const manifestPath = await writeManifest(manifest);
    await assert.rejects(() => loadSubmissionManifest(manifestPath), /shortDescription|longDescription/);
  }
});

test('runtime manifest validation requires finite non-negative prices and booleans', async () => {
  for (const mutation of [
    (manifest) => { manifest.personalPriceUsd = -1; },
    (manifest) => { manifest.professionalPriceUsd = '29.99'; },
    (manifest) => { manifest.matureContent = 'false'; },
    (manifest) => { manifest.allowsUsageWithAi = 1; },
  ]) {
    const manifest = makeManifest();
    mutation(manifest);
    const manifestPath = await writeManifest(manifest);
    await assert.rejects(() => loadSubmissionManifest(manifestPath), /personalPriceUsd|professionalPriceUsd|matureContent|allowsUsageWithAi/);
  }
});

test('runtime manifest validation requires one unique package per engine version', async () => {
  for (const packages of [
    [],
    [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/package.zip' }, { engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/package.zip' }],
    [{ engineVersion: '5.7', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/package.zip' }],
  ]) {
    const manifest = makeManifest({ packages });
    const manifestPath = await writeManifest(manifest);
    await assert.rejects(() => loadSubmissionManifest(manifestPath), /packages must be a non-empty array|packages count|duplicate engineVersion|package engineVersion/);
  }
});
