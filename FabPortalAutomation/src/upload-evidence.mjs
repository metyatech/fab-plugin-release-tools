import { readFile } from 'node:fs/promises';
import { normalizePortalFileName } from './portal-file-identity.mjs';

function fail(message) {
  throw new Error(`Fab Portal upload evidence invalid: ${message}`);
}

export async function loadFabPortalUploadEvidence(filePath, manifestInfo) {
  let evidence;
  try {
    evidence = JSON.parse(await readFile(filePath, 'utf8'));
  } catch (error) {
    fail(`could not read JSON: ${error.message}`);
  }
  const rootKeys = ['schemaVersion', 'listingId', 'manifestSha256', 'additionalFiles'];
  if (!evidence || Object.keys(evidence).length !== rootKeys.length || rootKeys.some((key) => !Object.hasOwn(evidence, key))) fail('evidence must contain exactly the documented fields.');
  if (!evidence || evidence.schemaVersion !== 1) fail('schemaVersion must equal 1.');
  if (evidence.listingId !== manifestInfo.manifest.listingId) fail('listingId does not match the submission manifest.');
  if (evidence.manifestSha256 !== manifestInfo.manifestSha256) fail('manifestSha256 does not match the loaded submission manifest.');
  if (!Array.isArray(evidence.additionalFiles)) fail('additionalFiles must be an array.');
  const expected = manifestInfo.verifiedAdditionalFiles ?? [];
  if (evidence.additionalFiles.length !== expected.length) fail('additionalFiles must contain one record for every verified local Additional File.');
  for (const file of expected) {
    const matches = evidence.additionalFiles.filter((item) => item?.fileName === file.fileName);
    if (matches.length !== 1) fail(`expected exactly one upload record for ${file.fileName}.`);
    const [record] = matches;
    const recordKeys = ['fileName', 'portalFileName', 'localSha256', 'sizeBytes', 'uploadCompleted', 'completedAtUtc'];
    if (Object.keys(record).length !== recordKeys.length || recordKeys.some((key) => !Object.hasOwn(record, key))) fail(`upload record for ${file.fileName} must contain exactly the documented fields.`);
    if (record.localSha256?.toLowerCase() !== file.sha256.toLowerCase()) fail(`localSha256 does not match the verified local artifact for ${file.fileName}.`);
    if (record.sizeBytes !== file.bytes) fail(`sizeBytes does not match the verified local artifact for ${file.fileName}.`);
    if (typeof record.portalFileName !== 'string' || normalizePortalFileName(record.portalFileName) !== normalizePortalFileName(file.fileName)) fail(`portalFileName does not correspond to the verified local artifact for ${file.fileName}.`);
    if (record.uploadCompleted !== true) fail(`uploadCompleted must be true for ${file.fileName}.`);
    if (typeof record.completedAtUtc !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(record.completedAtUtc) || Number.isNaN(Date.parse(record.completedAtUtc))) {
      fail(`completedAtUtc must be a valid UTC timestamp for ${file.fileName}.`);
    }
  }
  return evidence;
}
