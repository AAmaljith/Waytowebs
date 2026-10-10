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

async function zohoRequest(path, { method = 'GET', body, operation = 'Inventory API' } = {}) {
  const token = await getToken();
  const sep = path.includes('?') ? '&' : '?';
  const headers = { Authorization: `Zoho-oauthtoken ${token}` };
  const options = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(body);
  }
  const r = await fetch(`${API}${path}${sep}organization_id=${process.env.ZOHO_ORG_ID}`, options);
  const responseBody = await readJson(r, operation);
  if (!r.ok || (responseBody.code !== undefined && Number(responseBody.code) !== 0)) {
    throw new Error(
      `Zoho ${operation} request failed (${r.status}): ${responseBody.message || 'Unknown Zoho error'}`
    );
  }
  return responseBody;
}

async function zoho(path) {
  return zohoRequest(path);
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
  const paymentTerms = Number(full.contact?.payment_terms);
  const creditLimit = Number(full.contact?.credit_limit);
  const outstandingReceivable = Number(full.contact?.outstanding_receivable_amount);
  return {
    allowed: true,
    contactId: match.contact_id,
    name: match.contact_name,
    paymentTerms: Number.isFinite(paymentTerms) ? paymentTerms : null,
    creditLimit: Number.isFinite(creditLimit) ? creditLimit : null,
    outstandingReceivable: Number.isFinite(outstandingReceivable)
      ? outstandingReceivable
      : null,
  };
}

async function findCustomerContact(mobile) {
  const contacts = await getAll('/contacts', 'contacts');
  const matches = contacts.filter(
    (contact) =>
      String(contact.contact_type || '').toLowerCase() === 'customer' &&
      (normalize(contact.mobile) === normalize(mobile) ||
        normalize(contact.phone) === normalize(mobile)),
  );
  if (matches.length > 1) {
    throw new Error('Multiple Zoho customer contacts match the verified phone number');
  }
  if (matches.length === 0) return null;
  return {
    contactId: matches[0].contact_id,
    name: matches[0].contact_name,
  };
}

async function createCustomerContact({ name, mobile }) {
  const normalizedName = String(name || '').trim();
  const normalizedMobile = normalize(mobile);
  if (!normalizedName || !/^\d{10}$/.test(normalizedMobile)) {
    throw new Error('A valid customer name and verified mobile number are required');
  }
  const response = await zohoRequest('/contacts', {
    method: 'POST',
    operation: 'customer contact creation',
    body: {
      contact_name: normalizedName,
      contact_type: 'customer',
      mobile: `+91${normalizedMobile}`,
      contact_persons: [
        {
          first_name: normalizedName,
          mobile: `+91${normalizedMobile}`,
          is_primary_contact: true,
        },
      ],
    },
  });
  const contact = response.contact;
  if (!contact || typeof contact.contact_id !== 'string' && typeof contact.contact_id !== 'number') {
    throw new Error('Zoho customer contact creation returned no contact ID');
  }
  return {
    contactId: String(contact.contact_id),
    name: contact.contact_name || normalizedName,
  };
}

let itemCache = { data: null, at: 0 };

async function getItems({ refresh = false } = {}) {
  if (!refresh && itemCache.data && Date.now() - itemCache.at < 5 * 60 * 1000) {
    return itemCache.data;
  }
  const sourceItems = await getAll('/items', 'items');
  const items = sourceItems.map((item) => ({
    id: item.item_id,
    name: item.name,
    sku: item.sku,
    category: item.category_name || 'General',
    price: item.rate,
    stock: item.available_stock ?? item.stock_on_hand ?? 0,
    taxId: item.tax_id || null,
    taxPercentage: item.tax_percentage == null ? null : Number(item.tax_percentage),
    description: item.description || '',
    brand: item.brand || '',
    manufacturer: item.manufacturer || '',
    unit: item.unit || '',
    weight: item.weight_with_unit || '',
    dimensions: item.dimensions_with_unit || '',
    imageAvailable: Boolean(item.image_name || item.image_document_id),
    canBeSold: item.can_be_sold !== false && item.status !== 'inactive',
  }));
  itemCache = { data: items, at: Date.now() };
  return items;
}

async function createSalesOrder(payload) {
  const response = await zohoRequest('/salesorders', {
    method: 'POST',
    body: payload,
    operation: 'sales order creation',
  });
  if (!response.salesorder || typeof response.salesorder !== 'object') {
    throw new Error('Zoho sales order creation returned no sales order');
  }
  return response.salesorder;
}

async function getSalesOrders(contactId) {
  if (!/^\d+$/.test(String(contactId))) throw new Error('Invalid Zoho contact ID');
  const orders = await getAll(
    `/salesorders?customer_id=${encodeURIComponent(contactId)}`,
    'salesorders',
  );
  return orders;
}

async function getSalesOrder(orderId) {
  if (!/^\d+$/.test(String(orderId))) throw new Error('Invalid Zoho sales order ID');
  const response = await zoho(`/salesorders/${orderId}`);
  if (!response.salesorder || typeof response.salesorder !== 'object') {
    throw new Error('Zoho sales order request returned no sales order');
  }
  return response.salesorder;
}

async function getItemImage(itemId) {
  if (!/^\d+$/.test(itemId)) throw new Error('Invalid Zoho item ID');

  const token = await getToken();
  const response = await fetch(
    `${API}/items/${itemId}/image?organization_id=${process.env.ZOHO_ORG_ID}`,
    { headers: { Authorization: `Zoho-oauthtoken ${token}` } },
  );
  if (!response.ok) {
    throw new Error(`Zoho item image request failed (${response.status})`);
  }

  const contentType = (response.headers.get('content-type') || '')
    .split(';', 1)[0]
    .trim()
    .toLowerCase();
  if (!/^image\/[a-z0-9.+-]+$/.test(contentType)) {
    throw new Error('Zoho item image endpoint returned a non-image response');
  }

  const image = Buffer.from(await response.arrayBuffer());
  if (image.length === 0) throw new Error('Zoho returned an empty item image');
  return { image, contentType };
}

module.exports = {
  normalize,
  checkDealer,
  findCustomerContact,
  createCustomerContact,
  getItems,
  getItemImage,
  createSalesOrder,
  getSalesOrders,
  getSalesOrder,
};
