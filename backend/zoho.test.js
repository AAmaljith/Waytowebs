const assert = require('node:assert/strict');
const { after, test } = require('node:test');

process.env.ZOHO_CLIENT_ID = 'test-client';
process.env.ZOHO_CLIENT_SECRET = 'test-secret';
process.env.ZOHO_REFRESH_TOKEN = 'test-refresh-token';
process.env.ZOHO_ORG_ID = 'test-organization';

const originalFetch = global.fetch;
const { checkDealer, getItems } = require('./zoho');

after(() => {
  global.fetch = originalFetch;
});

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  };
}

test('reads paginated dealer and item data and propagates Zoho errors', async () => {
  const requests = [];
  let firstContactPageCalls = 0;
  global.fetch = async (input, options = {}) => {
    const url = new URL(input);
    requests.push({ url, options });

    if (url.hostname === 'accounts.zoho.in') {
      return jsonResponse({ access_token: 'test-access-token', expires_in: 3600 });
    }

    assert.equal(url.searchParams.get('organization_id'), 'test-organization');
    assert.equal(options.headers.Authorization, 'Zoho-oauthtoken test-access-token');

    if (url.pathname.endsWith('/contacts') && url.searchParams.get('page') === '1') {
      firstContactPageCalls += 1;
      if (firstContactPageCalls > 1) {
        return jsonResponse({ code: 57, message: 'Invalid OAuth token' });
      }
      return jsonResponse({
        code: 0,
        contacts: [],
        page_context: { has_more_page: true },
      });
    }
    if (url.pathname.endsWith('/contacts') && url.searchParams.get('page') === '2') {
      return jsonResponse({
        code: 0,
        contacts: [
          {
            contact_id: 'dealer-1',
            contact_name: 'Verified Dealer',
            mobile: '+91 82812 92173',
          },
        ],
        page_context: { has_more_page: false },
      });
    }
    if (url.pathname.endsWith('/contacts/dealer-1')) {
      return jsonResponse({
        code: 0,
        contact: {
          custom_fields: [
            { label: 'Is Dealer', value: true },
            { label: 'Verified', value: 'Yes' },
          ],
        },
      });
    }
    if (url.pathname.endsWith('/items') && url.searchParams.get('page') === '1') {
      return jsonResponse({
        code: 0,
        items: [
          {
            item_id: 'item-1',
            name: 'PVC Pipe',
            sku: 'PVC-01',
            category_name: 'Pipes',
            rate: 250,
            stock_on_hand: 12,
          },
        ],
        page_context: { has_more_page: true },
      });
    }
    if (url.pathname.endsWith('/items') && url.searchParams.get('page') === '2') {
      return jsonResponse({
        code: 0,
        items: [
          {
            item_id: 'item-2',
            name: 'Pipe Connector',
            sku: 'CON-01',
            rate: 40,
            available_stock: 5,
          },
        ],
        page_context: { has_more_page: false },
      });
    }

    throw new Error(`Unexpected test request: ${url.pathname}`);
  };

  assert.deepEqual(await checkDealer('8281292173'), {
    allowed: true,
    contactId: 'dealer-1',
    name: 'Verified Dealer',
  });
  assert.deepEqual(await getItems(), [
    {
      id: 'item-1',
      name: 'PVC Pipe',
      sku: 'PVC-01',
      category: 'Pipes',
      price: 250,
      stock: 12,
    },
    {
      id: 'item-2',
      name: 'Pipe Connector',
      sku: 'CON-01',
      category: 'General',
      price: 40,
      stock: 5,
    },
  ]);
  await assert.rejects(checkDealer('9000000000'), /Zoho Inventory API request failed/);

  assert.equal(
    requests.filter(({ url }) => url.pathname.endsWith('/contacts') && url.searchParams.get('page') === '2').length,
    1
  );
  assert.equal(
    requests.filter(({ url }) => url.pathname.endsWith('/items') && url.searchParams.get('page') === '2').length,
    1
  );
});
