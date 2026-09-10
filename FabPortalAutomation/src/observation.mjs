import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fieldView, normalizeText } from './comparison.mjs';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const OBSERVATION_STATES = new Set(['OBSERVED', 'NOT_VISIBLE', 'NOT_DISCOVERED', 'NOT_APPLICABLE']);
const SOURCES = new Set(['interactive-browser', 'cdp']);
const VIEWS = new Set(['listing', 'format']);
const ROOT_KEYS = new Set(['schemaVersion', 'source', 'manifestSha256', 'observedAtUtc', 'listingId', 'listingTitle', 'listingStatus', 'fields']);
const FIELD_KEYS = new Set(['manifestJsonPath', 'state', 'value', 'view', 'note']);
const BASE_PATHS = [
  'title', 'shortDescription', 'longDescription', 'productType', 'category', 'subcategory', 'tags',
  'includedFormat', 'engineVersions', 'platforms', 'license', 'personalPriceUsd',
  'professionalPriceUsd', 'matureContent', 'generatedWithAi', 'allowsUsageWithAi',
  'promotionalContent', 'forumPost', 'activation', 'documentationUrl', 'supportUrl',
  'technicalInformationFile', 'media',
];

function fail(message) {
  throw new Error(`FabPortalObservation invalid: ${message}`);
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertExactKeys(value, allowed, field) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`${field} contains unsupported property ${key}.`);
  }
}

function expectedPaths(manifest) {
  return [...BASE_PATHS, ...manifest.packages.map((_item, index) => `packages[${index}].projectFileLink`)].sort();
}

function requireNonBlankString(value, field) {
  if (typeof value !== 'string' || value.trim() === '') fail(`${field} must be non-blank text.`);
}

function requireStringArray(value, field, { allowEmpty = false } = {}) {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) fail(`${field} must be a ${allowEmpty ? '' : 'non-empty '}string array.`);
  if (value.some((item) => typeof item !== 'string' || item.trim() === '')) fail(`${field} must contain only non-blank strings.`);
}

function isJsonValue(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return true;
  if (typeof value === 'number') return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJsonValue);
  if (isRecord(value)) return Object.values(value).every(isJsonValue);
  return false;
}

function validateMediaValue(value) {
  if (!isRecord(value)) fail('media OBSERVED value must be an object.');
  assertExactKeys(value, new Set(['count', 'items']), 'media value');
  if (!Number.isInteger(value.count) || value.count < 0) fail('media.count must be a non-negative integer.');
  if (!Array.isArray(value.items)) fail('media.items must be an array.');
  if (value.items.some((item) => !isRecord(item))) fail('media.items must contain objects.');
  const orders = [];
  for (const [index, item] of value.items.entries()) {
    assertExactKeys(item, new Set(['order', 'role']), `media.items[${index}]`);
    if (!Number.isInteger(item.order) || item.order < 1) fail(`media.items[${index}].order must be a positive integer.`);
    if (!['thumbnail', 'gallery'].includes(item.role)) fail(`media.items[${index}].role is invalid.`);
    orders.push(item.order);
  }
  if (value.count !== value.items.length) fail('media.count must equal media.items.length.');
  if (new Set(orders).size !== orders.length) fail('media.items order values must be unique.');
}

function validateObservedValue(fieldPath, value, manifest) {
  if (!isJsonValue(value)) fail(`${fieldPath}.value is not a JSON value.`);
  if (fieldPath === 'subcategory') return requireStringArray(value, fieldPath, { allowEmpty: true });
  if (['tags', 'engineVersions', 'platforms'].includes(fieldPath)) return requireStringArray(value, fieldPath);
  if (['matureContent', 'generatedWithAi', 'allowsUsageWithAi', 'promotionalContent', 'forumPost'].includes(fieldPath)) {
    if (typeof value !== 'boolean') fail(`${fieldPath}.value must be boolean.`);
    return;
  }
  if (['personalPriceUsd', 'professionalPriceUsd'].includes(fieldPath)) {
    if (!((typeof value === 'number' && Number.isFinite(value) && value >= 0) || (typeof value === 'string' && value.trim() !== ''))) {
      fail(`${fieldPath}.value must be a USD number or visible USD text.`);
    }
    return;
  }
  if (fieldPath === 'media') return validateMediaValue(value);
  if (fieldPath.startsWith('packages[')) {
    const match = /^packages\[(\d+)\]\.projectFileLink$/.exec(fieldPath);
    const index = Number(match[1]);
    if (manifest.packages[index].projectFileLink === null) fail(`${fieldPath} must be NOT_APPLICABLE because the manifest link is null.`);
    return requireNonBlankString(value, `${fieldPath}.value`);
  }
  requireNonBlankString(value, `${fieldPath}.value`);
}

function validateObservation(observation, manifestInfo) {
  if (!isRecord(observation)) fail('root must be an object.');
  assertExactKeys(observation, ROOT_KEYS, 'root');
  if (observation.schemaVersion !== 1) fail('schemaVersion must equal 1.');
  if (!SOURCES.has(observation.source)) fail('source must be interactive-browser or cdp.');
  if (typeof observation.manifestSha256 !== 'string' || !SHA256_PATTERN.test(observation.manifestSha256)) fail('manifestSha256 must be 64 lowercase hexadecimal characters.');
  if (observation.manifestSha256 !== manifestInfo.manifestSha256) fail('manifestSha256 does not match the supplied FabPortalSubmission.json bytes.');
  if (typeof observation.observedAtUtc !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(observation.observedAtUtc) || Number.isNaN(Date.parse(observation.observedAtUtc))) fail('observedAtUtc must be a valid ISO-8601 UTC timestamp.');
  if (typeof observation.listingId !== 'string' || !UUID_PATTERN.test(observation.listingId)) fail('listingId must be a lowercase UUID.');
  if (observation.listingId !== manifestInfo.manifest.listingId) fail('listingId does not match the manifest listingId.');
  requireNonBlankString(observation.listingTitle, 'listingTitle');
  if (normalizeText(observation.listingTitle) !== normalizeText(manifestInfo.manifest.title)) fail('listingTitle does not match the manifest title after normalization.');
  requireNonBlankString(observation.listingStatus, 'listingStatus');
  if (!Array.isArray(observation.fields) || observation.fields.length === 0) fail('fields must be a non-empty array.');
  const allowedPaths = new Set(expectedPaths(manifestInfo.manifest));
  const seen = new Set();
  for (const [index, field] of observation.fields.entries()) {
    if (!isRecord(field)) fail(`fields[${index}] must be an object.`);
    assertExactKeys(field, FIELD_KEYS, `fields[${index}]`);
    requireNonBlankString(field.manifestJsonPath, `fields[${index}].manifestJsonPath`);
    if (!allowedPaths.has(field.manifestJsonPath)) fail(`fields[${index}] has unsupported manifestJsonPath ${field.manifestJsonPath}.`);
    if (seen.has(field.manifestJsonPath)) fail(`duplicate manifestJsonPath ${field.manifestJsonPath}.`);
    seen.add(field.manifestJsonPath);
    if (!OBSERVATION_STATES.has(field.state)) fail(`fields[${index}].state is invalid.`);
    if (!VIEWS.has(field.view) || field.view !== fieldView(field.manifestJsonPath)) fail(`fields[${index}].view does not match the manifest field view.`);
    const hasValue = Object.prototype.hasOwnProperty.call(field, 'value');
    if (field.state === 'OBSERVED') {
      if (!hasValue) fail(`fields[${index}] OBSERVED entries require value.`);
      validateObservedValue(field.manifestJsonPath, field.value, manifestInfo.manifest);
    } else if (hasValue) {
      fail(`fields[${index}] ${field.state} entries must not provide value.`);
    }
    if (Object.prototype.hasOwnProperty.call(field, 'note')) {
      if (typeof field.note !== 'string' || field.note.trim() === '' || field.note.length > 500 || /[<>]/.test(field.note)) fail(`fields[${index}].note must be a short non-secret text note.`);
    }
  }
  const missing = [...allowedPaths].filter((fieldPath) => !seen.has(fieldPath));
  if (missing.length > 0) fail(`missing expected field observations: ${missing.join(', ')}.`);
  return observation;
}

export async function loadFabPortalObservation(observationPath, manifestInfo) {
  const resolvedPath = path.resolve(observationPath);
  const raw = await readFile(resolvedPath);
  const observationSha256 = createHash('sha256').update(raw).digest('hex');
  let observation;
  try {
    observation = JSON.parse(raw.toString('utf8'));
  } catch (error) {
    fail(`JSON parsing failed: ${error.message}`);
  }
  validateObservation(observation, manifestInfo);
  return { observation, observationPath: resolvedPath, observationSha256 };
}

export { expectedPaths, validateObservation };
