import { createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const listingId = '11111111-1111-4111-8111-111111111111';

export function makeManifest(overrides = {}) {
  const base = {
    schemaVersion: 2,
    pluginName: 'FixturePlugin',
    productVersion: '1.0.0',
    listingId,
    title: 'Fixture Product',
    shortDescription: 'Fixture short description',
    longDescription: 'Fixture long description',
    productType: 'Tools & Plugins',
    category: 'Network & Multiplayer',
    subcategory: [],
    tags: ['Plugin'],
    includedFormat: 'Unreal Engine',
    engineVersions: ['5.8'],
    platforms: ['Win64'],
    license: 'Fab Standard License',
    personalPriceUsd: 9.99,
    professionalPriceUsd: 29.99,
    matureContent: false,
    generatedWithAi: true,
    allowsUsageWithAi: true,
    promotionalContent: false,
    forumPost: false,
    activation: 'Manual activation',
    documentationUrl: 'https://example.com/docs',
    supportUrl: 'https://example.com/support',
    technicalInformationFile: 'submission/FabTechnicalInformation.txt',
    media: [{ order: 1, role: 'thumbnail', bundleRelativePath: 'media/001.jpg', sha256: 'a'.repeat(64) }],
    packages: [{ engineVersion: '5.8', bundleRelativePath: 'packages/UE5.8/package.zip', sha256: 'b'.repeat(64), projectFileLink: 'https://example.com/package.zip' }],
    portalReady: true,
  };
  return structuredClone({ ...base, ...overrides });
}

export function fixtureState(manifest, overrides = {}) {
  return {
    status: 'Draft',
    title: manifest.title,
    shortDescription: manifest.shortDescription,
    longDescription: manifest.longDescription,
    productType: manifest.productType,
    category: manifest.category,
    tags: manifest.tags,
    engineVersions: manifest.engineVersions,
    personalPriceUsd: manifest.personalPriceUsd,
    professionalPriceUsd: manifest.professionalPriceUsd,
    matureContent: manifest.matureContent,
    generatedWithAi: manifest.generatedWithAi,
    allowsUsageWithAi: manifest.allowsUsageWithAi,
    promotionalContent: manifest.promotionalContent,
    forumPost: manifest.forumPost,
    activation: manifest.activation,
    documentationUrl: manifest.documentationUrl,
    supportUrl: manifest.supportUrl,
    technicalInformationFile: manifest.technicalInformationFile,
    projectFileLink: manifest.packages[0].projectFileLink,
    mediaExisting: 'known',
    mediaOrder: manifest.media.map((item) => `${item.order}:${item.role}`).join(','),
    disableSave: false,
    ...overrides,
  };
}

export async function makeManifestInfo(manifest, { mediaFiles = [] } = {}) {
  const temp = await fsTemp();
  await writeFile(path.join(temp, 'manifest.json'), JSON.stringify(manifest));
  return { manifest, manifestPath: path.join(temp, 'manifest.json'), manifestSha256: createHash('sha256').update(JSON.stringify(manifest)).digest('hex'), bundleRoot: temp, mediaFiles, packageFiles: [] };
}

async function fsTemp() {
  const { mkdtemp } = await import('node:fs/promises');
  return mkdtemp(path.join(os.tmpdir(), 'fab-portal-fixture-'));
}
