// Fab's observed `kB` value maps to 1024 bytes per unit (16,946 bytes is
// displayed as 16.55 kB). IEC spellings are unambiguous; SI/legacy uppercase
// spellings are left unknown unless Fab-specific evidence establishes them.
const SIZE_UNITS = new Map([
  ['kB', 1024n], ['KiB', 1024n],
  ['MiB', 1024n ** 2n], ['GiB', 1024n ** 3n],
]);

function ceilDiv(numerator, denominator) {
  return (numerator + denominator - 1n) / denominator;
}

function asSafeInteger(value) {
  if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(value);
}

function roundedByteRange(displayValue, multiplier) {
  const [whole, fraction = ''] = displayValue.split('.');
  const scale = 10n ** BigInt(fraction.length);
  const shownUnits = BigInt(whole) * scale + BigInt(fraction || '0');
  const denominator = 2n * scale;
  const minimum = ceilDiv((2n * shownUnits - 1n) * multiplier, denominator);
  const maximum = ceilDiv((2n * shownUnits + 1n) * multiplier, denominator) - 1n;
  const minimumBytes = asSafeInteger(minimum < 0n ? 0n : minimum);
  const maximumBytes = asSafeInteger(maximum);
  return minimumBytes === null || maximumBytes === null || minimumBytes > maximumBytes
    ? null
    : { minimumBytes, maximumBytes };
}

export function parsePortalFileSizeEvidence({ rawBytes = null, displayText = '' } = {}) {
  if (rawBytes !== null && rawBytes !== undefined && /^\d+$/.test(String(rawBytes).trim())) {
    const bytes = Number(rawBytes);
    if (Number.isSafeInteger(bytes)) return { precision: 'exact', bytes, range: { minimumBytes: bytes, maximumBytes: bytes }, source: 'exact-metadata' };
  }

  const text = String(displayText ?? '');
  const exact = /\b([\d,]+)\s+bytes?\b/i.exec(text);
  if (exact) {
    const bytes = Number(exact[1].replaceAll(',', ''));
    if (Number.isSafeInteger(bytes)) return { precision: 'exact', bytes, range: { minimumBytes: bytes, maximumBytes: bytes }, source: 'visible-byte-count' };
  }

  const display = /(?<![\d.])(\d+(?:\.\d+)?)\s*(kB|KB|KiB|MB|MiB|GB|GiB)\b/.exec(text);
  if (!display) return { precision: 'unknown', bytes: null, range: null, source: null };
  const multiplier = SIZE_UNITS.get(display[2]);
  if (!multiplier) return { precision: 'unknown', bytes: null, range: null, source: 'ambiguous-unit', displayedValue: display[0] };
  const range = roundedByteRange(display[1], multiplier);
  return range
    ? { precision: 'rounded', bytes: null, range, source: 'visible-rounded-size', displayedValue: display[0] }
    : { precision: 'unknown', bytes: null, range: null, source: 'unrepresentable-rounded-size', displayedValue: display[0] };
}

export function normalizePortalFileName(value) {
  const basename = String(value ?? '').trim().split(/[\\/]/).at(-1) ?? '';
  return basename.toLocaleLowerCase().replace(/[^a-z0-9]/g, '');
}
