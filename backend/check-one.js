require('dotenv').config();
const ACCOUNTS = 'https://accounts.zoho.in';
const API = 'https://www.zohoapis.in/inventory/v1';
const TARGET = process.argv[2] || '8281292173';

const normalize = (n) =>
  String(n || '').replace(/\D/g, '').replace(/^91(?=\d{10,})/, '').replace(/^0+/, '').slice(-10);

async function tok() {
  const r = await fetch(`${ACCOUNTS}/oauth/v2/token`, {
    method: 'POST',
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: process.env.ZOHO_CLIENT_ID,
      client_secret: process.env.ZOHO_CLIENT_SECRET,
      refresh_token: process.env.ZOHO_REFRESH_TOKEN,
    }),
  });
  return (await r.json()).access_token;
}

async function z(path, t) {
  const sep = path.includes('?') ? '&' : '?';
  const r = await fetch(`${API}${path}${sep}organization_id=${process.env.ZOHO_ORG_ID}`, {
    headers: { Authorization: `Zoho-oauthtoken ${t}` },
  });
  return r.json();
}

(async () => {
  const t = await tok();
  const list = await z('/contacts', t);
  const hits = (list.contacts || []).filter(
    (c) => normalize(c.mobile) === normalize(TARGET) || normalize(c.phone) === normalize(TARGET)
  );
  console.log(`Contacts matching ${TARGET}: ${hits.length}`);
  for (const c of hits) {
    const full = await z(`/contacts/${c.contact_id}`, t);
    const cf = full.contact?.custom_fields || [];
    const flag = (l) => cf.find((x) => x.label === l)?.value;
    console.log(
      `${c.contact_name} | mobile: ${c.mobile} | phone: ${c.phone} | Is Dealer: ${flag('Is Dealer')} | Verified: ${flag('Verified')}`
    );
  }
})();
