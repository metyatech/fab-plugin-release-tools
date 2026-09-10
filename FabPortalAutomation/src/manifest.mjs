import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { TextDecoder } from 'node:util';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const MAX_FILE_BYTES = 15 * 1024 * 1024 * 1024;

function fail(message) {
  throw new Error(`FabPortalSubmission manifest invalid: ${message}`);
}

function requireString(value, field) {
  if (typeof value !== 'string' || value.trim() === '') fail(`${field} must be non-blank text.`);
  return value;
}

function requireNumber(value, field) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) fail(`${field} must be a finite non-negative JSON number.`);
  return value;
}

function requireArray(value, field, { allowEmpty = false } = {}) {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) fail(`${field} must be a ${allowEmpty ? '' : 'non-empty '}array.`);
  if (value.some((item) => typeof item !== 'string' || item.trim() === '')) fail(`${field} must contain only non-blank strings.`);
  return value;
}

function requireSha256(value, field) {
  requireString(value, field);
  if (!SHA256_PATTERN.test(value)) fail(`${field} must be a SHA-256 hexadecimal value.`);
  return value.toLowerCase();
}

function resolveBundleFile(bundleRoot, relativePath, field) {
  requireString(relativePath, field);
  const normalized = relativePath.replaceAll('\\', '/');
  if (normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized) || normalized.split('/').includes('..')) {
    fail(`${field} must remain within the submission bundle.`);
  }
  const resolved = path.resolve(bundleRoot, normalized);
  const relative = path.relative(bundleRoot, resolved);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    fail(`${field} resolves outside the submission bundle.`);
  }
  return { relativePath: normalized, path: resolved };
}

export async function hashFile(filePath, maximumBytes = MAX_FILE_BYTES) {
  const digest = createHash('sha256');
  let bytes = 0;
  const stream = createReadStream(filePath);
  try {
    for await (const chunk of stream) {
      bytes += chunk.length;
      if (bytes > maximumBytes) throw new Error(`File exceeds the ${maximumBytes} byte safety limit: ${filePath}`);
      digest.update(chunk);
    }
  } finally {
    stream.destroy();
  }
  return { sha256: digest.digest('hex'), bytes };
}

async function verifyBundleFile(bundleRoot, relativePath, expectedSha, field) {
  const file = resolveBundleFile(bundleRoot, relativePath, field);
  let info;
  try {
    info = await stat(file.path);
  } catch (error) {
    fail(`${field} does not exist: ${error.message}`);
  }
  if (!info.isFile()) fail(`${field} must reference a regular file.`);
  const actual = await hashFile(file.path);
  if (actual.sha256.toLowerCase() !== expectedSha.toLowerCase()) {
    fail(`${field} SHA-256 does not match the manifest.`);
  }
  return { ...file, bytes: actual.bytes, sha256: actual.sha256 };
}

function validateMedia(manifest) {
  if (!Array.isArray(manifest.media) || manifest.media.length === 0) fail('media must be a non-empty array.');
  if (manifest.media.some((item) => !item || typeof item !== 'object' || Array.isArray(item))) fail('media items must be objects.');
  const orders = manifest.media.map((item) => item?.order);
  if (orders.some((order) => !Number.isInteger(order) || order < 1)) fail('media order values must be positive integers.');
  if (new Set(orders).size !== orders.length) fail('media order values must be unique.');
  const sorted = [...orders].sort((a, b) => a - b);
  if (sorted.some((order, index) => order !== index + 1)) fail('media order values must be contiguous starting at 1.');
  const thumbnails = manifest.media.filter((item) => item?.role === 'thumbnail');
  if (thumbnails.length !== 1 || thumbnails[0].order !== 1) fail('media must contain exactly one thumbnail at order 1.');
  if (manifest.media.some((item) => item?.role !== 'thumbnail' && item?.role !== 'gallery')) fail('media roles must be thumbnail or gallery.');
}

function validateTopLevel(manifest, { requirePortalReady = true } = {}) {
  if (manifest.schemaVersion !== 2) fail('schemaVersion must equal 2.');
  if (typeof manifest.portalReady !== 'boolean') fail('portalReady must be a boolean.');
  if (requirePortalReady && manifest.portalReady !== true) fail('portalReady must be true for write-capable modes.');
  requireString(manifest.pluginName, 'pluginName');
  requireString(manifest.productVersion, 'productVersion');
  requireString(manifest.title, 'title');
  requireString(manifest.shortDescription, 'shortDescription');
  requireString(manifest.longDescription, 'longDescription');
  if (typeof manifest.listingId !== 'string' || !UUID_PATTERN.test(manifest.listingId)) fail('listingId must be a lowercase UUID.');
  requireString(manifest.productType, 'productType');
  requireString(manifest.category, 'category');
  requireArray(manifest.subcategory, 'subcategory', { allowEmpty: true });
  requireArray(manifest.tags, 'tags');
  requireArray(manifest.engineVersions, 'engineVersions');
  requireArray(manifest.platforms, 'platforms');
  requireString(manifest.includedFormat, 'includedFormat');
  requireString(manifest.license, 'license');
  requireNumber(manifest.personalPriceUsd, 'personalPriceUsd');
  requireNumber(manifest.professionalPriceUsd, 'professionalPriceUsd');
  for (const field of ['matureContent', 'generatedWithAi', 'allowsUsageWithAi', 'promotionalContent', 'forumPost']) {
    if (typeof manifest[field] !== 'boolean') fail(`${field} must be a boolean.`);
  }
  requireString(manifest.activation, 'activation');
  for (const field of ['documentationUrl', 'supportUrl']) {
    const value = requireString(manifest[field], field);
    if (!value.startsWith('https://')) fail(`${field} must be HTTPS.`);
  }
  requireString(manifest.technicalInformationFile, 'technicalInformationFile');
  if (!Array.isArray(manifest.packages) || manifest.packages.length === 0) fail('packages must be a non-empty array.');
  if (manifest.packages.length !== manifest.engineVersions.length) fail('packages count must equal engineVersions count.');
  const packageVersions = manifest.packages.map((item, index) => requireString(item?.engineVersion, `packages[${index}].engineVersion`));
  if (new Set(packageVersions).size !== packageVersions.length) fail('packages must not contain duplicate engineVersion values.');
  if (new Set(packageVersions).size !== new Set(manifest.engineVersions).size || packageVersions.some((version) => !manifest.engineVersions.includes(version)) || manifest.engineVersions.some((version) => !packageVersions.includes(version))) {
    fail('package engineVersion values must exactly equal engineVersions.');
  }
  validateMedia(manifest);
}

export async function loadSubmissionManifest(manifestPath, { requirePortalReady = true } = {}) {
  const resolvedManifestPath = path.resolve(manifestPath);
  const raw = await readFile(resolvedManifestPath);
  const manifestSha256 = createHash('sha256').update(raw).digest('hex');
  let manifest;
  try {
    manifest = JSON.parse(raw.toString('utf8'));
  } catch (error) {
    fail(`JSON parsing failed: ${error.message}`);
  }
  validateTopLevel(manifest, { requirePortalReady });
  const bundleRoot = path.dirname(resolvedManifestPath);
  const technicalInformation = resolveBundleFile(bundleRoot, manifest.technicalInformationFile, 'technicalInformationFile');
  const technicalInfo = await stat(technicalInformation.path).catch((error) => fail(`technicalInformationFile does not exist: ${error.message}`));
  if (!technicalInfo.isFile()) fail('technicalInformationFile must reference a regular file.');
  let technicalInformationText;
  try {
    const decoder = new TextDecoder('utf-8', { fatal: true });
    technicalInformationText = decoder.decode(await readFile(technicalInformation.path));
  } catch (error) {
    fail(`technicalInformationFile must be valid UTF-8 text: ${error.message}`);
  }

  const mediaFiles = [];
  for (const item of manifest.media) {
    const sha256 = requireSha256(item.sha256, `media[${item.order}].sha256`);
    mediaFiles.push({
      ...item,
      ...(await verifyBundleFile(bundleRoot, item.bundleRelativePath, sha256, `media[${item.order}].bundleRelativePath`)),
      sha256,
    });
  }

  const packageFiles = [];
  for (const [index, item] of manifest.packages.entries()) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) fail(`packages[${index}] must be an object.`);
    requireString(item.engineVersion, `packages[${index}].engineVersion`);
    if (!Object.prototype.hasOwnProperty.call(item, 'projectFileLink')) fail(`packages[${index}].projectFileLink must be present and either HTTPS or null.`);
    const projectFileLink = item.projectFileLink;
    if (projectFileLink === null) {
      if (requirePortalReady) fail(`packages[${index}].projectFileLink must be HTTPS for write-capable modes.`);
    } else {
      requireString(projectFileLink, `packages[${index}].projectFileLink`);
      if (!projectFileLink.startsWith('https://')) fail(`packages[${index}].projectFileLink must be HTTPS.`);
    }
    const sha256 = requireSha256(item.sha256, `packages[${index}].sha256`);
    packageFiles.push({
      ...item,
      projectFileLink,
      ...(await verifyBundleFile(bundleRoot, item.bundleRelativePath, sha256, `packages[${index}].bundleRelativePath`)),
      sha256,
    });
  }

  return {
    manifest,
    manifestPath: resolvedManifestPath,
    manifestSha256,
    bundleRoot,
    technicalInformation,
    technicalInformationText,
    mediaFiles,
    packageFiles,
  };
}

export { MAX_FILE_BYTES };
