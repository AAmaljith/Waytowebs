require('dotenv').config();
const ACCOUNTS = 'https://accounts.zoho.in';
const API = 'https://www.zohoapis.in/inventory/v1';

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
  for (const c of list.contacts || []) {
    const full = await z(`/contacts/${c.contact_id}`, t);
    const cf = full.contact?.custom_fields || [];
    const flag = (label) => cf.find((x) => x.label === label)?.value;
    console.log(
      `${c.contact_name} | mobile: ${c.mobile} | phone: ${c.phone} | dealer: ${flag('Is Dealer')} | verified: ${flag('Verified')}`
    );
  }
})();
