import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { loadFabPortalUploadEvidence } from '../src/upload-evidence.mjs';

async function evidenceFile(value) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'fab-upload-evidence-'));
  const filePath = path.join(directory, 'FabPortalUploadEvidence.json');
  await writeFile(filePath, JSON.stringify(value));
  return filePath;
}

const manifestInfo = {
  manifest: { listingId: '11111111-1111-4111-8111-111111111111' },
  manifestSha256: 'a'.repeat(64),
  verifiedAdditionalFiles: [{ fileName: 'Demo_UE5.8.zip', sha256: 'b'.repeat(64), bytes: 2048 }],
};

function evidence(overrides = {}) {
  return {
    schemaVersion: 1,
    listingId: manifestInfo.manifest.listingId,
    manifestSha256: manifestInfo.manifestSha256,
    additionalFiles: [{ fileName: 'Demo_UE5.8.zip', portalFileName: 'demo_ue58.zip', localSha256: 'b'.repeat(64), sizeBytes: 2048, uploadCompleted: true, completedAtUtc: '2026-10-08T06:00:00Z' }],
    ...overrides,
  };
}

test('upload evidence must bind a completed upload to exact manifest and verified local hash', async () => {
  const result = await loadFabPortalUploadEvidence(await evidenceFile(evidence()), manifestInfo);
  assert.equal(result.additionalFiles[0].uploadCompleted, true);
});

test('upload evidence rejects a different manifest, artifact hash, size, or incomplete operation', async () => {
  for (const value of [
    evidence({ manifestSha256: 'c'.repeat(64) }),
    evidence({ additionalFiles: [{ ...evidence().additionalFiles[0], localSha256: 'c'.repeat(64) }] }),
    evidence({ additionalFiles: [{ ...evidence().additionalFiles[0], sizeBytes: 2047 }] }),
    evidence({ additionalFiles: [{ ...evidence().additionalFiles[0], portalFileName: 'old_demo.zip' }] }),
    evidence({ additionalFiles: [{ ...evidence().additionalFiles[0], uploadCompleted: false }] }),
  ]) {
    const filePath = await evidenceFile(value);
    await assert.rejects(() => loadFabPortalUploadEvidence(filePath, manifestInfo));
  }
});
