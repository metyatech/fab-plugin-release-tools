import assert from 'node:assert/strict';
import test from 'node:test';
import { parsePortalFileSizeEvidence, normalizePortalFileName } from '../src/portal-file-identity.mjs';
import { verifyAdditionalFileIdentity } from '../src/portal-contract.mjs';

test('exact byte metadata takes precedence over rounded display text', () => {
  assert.deepEqual(parsePortalFileSizeEvidence({ rawBytes: '16946', displayText: '16.55 kB' }), {
    precision: 'exact', bytes: 16946, range: { minimumBytes: 16946, maximumBytes: 16946 }, source: 'exact-metadata',
  });
});

test('visible exact byte counts are preserved', () => {
  assert.equal(parsePortalFileSizeEvidence({ displayText: '16,946 bytes' }).bytes, 16946);
});

test('rounded 16.55 kB maps to a binary-unit byte interval without claiming an exact count', () => {
  const evidence = parsePortalFileSizeEvidence({ displayText: '16.55 kB' });
  assert.equal(evidence.precision, 'rounded');
  assert.equal(evidence.bytes, null);
  assert.deepEqual(evidence.range, { minimumBytes: 16943, maximumBytes: 16952 });
  for (const expectedSizeBytes of [16943, 16946, 16952]) {
    const identity = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes, portalSizeRange: evidence.range, localSha256: 'a'.repeat(64), sourceFileName: 'Demo_UE5.8.zip', displayFileName: 'demo_ue58.zip' });
    assert.equal(identity.sizeEvidenceState, 'MATCH');
    assert.equal(identity.portalSizeBytes, null);
    assert.equal(identity.state, 'PASS');
  }
  for (const expectedSizeBytes of [16942, 16953]) {
    const identity = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes, portalSizeRange: evidence.range, localSha256: 'a'.repeat(64), sourceFileName: 'Demo_UE5.8.zip', displayFileName: 'demo_ue58.zip' });
    assert.equal(identity.sizeEvidenceState, 'MISMATCH');
    assert.equal(identity.state, 'FAIL');
  }
});

test('rounded size parser handles different unit spellings', () => {
  assert.equal(parsePortalFileSizeEvidence({ displayText: '16.55 KiB' }).range.minimumBytes, 16943);
  assert.deepEqual(parsePortalFileSizeEvidence({ displayText: '0.02 MiB' }).range, { minimumBytes: 15729, maximumBytes: 26214 });
  assert.equal(parsePortalFileSizeEvidence({ displayText: '16.55 KB' }).precision, 'unknown');
  assert.equal(parsePortalFileSizeEvidence({ displayText: '0.02 MB' }).precision, 'unknown');
  assert.equal(parsePortalFileSizeEvidence({ displayText: '0.02 GB' }).precision, 'unknown');
});

test('missing size evidence remains unknown and clear size conflicts fail closed', () => {
  assert.equal(parsePortalFileSizeEvidence({ displayText: 'Demo_UE5.8.zip' }).precision, 'unknown');
  const unknown = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 16946, localSha256: 'a'.repeat(64), sourceFileName: 'Demo_UE5.8.zip', displayFileName: 'demo_ue58.zip' });
  assert.equal(unknown.sizeEvidenceState, 'UNKNOWN');
  const mismatch = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 16946, portalSizeBytes: 16000, localSha256: 'a'.repeat(64), sourceFileName: 'Demo_UE5.8.zip', displayFileName: 'demo_ue58.zip' });
  assert.equal(mismatch.sizeEvidenceState, 'MISMATCH');
  assert.equal(mismatch.state, 'FAIL');
});

test('filename normalization accepts Fab punctuation and case changes but rejects unrelated names', () => {
  assert.equal(normalizePortalFileName('Demo_UE5.8.zip'), normalizePortalFileName('demo_ue58.zip'));
  assert.notEqual(normalizePortalFileName('Demo_UE5.8.zip'), normalizePortalFileName('old_demo.zip'));
  const identity = verifyAdditionalFileIdentity({ format: 'Additional files', role: 'Additional File', uploadCompleted: true, expectedSizeBytes: 2048, portalSizeBytes: 2048, localSha256: 'a'.repeat(64), sourceFileName: 'Demo_UE5.8.zip', displayFileName: 'old_demo.zip' });
  assert.equal(identity.filenameCorresponds, false);
  assert.equal(identity.state, 'FAIL');
});
