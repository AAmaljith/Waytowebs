require('dotenv').config();

const ACCOUNTS = 'https://accounts.zoho.in';
const API = 'https://www.zohoapis.in/inventory/v1';

let cached = { token: null, exp: 0 };

async function getToken() {
  if (cached.token && Date.now() < cached.exp) return cached.token;
  const required = [
    'ZOHO_CLIENT_ID',
    'ZOHO_CLIENT_SECRET',
    'ZOHO_REFRESH_TOKEN',
    'ZOHO_ORG_ID',
  ];
  const missing = required.filter((name) => !process.env[name]);
  if (missing.length) throw new Error(`Missing Zoho configuration: ${missing.join(', ')}`);

  const r = await fetch(`${ACCOUNTS}/oauth/v2/token`, {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: process.env.ZOHO_CLIENT_ID,
      client_secret: process.env.ZOHO_CLIENT_SECRET,
      refresh_token: process.env.ZOHO_REFRESH_TOKEN,
    }),
  });
  const d = await readJson(r, 'OAuth token');
  if (!r.ok || typeof d.access_token !== 'string' || !d.access_token) {
    throw new Error(
      `Zoho OAuth token request failed (${r.status}): ${d.error || 'No access token returned'}`
    );
  }
  const expiresIn = Number(d.expires_in);
  cached = {
    token: d.access_token,
    exp: Date.now() + Math.max(0, (Number.isFinite(expiresIn) ? expiresIn : 0) - 120) * 1000,
  };
  return cached.token;
}

async function readJson(response, operation) {
  let body;
  try {
    body = await response.json();
  } catch {
    throw new Error(
      `Zoho ${operation} returned an invalid JSON response (${response.status})`
    );
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    throw new Error(`Zoho ${operation} returned an invalid response (${response.status})`);
  }
  return body;
}

async function zoho(path) {
  const token = await getToken();
  const sep = path.includes('?') ? '&' : '?';
  const r = await fetch(`${API}${path}${sep}organization_id=${process.env.ZOHO_ORG_ID}`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` },
  });
  const body = await readJson(r, 'Inventory API');
  if (!r.ok || (body.code !== undefined && Number(body.code) !== 0)) {
    throw new Error(
      `Zoho Inventory API request failed (${r.status}): ${body.message || 'Unknown Zoho error'}`
    );
  }
  return body;
}

async function getAll(path, collection) {
  const results = [];
  let page = 1;
  let hasMore = true;
  while (hasMore) {
    const separator = path.includes('?') ? '&' : '?';
    const response = await zoho(`${path}${separator}page=${page}&per_page=200`);
    results.push(...(Array.isArray(response[collection]) ? response[collection] : []));
    hasMore = response.page_context?.has_more_page === true;
    page += 1;
  }
  return results;
}

const normalize = (n) =>
  String(n || '')
    .replace(/\D/g, '')
    .replace(/^91(?=\d{10,})/, '')
    .replace(/^0+/, '')
    .slice(-10);

async function checkDealer(mobile) {
  const contacts = await getAll('/contacts', 'contacts');
  const matches = contacts.filter(
    (c) => normalize(c.mobile) === normalize(mobile) || normalize(c.phone) === normalize(mobile)
  );
  if (matches.length === 0) return { allowed: false, reason: 'Not registered. Contact admin.' };
  if (matches.length > 1) return { allowed: false, reason: 'Duplicate number in Zoho. Contact admin.' };

  const match = matches[0];
  const full = await zoho(`/contacts/${match.contact_id}`);
  const fields = full.contact?.custom_fields || [];
  const isTrue = (label) => {
    const field = fields.find((item) => item.label === label);
    return !!field && (field.value === true || field.value === 'true' || field.value === 'Yes');
  };
  if (!isTrue('Is Dealer')) return { allowed: false, reason: 'Not a dealer account.' };
  if (!isTrue('Verified')) return { allowed: false, reason: 'Dealer not verified yet.' };
  return { allowed: true, contactId: match.contact_id, name: match.contact_name };
}

let itemCache = { data: null, at: 0 };

async function getItems() {
  if (itemCache.data && Date.now() - itemCache.at < 5 * 60 * 1000) return itemCache.data;
  const sourceItems = await getAll('/items', 'items');
  const items = sourceItems.map((item) => ({
    id: item.item_id,
    name: item.name,
    sku: item.sku,
    category: item.category_name || 'General',
    price: item.rate,
    stock: item.stock_on_hand ?? item.available_stock ?? 0,
  }));
  itemCache = { data: items, at: Date.now() };
  return items;
}

module.exports = { normalize, checkDealer, getItems };
