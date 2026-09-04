export const DEFAULT_WIDE_VIEWPORT = Object.freeze({ width: 1440, height: 900 });

function sameViewport(left, right) {
  return left?.width === right?.width && left?.height === right?.height;
}

export async function readViewport(page) {
  const viewport = await page.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }));
  if (!Number.isInteger(viewport?.width) || !Number.isInteger(viewport?.height) || viewport.width <= 0 || viewport.height <= 0) {
    throw new Error('Browser viewport could not be read safely.');
  }
  return viewport;
}

async function restoreViewport(page, original, diagnostics) {
  await page.setViewportSize(original);
  const restored = await readViewport(page);
  diagnostics.restored = sameViewport(restored, original);
  if (!diagnostics.restored) throw new Error(`Browser viewport was not restored to ${original.width}x${original.height}.`);
}

export async function acquireResponsiveViewportLease(page, { isMounted, diagnostics = null, wideViewport = DEFAULT_WIDE_VIEWPORT, timeoutMs = 3000 } = {}) {
  if (typeof isMounted !== 'function') throw new Error('Responsive viewport lease requires a format navigation observation callback.');
  const evidence = diagnostics ?? {};
  const original = await readViewport(page);
  evidence.originalWidth = original.width;
  evidence.originalHeight = original.height;
  evidence.temporaryWideViewportUsed = false;
  evidence.observationWidth = original.width;
  evidence.observationHeight = original.height;
  evidence.restored = false;

  if (await isMounted()) {
    return {
      async release() {
        const current = await readViewport(page);
        if (sameViewport(current, original)) {
          evidence.restored = true;
          return;
        }
        await restoreViewport(page, original, evidence);
      },
    };
  }

  await page.setViewportSize(wideViewport);
  evidence.temporaryWideViewportUsed = true;
  const deadline = Date.now() + timeoutMs;
  let mounted = false;
  while (Date.now() < deadline) {
    if (await isMounted()) {
      mounted = true;
      break;
    }
    await page.waitForTimeout(Math.min(50, Math.max(1, deadline - Date.now())));
  }
  const observation = await readViewport(page);
  evidence.observationWidth = observation.width;
  evidence.observationHeight = observation.height;
  if (!mounted) {
    try {
      await restoreViewport(page, original, evidence);
    } catch (restoreError) {
      throw new Error(`Responsive format navigation did not mount; viewport restoration also failed: ${restoreError.message}`);
    }
    throw new Error(`Responsive format navigation did not mount at ${wideViewport.width}x${wideViewport.height}.`);
  }

  let released = false;
  return {
    async release() {
      if (released) return;
      released = true;
      await restoreViewport(page, original, evidence);
    },
  };
}
