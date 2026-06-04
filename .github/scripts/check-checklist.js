#!/usr/bin/env node
// Fails (exit 1) if any checkbox between the TEST-CHECKLIST delimiters is
// unticked. Only boxes inside the delimiters count — boxes anywhere else in
// the PR body are ignored, so optional/cosmetic checkboxes never block merge.
'use strict';

const START = '<!-- TEST-CHECKLIST-START -->';
const END = '<!-- TEST-CHECKLIST-END -->';

function extractSection(body) {
  const s = body.indexOf(START);
  const e = body.indexOf(END);
  if (s === -1 || e === -1 || e < s) return null;
  return body.slice(s + START.length, e);
}

function findUncheckedItems(body) {
  const section = extractSection(body || '');
  if (section === null) return { error: 'delimiters-missing', unchecked: [], total: 0 };
  const unchecked = [];
  let total = 0;
  for (const line of section.split(/\r?\n/)) {
    const m = line.match(/^\s*-\s*\[( |x|X)\]\s*(.*)$/);
    if (!m) continue;
    total += 1;
    if (m[1] === ' ') unchecked.push(m[2].trim());
  }
  return { error: total === 0 ? 'no-items' : null, unchecked, total };
}

module.exports = { extractSection, findUncheckedItems, START, END };

if (require.main === module) {
  const res = findUncheckedItems(process.env.PR_BODY || '');
  if (res.error === 'delimiters-missing') {
    console.error('❌ Test-checklist delimiters not found in the PR body. Use the PR template.');
    process.exit(1);
  }
  if (res.error === 'no-items') {
    console.error('❌ No checklist items found between the delimiters.');
    process.exit(1);
  }
  if (res.unchecked.length > 0) {
    console.error(`❌ ${res.unchecked.length}/${res.total} manual-test items still unchecked:`);
    for (const u of res.unchecked) console.error(`   - [ ] ${u}`);
    process.exit(1);
  }
  console.log(`✅ All ${res.total} manual-test checklist items are checked.`);
}
