import assert from 'node:assert/strict';
import test from 'node:test';
import { compareRichText, richTextToPlainText, validateRichText } from '../src/rich-text.mjs';

const formatted = {
  blocks: [
    { type: 'heading', level: 2, runs: [{ text: 'Included Profiles' }] },
    { type: 'paragraph', runs: [{ text: 'Use ' }, { text: 'Solo', marks: ['bold'] }, { text: ' for a local run.' }] },
    { type: 'unordered_list', items: [[{ text: 'Listen Server', marks: ['italic'] }], [{ text: 'Bad Network', marks: ['underline'] }]] },
    { type: 'ordered_list', items: [[{ text: 'Open the editor.' }], [{ text: 'Run the profile.' }]] },
    { type: 'paragraph', runs: [{ text: 'Docs', marks: ['link'], href: 'https://example.com/docs' }] },
  ],
};

test('rich text model supports the approved blocks and inline marks', () => {
  assert.doesNotThrow(() => validateRichText(formatted));
  assert.equal(richTextToPlainText(formatted), 'Included Profiles\n\nUse Solo for a local run.\n\n- Listen Server\n- Bad Network\n\n1. Open the editor.\n2. Run the profile.\n\nDocs');
  assert.equal(compareRichText(structuredClone(formatted), formatted), 'MATCH');
});

test('rich text comparison rejects flattened or semantically different content', () => {
  assert.equal(compareRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'Included Profiles' }] }] }, formatted), 'MISMATCH');
  assert.equal(compareRichText({ blocks: [{ type: 'paragraph', runs: [{ text: '- Listen Server' }] }] }, { blocks: [{ type: 'unordered_list', items: [[{ text: 'Listen Server' }]] }] }), 'MISMATCH');
  assert.equal(compareRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'Solo' }] }] }, { blocks: [{ type: 'paragraph', runs: [{ text: 'Solo', marks: ['bold'] }] }] }), 'MISMATCH');
  assert.equal(compareRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'Docs', marks: ['link'], href: 'https://example.com/wrong' }] }] }, { blocks: [{ type: 'paragraph', runs: [{ text: 'Docs', marks: ['link'], href: 'https://example.com/docs' }] }] }), 'MISMATCH');
});

test('rich text validation rejects unsupported color and malformed link contracts', () => {
  assert.throws(() => validateRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'red', marks: ['color'] }] }] }), /supported marks/);
  assert.throws(() => validateRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'Docs', marks: ['link'] }] }] }), /require href/);
  assert.throws(() => validateRichText({ blocks: [{ type: 'paragraph', runs: [{ text: 'Docs', href: 'https://example.com/docs' }] }] }), /only allowed on link/);
});
