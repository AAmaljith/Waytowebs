require('dotenv').config();

// India data center. If your Zoho address ends in .com, change .in to .com in both lines.
const ACCOUNTS = 'https://accounts.zoho.in';
const API = 'https://www.zohoapis.in/inventory/v1';

async function getToken() {
  const r = await fetch(`${ACCOUNTS}/oauth/v2/token`, {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: process.env.ZOHO_CLIENT_ID,
      client_secret: process.env.ZOHO_CLIENT_SECRET,
      refresh_token: process.env.ZOHO_REFRESH_TOKEN,
    }),
  });
  const d = await r.json();
  if (!d.access_token) throw new Error('Token error: ' + JSON.stringify(d));
  return d.access_token;
}

async function zoho(path, token) {
  const sep = path.includes('?') ? '&' : '?';
  const url = `${API}${path}${sep}organization_id=${process.env.ZOHO_ORG_ID}`;
  const r = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` },
  });
  return r.json();
}

// Makes +91-08281292173, 08281292173 and 8281292173 all become 8281292173
const normalize = (n) =>
  String(n || '')
    .replace(/\D/g, '')
    .replace(/^91(?=\d{10,})/, '')
    .replace(/^0+/, '')
    .slice(-10);

async function checkDealer(mobile, token) {
  const list = await zoho('/contacts', token);
  const matches = (list.contacts || []).filter(
    (c) =>
      normalize(c.mobile) === normalize(mobile) ||
      normalize(c.phone) === normalize(mobile)
  );
  if (matches.length === 0) return { allowed: false, reason: 'Not registered' };
  if (matches.length > 1)
    return { allowed: false, reason: 'Duplicate number in Zoho: ask admin to fix' };
  const match = matches[0];

  const full = await zoho(`/contacts/${match.contact_id}`, token);
  const fields = full.contact?.custom_fields || [];
  const isTrue = (label) => {
    const f = fields.find((x) => x.label === label);
    return !!f && (f.value === true || f.value === 'true' || f.value === 'Yes');
  };

  if (!isTrue('Is Dealer'))
    return { allowed: false, reason: 'Not a dealer', name: match.contact_name };
  if (!isTrue('Verified'))
    return { allowed: false, reason: 'Not verified', name: match.contact_name };
  return { allowed: true, contactId: match.contact_id, name: match.contact_name };
}

(async () => {
  try {
    const token = await getToken();
    console.log('Token OK\n');

    const items = await zoho('/items', token);
    console.log('ITEMS');
    if (!items.items) console.log('No items returned:', items);
    (items.items || []).forEach((i) =>
      console.log(` - ${i.name} | ${i.sku} | Rs.${i.rate} | stock: ${i.stock_on_hand}`)
    );

    // Change these numbers to match YOUR contacts
    console.log('\nVerified dealer   :', await checkDealer('8281292173', token));
    console.log('Unverified dealer :', await checkDealer('9895673607', token));
    console.log('Unknown number    :', await checkDealer('9999999999', token));
  } catch (e) {
    console.error('FAILED:', e.message);
  }
})();