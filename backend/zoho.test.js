const assert = require('node:assert/strict');
const { after, test } = require('node:test');

process.env.ZOHO_CLIENT_ID = 'test-client';
process.env.ZOHO_CLIENT_SECRET = 'test-secret';
process.env.ZOHO_REFRESH_TOKEN = 'test-refresh-token';
process.env.ZOHO_ORG_ID = 'test-organization';

const originalFetch = global.fetch;
const {
  checkDealer,
  findCustomerContact,
  createCustomerContact,
  getItems,
  getItemImage,
  createSalesOrder,
  getSalesOrders,
  getSalesOrder,
} = require('./zoho');

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
          payment_terms: 90,
          credit_limit: 10000,
          outstanding_receivable_amount: 1000,
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
            description: 'Potable water pipe',
            brand: 'Waytowebs',
            manufacturer: 'Pipe Works',
            unit: 'piece',
            weight_with_unit: '1 kg',
            dimensions_with_unit: '1 m',
            image_name: 'pvc-pipe.jpg',
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
    paymentTerms: 90,
    creditLimit: 10000,
    outstandingReceivable: 1000,
  });
  assert.deepEqual(await getItems(), [
    {
      id: 'item-1',
      name: 'PVC Pipe',
      sku: 'PVC-01',
      category: 'Pipes',
      price: 250,
      stock: 12,
      taxId: null,
      taxPercentage: null,
      description: 'Potable water pipe',
      brand: 'Waytowebs',
      manufacturer: 'Pipe Works',
      unit: 'piece',
      weight: '1 kg',
      dimensions: '1 m',
      imageAvailable: true,
      canBeSold: true,
    },
    {
      id: 'item-2',
      name: 'Pipe Connector',
      sku: 'CON-01',
      category: 'General',
      price: 40,
      stock: 5,
      taxId: null,
      taxPercentage: null,
      description: '',
      brand: '',
      manufacturer: '',
      unit: '',
      weight: '',
      dimensions: '',
      imageAvailable: false,
      canBeSold: true,
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

test('loads authenticated Zoho product image bytes and rejects invalid image responses', async () => {
  let requestUrl;
  global.fetch = async (input, options = {}) => {
    requestUrl = new URL(input);
    assert.equal(options.headers.Authorization, 'Zoho-oauthtoken test-access-token');
    return {
      ok: true,
      status: 200,
      headers: new Headers({ 'content-type': 'image/jpeg; charset=binary' }),
      arrayBuffer: async () => Uint8Array.from([0xff, 0xd8, 0xff]).buffer,
    };
  };

  const result = await getItemImage('1234567890');
  assert.equal(requestUrl.pathname, '/inventory/v1/items/1234567890/image');
  assert.equal(requestUrl.searchParams.get('organization_id'), 'test-organization');
  assert.equal(result.contentType, 'image/jpeg');
  assert.deepEqual([...result.image], [0xff, 0xd8, 0xff]);

  global.fetch = async () => ({
    ok: true,
    status: 200,
    headers: new Headers({ 'content-type': 'application/json' }),
    arrayBuffer: async () => new ArrayBuffer(0),
  });
  await assert.rejects(
    getItemImage('1234567890'),
    /non-image response/,
  );

  await assert.rejects(getItemImage('invalid-id'), /Invalid Zoho item ID/);
});

test('creates and reads Zoho sales orders for the matching customer contact', async () => {
  const requests = [];
  global.fetch = async (input, options = {}) => {
    const url = new URL(input);
    requests.push({ url, options });
    if (url.hostname === 'accounts.zoho.in') {
      return jsonResponse({ access_token: 'test-access-token', expires_in: 3600 });
    }
    if (url.pathname.endsWith('/contacts')) {
      return jsonResponse({
        code: 0,
        contacts: [
          {
            contact_id: '12345',
            contact_name: 'App Customer',
            contact_type: 'customer',
            mobile: '+91 82812 92173',
          },
        ],
        page_context: { has_more_page: false },
      });
    }
    if (url.pathname.endsWith('/salesorders') && options.method === 'POST') {
      assert.deepEqual(JSON.parse(options.body), {
        customer_id: '12345',
        line_items: [{ item_id: '98765', rate: 250, quantity: 2 }],
      });
      return jsonResponse({
        code: 0,
        salesorder: {
          salesorder_id: '45678',
          salesorder_number: 'SO-45678',
          customer_id: '12345',
        },
      });
    }
    if (url.pathname.endsWith('/salesorders') && options.method === 'GET') {
      assert.equal(url.searchParams.get('customer_id'), '12345');
      return jsonResponse({
        code: 0,
        salesorders: [{ salesorder_id: '45678', customer_id: '12345' }],
        page_context: { has_more_page: false },
      });
    }
    if (url.pathname.endsWith('/salesorders/45678')) {
      return jsonResponse({
        code: 0,
        salesorder: { salesorder_id: '45678', customer_id: '12345' },
      });
    }
    throw new Error(`Unexpected test request: ${url.pathname}`);
  };

  assert.deepEqual(await findCustomerContact('8281292173'), {
    contactId: '12345',
    name: 'App Customer',
  });
  const order = await createSalesOrder({
    customer_id: '12345',
    line_items: [{ item_id: '98765', rate: 250, quantity: 2 }],
  });
  assert.equal(order.salesorder_id, '45678');
  assert.equal((await getSalesOrders('12345')).length, 1);
  assert.equal((await getSalesOrder('45678')).customer_id, '12345');
  assert.equal(requests.filter(({ options }) => options.method === 'POST').length, 1);
  await assert.rejects(getSalesOrders('invalid-id'), /Invalid Zoho contact ID/);
});

test('creates a Zoho customer contact from the verified app profile on first order', async () => {
  let requestBody;
  global.fetch = async (input, options = {}) => {
    const url = new URL(input);
    if (url.hostname === 'accounts.zoho.in') {
      return jsonResponse({ access_token: 'test-access-token', expires_in: 3600 });
    }
    assert.equal(url.pathname.endsWith('/contacts'), true);
    assert.equal(options.method, 'POST');
    requestBody = JSON.parse(options.body);
    return jsonResponse({
      code: 0,
      contact: { contact_id: '54321', contact_name: 'New Customer' },
    });
  };

  const contact = await createCustomerContact({
    name: 'New Customer',
    mobile: '8281292173',
  });
  assert.equal(contact.contactId, '54321');
  assert.deepEqual(requestBody, {
    contact_name: 'New Customer',
    contact_type: 'customer',
    mobile: '+918281292173',
    contact_persons: [
      {
        first_name: 'New Customer',
        mobile: '+918281292173',
        is_primary_contact: true,
      },
    ],
  });
});
