const assert = require('assert');
const { findUncheckedItems } = require('./check-checklist');

const wrap = (inner) =>
  `intro text\n<!-- TEST-CHECKLIST-START -->\n${inner}\n<!-- TEST-CHECKLIST-END -->\nfooter\n- [ ] outside box must be ignored`;

// all checked (mixed-case x)
let r = findUncheckedItems(wrap('- [x] alpha\n- [X] bravo'));
assert.strictEqual(r.error, null, 'no error when all checked');
assert.strictEqual(r.total, 2, 'counts two items');
assert.strictEqual(r.unchecked.length, 0, 'none unchecked');

// one unchecked — and the outside box is not counted
r = findUncheckedItems(wrap('- [x] alpha\n- [ ] bravo'));
assert.deepStrictEqual(r.unchecked, ['bravo'], 'only the inside unticked item');
assert.strictEqual(r.total, 2, 'outside box excluded from total');

// missing delimiters
r = findUncheckedItems('no markers here at all');
assert.strictEqual(r.error, 'delimiters-missing', 'flags missing delimiters');

// delimiters present but no checkbox items
r = findUncheckedItems(wrap('just prose, no checkboxes'));
assert.strictEqual(r.error, 'no-items', 'flags empty checklist');

console.log('all checklist parser tests passed');
