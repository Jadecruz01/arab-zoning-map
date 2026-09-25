/**
 * City of Arab — Zoning & Property Map feed
 * Google Apps Script web app that lets the map (and the permit site) read and
 * write the "Properties" tab of this Google Sheet.
 *
 * Setup
 *  1. Create a Google Sheet. Rename the first tab to: Properties
 *  2. Extensions → Apps Script. Replace everything with this file. Save.
 *  3. Change KEY below to a long random phrase.
 *  4. Run `setup` once from the editor (creates the header row) and approve access.
 *     Run it again after updating this script: it rewrites row 1 and the status dropdown.
 *     (If you already have data, add any new columns at the end of row 1 by hand instead.)
 *  5. Deploy → New deployment → type "Web app"
 *       Execute as: Me   ·   Who has access: Anyone
 *     Copy the URL that ends in /exec.
 *  6. Paste the /exec URL and KEY into the map's Staff dashboard → Google Sheet feed
 *     (or into CONFIG.SHEET_API / CONFIG.SHEET_KEY at the top of index.html).
 *  After editing this script later: Deploy → Manage deployments → Edit → New version.
 *
 * Reading (GET  …/exec?action=list)            → public rows only (public != "N"), owner column removed
 * Reading (GET  …/exec?action=list&key=KEY)    → every row, every column (staff)
 * Writing (POST …/exec, body = JSON as text/plain)
 *   {"key":"KEY","action":"upsert","row":{"id":"ANX-2026-018","status":"approved", ...}}
 *   {"key":"KEY","action":"delete","id":"ANX-2026-018"}
 * An upsert only changes the columns you send. Annexation timeline:
 *   submitted → review → pc_scheduled (PC hearing) → approved (PC recommends to Council, vote in pc_vote)
 *   → council (on the City Council agenda, council_date) → annexed (Council approved, council_vote + ordinance_no)
 *   denied / withdrawn can happen at any point.
 * So when the Planning Commission votes the permit site sends {id, status:"approved", pc_date, pc_vote},
 * and when the Council approves it sends {id, status:"annexed", council_vote, decision_date, ordinance_no}.
 */

const KEY = 'CHANGE-ME-to-a-long-random-phrase';
const SHEET_NAME = 'Properties';
const COLUMNS = ['id','kind','name','address','ppin','parcel_number','owner','acreage','current_zone','requested_zone',
  'status','application_no','submitted_date','pc_date','pc_vote','council_date','council_vote','decision_date','ordinance_no','notes','public',
  'lat','lng','geometry','source','updated_at','updated_by'];
const STATUSES = ['submitted','review','pc_scheduled','approved','council','annexed','denied','withdrawn'];
const STAFF_ONLY = ['owner','updated_by'];

function setup() {
  const sh = sheet_();
  sh.getRange(1, 1, 1, COLUMNS.length).setValues([COLUMNS]).setFontWeight('bold');
  sh.setFrozenRows(1);
  const statusCol = COLUMNS.indexOf('status') + 1;
  sh.getRange(2, statusCol, sh.getMaxRows() - 1, 1).setDataValidation(
    SpreadsheetApp.newDataValidation().requireValueInList(STATUSES, true).setAllowInvalid(false).build());
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  const staff = p.key === KEY;
  let rows = readRows_();
  if (!staff) {
    rows = rows.filter(r => String(r.public || 'Y').toUpperCase() !== 'N')
               .map(r => { STAFF_ONLY.forEach(c => delete r[c]); return r; });
  }
  return json_({ ok: true, rows: rows, updated: new Date().toISOString() });
}

function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return json_({ ok: false, error: 'Body must be JSON' }); }
  if (body.key !== KEY) return json_({ ok: false, error: 'Wrong key' });
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    if (body.action === 'upsert') return json_(upsert_(body.row || {}));
    if (body.action === 'delete') return json_(remove_(String(body.id || '')));
    return json_({ ok: false, error: 'Unknown action' });
  } finally {
    lock.releaseLock();
  }
}

function upsert_(row) {
  if (!row.id) row.id = 'p' + Date.now().toString(36);
  if (row.status && STATUSES.indexOf(row.status) < 0) return { ok: false, error: 'Unknown status: ' + row.status };
  row.updated_at = new Date().toISOString();
  const sh = sheet_();
  const head = header_(sh);
  const ids = idColumn_(sh);
  const idx = ids.indexOf(String(row.id));
  if (idx >= 0) {
    const r = idx + 2;
    const current = sh.getRange(r, 1, 1, head.length).getValues()[0];
    head.forEach((h, i) => { if (Object.prototype.hasOwnProperty.call(row, h)) current[i] = clean_(row[h]); });
    sh.getRange(r, 1, 1, head.length).setValues([current]);
    return { ok: true, id: row.id, updated: true };
  }
  if (!row.status) row.status = 'submitted';
  if (!row.public) row.public = 'Y';
  sh.appendRow(head.map(h => clean_(row[h])));
  return { ok: true, id: row.id, created: true };
}

function remove_(id) {
  const sh = sheet_();
  const idx = idColumn_(sh).indexOf(id);
  if (idx < 0) return { ok: false, error: 'Not found' };
  sh.deleteRow(idx + 2);
  return { ok: true, id: id, deleted: true };
}

function readRows_() {
  const sh = sheet_();
  const values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  const head = values[0].map(String);
  return values.slice(1).filter(r => r.some(v => v !== '')).map(r => {
    const o = {};
    head.forEach((h, i) => {
      let v = r[i];
      if (v instanceof Date) v = Utilities.formatDate(v, Session.getScriptTimeZone(), h === 'updated_at' ? "yyyy-MM-dd'T'HH:mm:ss" : 'yyyy-MM-dd');
      o[h] = v === null || v === undefined ? '' : String(v);
    });
    return o;
  });
}

function sheet_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  return ss.getSheetByName(SHEET_NAME) || ss.insertSheet(SHEET_NAME);
}
function header_(sh) {
  const last = Math.max(sh.getLastColumn(), 1);
  const head = sh.getRange(1, 1, 1, last).getValues()[0].map(String).filter(Boolean);
  return head.length ? head : COLUMNS;
}
function idColumn_(sh) {
  const n = sh.getLastRow() - 1;
  if (n < 1) return [];
  const col = header_(sh).indexOf('id') + 1;
  return sh.getRange(2, col, n, 1).getValues().map(r => String(r[0]));
}
function clean_(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return JSON.stringify(v);
  const s = String(v);
  return /^[=+\-@]/.test(s) && !/^-?\d/.test(s) ? "'" + s : s; // stop formula injection, keep negative numbers
}
function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
