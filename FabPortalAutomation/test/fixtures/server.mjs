import http from 'node:http';

function html(value) {
  return String(value ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function pageMarkup(state, listingId) {
  const checked = (value) => value ? ' checked' : '';
  const radio = (label, isChecked) => `<label>${html(label)}<input type="radio" aria-label="${html(label)}"${checked(isChecked)}></label>`;
  const challengeMarkup = `<section data-testid="fixture-challenge"${state.challengeVisible ? '' : ' hidden'}><h2>Verify you are human</h2><p>Cloudflare security check</p></section>`;
  const confirmationButtons = (state.submitConfirmationButtons ?? ['Confirm']).map((label) => `<button type="button" data-testid="submit-confirm">${html(label)}</button>`).join('');
  const confirmationDialog = state.submitFlow === 'confirmation'
    ? `<div role="dialog" aria-label="Submit for review confirmation" hidden><h2>Submit for review?</h2>${confirmationButtons}<button type="button" data-testid="submit-cancel">Cancel</button></div>`
    : '';
  const unrelatedDialog = state.preExistingDialog
    ? '<div role="dialog" aria-label="Unrelated information"><h2>Unrelated information</h2><p>This dialog is not a submission confirmation.</p><button type="button" data-testid="unrelated-dialog-close">Close</button></div>'
    : '';
  const statusMarkup = state.statusRendering === 'plain-text'
    ? `<div data-status-value>${html(state.status)}</div>`
    : `<div data-testid="listing-status" data-status-value>${html(state.status)}</div>`;
  const productFormats = state.productFormats ?? [{ name: 'Unreal Engine' }];
  const prefetchedFormats = state.prefetchedAssetFormats === 'missing'
    ? undefined
    : state.prefetchedAssetFormats ?? productFormats.map((format) => ({ assetFormatType: { code: format.code ?? format.name.toLowerCase().replaceAll(' ', '-'), name: format.name } }));
  const prefetchedListing = {
    uid: listingId,
    ...(state.prefetchedListingFields ?? {}),
    ...(prefetchedFormats === undefined ? {} : { assetFormats: prefetchedFormats }),
  };
  const prefetchedKey = state.prefetchedListingId ?? listingId;
  const prefetchedData = JSON.stringify({
    [`/i/portal/listings/${prefetchedKey}`]: prefetchedListing,
    ...(state.prefetchedCategoryEntries ? { '/i/taxonomy/categories/tree': { results: { 'tool-and-plugin': state.prefetchedCategoryEntries } } } : {}),
  }).replaceAll('<', '\\u003c');
  const addFormatButtons = Array.from({ length: state.addFormatButtonCount ?? 1 }, () => '<button type="button" aria-label="Add new format">Add new format</button>').join('');
  const delayedChoiceStyle = state.formatChoiceDelayMs ? ' style="display:none"' : '';
  const formatChoices = Array.from({ length: state.formatChoiceCount ?? 1 }, () => `<button type="button" role="option" aria-label="Unreal Engine"${delayedChoiceStyle}>Unreal Engine</button>`).join('');
  const nextFormatButton = state.formatChoiceNeedsNext ? '<button type="button" aria-label="Confirm selected option: Unreal Engine" disabled>Next</button><button type="button" aria-label="Confirm" hidden>Confirm</button>' : '';
  const responsiveStyle = state.responsiveFormatNavigation ? '<style>[data-responsive-format-navigation]{display:block}@media (max-width: 1000px){[data-responsive-format-navigation]{display:none}}</style>' : '';
  const formatInventory = `<section aria-label="Included Files" data-testid="product-formats" data-responsive-format-navigation="${state.responsiveFormatNavigation ? 'true' : 'false'}" data-format-count="${productFormats.length}"${state.hideFormatInventory ? ' hidden' : ''}><h2>Included Files</h2>${productFormats.map((format) => `<button type="button" data-format-name="${html(format.name)}">${html(format.name)}</button>`).join('')}${addFormatButtons}</section>`;
  const formatChooser = `<div role="dialog" aria-label="Add new format" hidden><h2>Add new format</h2>${formatChoices}${nextFormatButton}</div>`;
  const strayFormatButton = state.strayFormatButton ? '<button type="button" aria-label="Unreal Engine">Unreal Engine</button>' : '';
  const listingControls = `
    <input role="combobox" aria-label="Search" disabled>
    <h1>${html(state.title)}</h1>
    ${statusMarkup}
    <label>Title *<input aria-label="Title *" value="${html(state.title)}" ${state.disableFields?.includes('title') ? 'disabled' : ''}></label>
    <label>Short description *<input aria-label="Short description *" value="${html(state.shortDescription)}" ${state.disableFields?.includes('shortDescription') ? 'disabled' : ''}></label>
    <label>Description *<div role="textbox" aria-label="Description *" contenteditable="true">${html(state.longDescription)}</div></label>
    <label>Product type *<select aria-label="Product type *">${(state.productTypeOptions ?? [state.productType]).map((option) => `<option${option === state.productType ? ' selected' : ''}>${html(option)}</option>`).join('')}</select></label>
    <label>Category *<input role="combobox" aria-label="Category selection" value="${html(state.category)}"></label>
    <label>Tags *<input aria-label="Tags *" value="${html(state.tags[0] ?? '')}"${state.tagsEditable ? '' : ' readonly'}>${state.tagsCount ? `<input role="combobox" aria-label="${html(state.tagSearchAriaLabel ?? 'Search a tag')}" placeholder="${html(state.tagSearchPlaceholder ?? 'Search a tag')}"><span id="tagsCount">${html(state.tagsCount)}</span>${(state.tagOptions ?? []).map((tag) => `<div role="option" aria-label="${html(tag)}">${html(tag)}</div>`).join('')}` : ''}</label>
    ${formatInventory}${strayFormatButton}
    ${state.mainProjectVersionsVisible ? '<h2>Project Versions*</h2><a href="/portal/listings">Back to listings</a>' : ''}
    ${radio('Standard License (Free or Paid)', true)}
    <label>Personal price *<input aria-label="Personal price *" value="${html(state.personalPriceUsd)}"></label>
    <label>Professional price *<input aria-label="Professional price *" value="${html(state.professionalPriceUsd)}"></label>
    ${radio('No, this listing does not contain mature content.', !state.matureContent)}
    ${radio('Yes, it was partly or fully created with generative AI', state.generatedWithAi)}
    <label>${html('Do not allow this product to be used by Generative AI Programs.')}<input type="checkbox" aria-label="Do not allow this product to be used by Generative AI Programs."${checked(!state.allowsUsageWithAi)}></label>
    <label>${html('Includes promotional content')}<input type="checkbox" aria-label="Includes promotional content"${checked(state.promotionalContent)}></label>
    ${radio('No, do not create a forum post', !state.forumPost)}
    <label>Activation<input aria-label="Activation" value="${html(state.activation)}"></label>
    ${(state.readOnlySections ?? []).map((label, index) => `<button type="button" aria-label="toggle ${html(label)}" aria-expanded="false" aria-controls="fixture-section-${index}">toggle ${html(label)}</button><section id="fixture-section-${index}" hidden>${html(label)} content</section>`).join('')}
    <button type="button" data-testid="save" ${state.disableSave ? 'disabled' : ''}>Save</button>
    <button type="button" data-testid="submit">Submit for review</button>
    <button type="button" data-testid="cancel">Cancel submission</button>
    ${unrelatedDialog}
    ${confirmationDialog}${formatChooser}`;
  const formatControls = `
    ${state.omitFormatBack ? '' : '<button type="button" aria-label="Back to listing">Back to listing</button>'}
    ${state.formatListingSummaryVisible ? `<button type="button" data-testid="format-listing-summary">${html(state.title)} Tools &amp; Plugins From $29.99</button>` : ''}
    ${state.formatTitleVisible ? `<span data-testid="format-listing-title">${html(state.title)}</span>` : ''}
    <h2>Unreal Engine</h2>
    <h2>Manage format</h2>
    <h3>Project Versions*</h3>
    ${state.engineVersions.map((version) => `<div>UE_${html(version)}</div>`).join('')}
    <button type="button" aria-label="Remove ${html(state.platformDisplay ?? 'Windows')}">Remove ${html(state.platformDisplay ?? 'Windows')}</button>
    <label>Project File Link<input aria-label="Project File Link" value="${html(state.projectFileLink)}" ${state.disableFields?.includes('projectFileLink') ? 'disabled' : ''}></label>
    <section aria-label="Technical details">
      <p>Documentation: ${html(state.documentationUrl)}</p>
      <p>Support: ${html(state.supportUrl)}</p>
      <div ${state.technicalInformationNoLabel ? '' : 'aria-label="Technical Information" '}contenteditable="true">${html(state.technicalInformationText)}</div>
    </section>
    <section data-testid="media-gallery" data-existing="${html(state.mediaExisting)}" data-order="${html(state.mediaOrder ?? '')}" data-upload-order="${html(initialStateMediaOrder(state))}">${html(state.mediaExisting === 'existing' ? 'Existing media' : state.mediaExisting === 'known' || state.mediaExisting === 'uploaded' ? '001 thumbnail 002 gallery' : 'Empty gallery')}</section>
    <input type="file" data-testid="media-upload" multiple>`;
  return `<!doctype html><html><head><title>Fab fixture</title>${responsiveStyle}</head><body>
  <script id="js-json-data-prefetched-data" type="application/json">${prefetchedData}</script>
  <main id="listing-view">${listingControls}</main>
  <main id="format-view" hidden>${formatControls}</main>
  ${challengeMarkup}
  <script>
    const listingView = document.querySelector('#listing-view');
    const formatView = document.querySelector('#format-view');
    const value = (selector) => document.querySelector(selector)?.value ?? '';
    const syncFormatState = () => {
      const project = document.querySelector('[aria-label="Project File Link"]');
      if (project) window.fixtureProjectFileLink = project.value;
      const technical = formatView.querySelector('[contenteditable="true"]');
      if (technical) window.fixtureTechnicalInformationText = technical.innerText;
    };
    const setView = (view) => {
      syncFormatState();
      const main = view === 'listing';
      if (main && ${JSON.stringify(state.dropStagedFields ?? [])}.includes('projectFileLink')) {
        const project = document.querySelector('[aria-label="Project File Link"]');
        if (project) project.value = ${JSON.stringify(state.projectFileLink)};
        window.fixtureProjectFileLink = ${JSON.stringify(state.projectFileLink)};
      }
      listingView.hidden = !main;
      formatView.hidden = main;
    };
    const payload = () => ({
      title: value('[aria-label="Title *"]'),
      shortDescription: value('[aria-label="Short description *"]'),
      longDescription: document.querySelector('[aria-label="Description *"]')?.innerText ?? '',
      productType: value('[aria-label="Product type *"]'),
      category: value('[aria-label="Category selection"]'),
      personalPriceUsd: value('[aria-label="Personal price *"]'),
      professionalPriceUsd: value('[aria-label="Professional price *"]'),
      matureContent: !document.querySelector('[aria-label="No, this listing does not contain mature content."]')?.checked,
      generatedWithAi: document.querySelector('[aria-label="Yes, it was partly or fully created with generative AI"]')?.checked ?? false,
      allowsUsageWithAi: !(document.querySelector('[aria-label="Do not allow this product to be used by Generative AI Programs."]')?.checked ?? false),
      promotionalContent: document.querySelector('[aria-label="Includes promotional content"]')?.checked ?? false,
      forumPost: !document.querySelector('[aria-label="No, do not create a forum post"]')?.checked,
      activation: value('[aria-label="Activation"]'),
      documentationUrl: ${JSON.stringify(state.documentationUrl)},
      supportUrl: ${JSON.stringify(state.supportUrl)},
      technicalInformationText: window.fixtureTechnicalInformationText ?? ${JSON.stringify(state.technicalInformationText)},
      projectFileLink: window.fixtureProjectFileLink ?? ${JSON.stringify(state.projectFileLink)},
      mediaExisting: document.querySelector('[data-testid="media-gallery"]')?.dataset.existing ?? 'existing',
      mediaOrder: document.querySelector('[data-testid="media-gallery"]')?.dataset.order ?? ''
    });
    document.querySelectorAll('[data-format-name]').forEach((button) => button.addEventListener('click', () => setView('format')));
    document.querySelectorAll('[aria-label="Add new format"]').forEach((button) => button.addEventListener('click', () => {
      const dialog = document.querySelector('[role="dialog"][aria-label="Add new format"]');
      dialog.hidden = false;
      if (${JSON.stringify(state.formatChoiceDelayMs ?? 0)} > 0) {
        setTimeout(() => dialog.querySelectorAll('[role="option"]').forEach((choice) => { choice.style.display = ''; }), ${JSON.stringify(state.formatChoiceDelayMs ?? 0)});
      }
    }));
    const createFormat = async () => {
      if (${JSON.stringify(Boolean(state.challengeAfterFormatCreate))}) revealChallenge();
      await fetch(${JSON.stringify(state.formatCreateRequestPath ?? '/api/create-format')}, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: 'Unreal Engine' }) });
      const inventory = document.querySelector('[data-testid="product-formats"]');
      inventory.dataset.formatCount = '1';
      const button = document.createElement('button');
      button.type = 'button';
      button.dataset.formatName = 'Unreal Engine';
      button.textContent = 'Unreal Engine';
      button.addEventListener('click', () => setView('format'));
      inventory.insertBefore(button, inventory.querySelector('[aria-label="Add new format"]'));
      document.querySelector('[role="dialog"][aria-label="Add new format"]').hidden = true;
    };
    document.querySelectorAll('[role="option"][aria-label="Unreal Engine"]').forEach((choice) => choice.addEventListener('click', async () => {
      if (${JSON.stringify(Boolean(state.formatChoiceNeedsNext))}) {
        choice.setAttribute('aria-selected', 'true');
        const next = document.querySelector('[role="dialog"][aria-label="Add new format"] [aria-label="Confirm selected option: Unreal Engine"]');
        if (next) next.disabled = false;
        return;
      }
      await createFormat();
    }));
    document.querySelector('[role="dialog"][aria-label="Add new format"] [aria-label="Confirm selected option: Unreal Engine"]')?.addEventListener('click', () => {
      if (${JSON.stringify(Boolean(state.formatChoiceNeedsNext))}) {
        const next = document.querySelector('[role="dialog"][aria-label="Add new format"] [aria-label="Confirm selected option: Unreal Engine"]');
        const confirm = document.querySelector('[role="dialog"][aria-label="Add new format"] [aria-label="Confirm"]');
        if (next) next.hidden = true;
        if (confirm) confirm.hidden = false;
        return;
      }
      createFormat();
    });
    document.querySelector('[role="dialog"][aria-label="Add new format"] [aria-label="Confirm"]')?.addEventListener('click', createFormat);
    document.querySelector('[aria-label="Back to listing"]')?.addEventListener('click', () => setView('listing'));
    document.querySelector('[data-testid="format-listing-summary"]')?.addEventListener('click', () => setView('listing'));
    document.querySelector('[data-testid="save"]').addEventListener('click', () => { syncFormatState(); if (${JSON.stringify(Boolean(state.challengeAfterSave))}) revealChallenge(); fetch('/api/save', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload()) }); });
    const submitRequest = async () => {
      const response = await fetch(${JSON.stringify(state.submitRequestPath ?? '/api/submit')}, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({}) });
      if (response.ok && ${JSON.stringify((state.submitRequestPath ?? '/api/submit') === '/api/submit' && !state.submitStaysDraft && !state.submitRequestFailure)}) document.querySelector('[data-status-value]').textContent = 'Pending approval';
    };
    document.querySelector('[data-testid="submit"]').addEventListener('click', () => {
      if (${JSON.stringify(state.submitFlow === 'confirmation')}) document.querySelector('[role="dialog"]').hidden = false;
      else submitRequest();
    });
    document.querySelectorAll('[data-testid="submit-confirm"]').forEach((button) => button.addEventListener('click', submitRequest));
    document.querySelector('[data-testid="submit-cancel"]')?.addEventListener('click', () => fetch('/api/cancel', { method: 'POST' }));
    document.querySelector('[data-testid="cancel"]').addEventListener('click', () => fetch('/api/cancel', { method: 'POST' }));
    let stagedInputObserved = false;
    const challenge = document.querySelector('[data-testid="fixture-challenge"]');
    const revealChallenge = () => { if (challenge) challenge.hidden = false; };
    document.querySelectorAll('input,select,[contenteditable="true"]').forEach((control) => control.addEventListener('input', () => {
      if (${state.challengeAfterFirstMutation ? 'true' : 'false'} && !stagedInputObserved) {
        stagedInputObserved = true;
        revealChallenge();
      }
    }));
    document.querySelectorAll('[aria-expanded="false"][aria-controls^="fixture-section-"]').forEach((toggle) => toggle.addEventListener('click', () => {
      if (${state.readOnlySectionMutation ? 'true' : 'false'}) fetch('/api/read-only-expansion', { method: 'POST' }).catch(() => undefined);
      if (${state.challengeOnReadOnlyExpansion ? 'true' : 'false'}) revealChallenge();
      toggle.setAttribute('aria-expanded', 'true');
      document.getElementById(toggle.getAttribute('aria-controls')).hidden = false;
    }));
    document.querySelector('[data-testid="media-upload"]').addEventListener('change', () => { const gallery = document.querySelector('[data-testid="media-gallery"]'); gallery.dataset.existing = 'uploaded'; gallery.dataset.order = gallery.dataset.uploadOrder; gallery.textContent = '001 thumbnail 002 gallery'; });
    const revealFormatAfterField = ${JSON.stringify(state.revealFormatAfterField ?? null)};
    if (revealFormatAfterField) document.querySelectorAll('input,select,[contenteditable="true"]').forEach((control) => control.addEventListener('input', () => { if (control.getAttribute('aria-label') === revealFormatAfterField) document.querySelector('[data-testid="product-formats"]')?.removeAttribute('hidden'); }));
    if (revealFormatAfterField) document.querySelectorAll('select').forEach((control) => control.addEventListener('change', () => { if (control.getAttribute('aria-label') === revealFormatAfterField) document.querySelector('[data-testid="product-formats"]')?.removeAttribute('hidden'); }));
  </script>
  </body></html>`;
}

function initialStateMediaOrder(state) {
  return state.mediaOrder ?? '1:thumbnail';
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

export async function startFixture(initialState, { dropSaveFields = [], redirectListingId = null } = {}) {
  const state = structuredClone(initialState);
  const requests = [];
  const mutations = [];
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    requests.push({ method: request.method, pathname: url.pathname });
    if (request.method === 'GET' && url.pathname.startsWith('/portal/listings/')) {
      const listingId = url.pathname.split('/')[3];
      if (redirectListingId && listingId !== redirectListingId) {
        response.writeHead(302, { location: `/portal/listings/${redirectListingId}/edit` });
        response.end();
        return;
      }
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(pageMarkup(state, listingId));
      return;
    }
    if (request.method === 'PATCH' && url.pathname.startsWith('/i/portal/listings/')) {
      const body = JSON.parse(await readBody(request) || '{}');
      mutations.push({ method: 'PATCH', pathname: url.pathname, body });
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/save') {
      const body = JSON.parse(await readBody(request) || '{}');
      mutations.push({ method: 'POST', pathname: url.pathname, body });
      for (const [key, value] of Object.entries(body)) if (!dropSaveFields.includes(key)) state[key] = value;
      if (state.challengeAfterSave) state.challengeVisible = true;
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    if (request.method === 'POST' && url.pathname === (state.formatCreateRequestPath ?? '/api/create-format')) {
      const body = JSON.parse(await readBody(request) || '{}');
      mutations.push({ method: 'POST', pathname: url.pathname, body });
      if (body.name === 'Unreal Engine' && !(state.productFormats ?? []).some((format) => format.name === 'Unreal Engine')) state.productFormats = [...(state.productFormats ?? []), { name: 'Unreal Engine' }];
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/submit') {
      mutations.push({ method: 'POST', pathname: url.pathname, body: {} });
      const accepted = !state.submitRequestFailure;
      if (accepted && !state.submitStaysDraft) state.status = 'Pending approval';
      response.writeHead(accepted ? 200 : 500, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    if (request.method === 'POST' && url.pathname === '/api/cancel') {
      mutations.push({ method: 'POST', pathname: url.pathname, body: {} });
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    if (request.method === 'POST' && url.pathname === '/graphql') {
      const bodyText = await readBody(request);
      let body = {};
      try { body = JSON.parse(bodyText || '{}'); } catch { /* the guard owns malformed request handling */ }
      if (/\bmutation\b/i.test(body.query ?? '')) mutations.push({ method: 'POST', pathname: url.pathname, body: { operationName: body.operationName ?? null } });
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{}');
      return;
    }
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{}');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const origin = `http://127.0.0.1:${address.port}`;
  return { state, requests, mutations, origin, close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())) };
}
