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
  const listingControls = `
    ${challengeMarkup}
    <h1>${html(state.title)}</h1>
    ${statusMarkup}
    <label>Title *<input aria-label="Title *" value="${html(state.title)}" ${state.disableFields?.includes('title') ? 'disabled' : ''}></label>
    <label>Short description *<input aria-label="Short description *" value="${html(state.shortDescription)}" ${state.disableFields?.includes('shortDescription') ? 'disabled' : ''}></label>
    <label>Description *<div role="textbox" aria-label="Description *" contenteditable="true">${html(state.longDescription)}</div></label>
    <label>Product type *<select aria-label="Product type *"><option selected>${html(state.productType)}</option></select></label>
    <label>Category *<input role="combobox" aria-label="Category selection" value="${html(state.category)}"></label>
    <label>Tags *<input aria-label="Tags *" value="${html(state.tags[0] ?? '')}" readonly></label>
    <button type="button" data-testid="included-format">Unreal Engine</button>
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
    ${confirmationDialog}`;
  const formatControls = `
    <button type="button" aria-label="Back to listing">Back to listing</button>
    <h2>Unreal Engine</h2>
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
  return `<!doctype html><html><head><title>Fab fixture</title></head><body>
  <main id="listing-view">${listingControls}</main>
  <main id="format-view" hidden>${formatControls}</main>
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
    document.querySelector('[data-testid="included-format"]').addEventListener('click', () => setView('format'));
    document.querySelector('[aria-label="Back to listing"]').addEventListener('click', () => setView('listing'));
    document.querySelector('[data-testid="save"]').addEventListener('click', () => { syncFormatState(); fetch('/api/save', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload()) }); });
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
    if (request.method === 'POST' && url.pathname === '/api/save') {
      const body = JSON.parse(await readBody(request) || '{}');
      mutations.push({ method: 'POST', pathname: url.pathname, body });
      for (const [key, value] of Object.entries(body)) if (!dropSaveFields.includes(key)) state[key] = value;
      if (state.challengeAfterSave) state.challengeVisible = true;
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
