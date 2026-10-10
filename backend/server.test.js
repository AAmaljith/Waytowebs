const assert = require('node:assert/strict');
const { createHmac } = require('node:crypto');
const { after, before, test } = require('node:test');
const jwt = require('jsonwebtoken');

process.env.JWT_SECRET ||= 'test-jwt-secret';
const app = require('./server');

let server;
let baseUrl;

class MemoryFirestore {
  constructor() {
    this.documents = new Map();
  }

  collection(name) {
    return {
      doc: (id) => {
        const key = `${name}/${id}`;
        const snapshot = () => ({
          exists: this.documents.has(key),
          data: () => this.documents.get(key),
        });
        return {
          get: async () => snapshot(),
          set: async (value) => this.documents.set(key, value),
          update: async (value) => {
            if (!this.documents.has(key)) throw new Error('Document does not exist');
            this.documents.set(key, { ...this.documents.get(key), ...value });
          },
          delete: async () => this.documents.delete(key),
          key,
        };
      },
    };
  }

  async runTransaction(callback) {
    return callback({
      get: (reference) => reference.get(),
      create: (reference, value) => {
        if (this.documents.has(reference.key)) {
          throw new Error('Document already exists');
        }
        this.documents.set(reference.key, value);
      },
    });
  }
}

before(async () => {
  server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const address = server.address();
  baseUrl = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  if (server) await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
});

test('Firebase session requires a supported role and Firebase ID token', async () => {
  const response = await fetch(`${baseUrl}/auth/firebase-session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ role: 'customer' }),
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: 'A Firebase ID token and valid role are required',
  });
});

test('Firebase session initializes Admin Auth before verifying an ID token', async () => {
  const previousProjectId = process.env.FIREBASE_PROJECT_ID;
  const previousServiceAccount = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  process.env.FIREBASE_PROJECT_ID = 'waytowebs-interview-app';
  delete process.env.FIREBASE_SERVICE_ACCOUNT_JSON;

  try {
    const response = await fetch(`${baseUrl}/auth/firebase-session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ role: 'customer', idToken: 'not-a-token' }),
    });

    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), {
      error: 'Firebase login has expired. Please verify your phone again.',
    });
  } finally {
    if (previousProjectId === undefined) {
      delete process.env.FIREBASE_PROJECT_ID;
    } else {
      process.env.FIREBASE_PROJECT_ID = previousProjectId;
    }
    if (previousServiceAccount === undefined) {
      delete process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
    } else {
      process.env.FIREBASE_SERVICE_ACCOUNT_JSON = previousServiceAccount;
    }
  }
});

test('eligibility precheck rejects customer role without claiming approval', async () => {
  const response = await fetch(`${baseUrl}/auth/check-eligibility`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ role: 'customer', mobile: '8281292173' }),
  });

  test('product image route requires authentication and a numeric Zoho product ID', async () => {
    const unauthenticated = await fetch(`${baseUrl}/products/123/image`);
    assert.equal(unauthenticated.status, 401);

    const token = jwt.sign(
      { mobile: '8281292173', role: 'customer' },
      process.env.JWT_SECRET,
    );
    const invalidId = await fetch(`${baseUrl}/products/not-a-number/image`, {
      headers: { authorization: `Bearer ${token}` },
    });

    assert.equal(invalidId.status, 400);
    assert.deepEqual(await invalidId.json(), {
      error: 'A valid product ID is required',
    });
  });

  test('cart and order APIs validate authorization and requests before storage access', async () => {
    const token = jwt.sign(
      { uid: 'customer-1', mobile: '8281292173', role: 'customer' },
      process.env.JWT_SECRET,
    );
    const invalidCart = await fetch(`${baseUrl}/cart`, {
      method: 'PUT',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ items: [{ productId: 'not-a-zoho-id', quantity: 1 }] }),
    });
    assert.equal(invalidCart.status, 400);

    const missingIdempotencyKey = await fetch(`${baseUrl}/orders`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ paymentMethod: 'direct' }),
    });
    assert.equal(missingIdempotencyKey.status, 400);

    const plumberToken = jwt.sign(
      { uid: 'plumber-1', mobile: '9000000001', role: 'plumber' },
      process.env.JWT_SECRET,
    );
    const plumberCart = await fetch(`${baseUrl}/cart`, {
      headers: { authorization: `Bearer ${plumberToken}` },
    });
    assert.equal(plumberCart.status, 403);
  });

  test('an empty cart does not require a Zoho catalog request', async () => {
    const database = new MemoryFirestore();
    app.setFirestoreForTests(database);
    const token = jwt.sign(
      { uid: 'customer-empty-cart', mobile: '8281292173', role: 'customer' },
      process.env.JWT_SECRET,
    );

    try {
      const response = await fetch(`${baseUrl}/cart`, {
        headers: { authorization: ['Bearer', token].join(' ') },
      });

      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), { items: [], subtotal: 0 });
    } finally {
      app.setFirestoreForTests(null);
    }
  });

  test('cart validates Zoho stock, blocks unpaid orders, and reads tracking', async () => {
    const database = new MemoryFirestore();
    app.setFirestoreForTests(database);
    const originalFetch = global.fetch;
    let salesOrderCreates = 0;
    global.fetch = async (input, options = {}) => {
      const url = new URL(input);
      if (url.hostname === '127.0.0.1') return originalFetch(input, options);
      if (url.hostname === 'accounts.zoho.in') {
        return {
          ok: true,
          status: 200,
          json: async () => ({ access_token: 'test-access-token', expires_in: 3600 }),
        };
      }
      if (url.pathname.endsWith('/items')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            code: 0,
            items: [
              {
                item_id: '123',
                name: 'Pipe',
                sku: 'PIPE-01',
                category_name: 'Pipes',
                rate: 250,
                available_stock: 10,
                can_be_sold: true,
                tax_id: 'tax-123',
              },
            ],
            page_context: { has_more_page: false },
          }),
        };
      }
      if (url.pathname.endsWith('/contacts')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            code: 0,
            contacts: [
              {
                contact_id: '555',
                contact_name: 'App Customer',
                contact_type: 'customer',
                mobile: '+91 82812 92173',
              },
            ],
            page_context: { has_more_page: false },
          }),
        };
      }
      if (url.pathname.endsWith('/salesorders') && options.method === 'POST') {
        salesOrderCreates += 1;
        const payload = JSON.parse(options.body);
        assert.equal(payload.customer_id, '555');
        assert.equal(payload.line_items[0].item_id, '123');
        assert.equal(payload.line_items[0].rate, 250);
        assert.equal(payload.line_items[0].quantity, 2);
        assert.equal(payload.line_items[0].tax_id, 'tax-123');
        return {
          ok: true,
          status: 201,
          json: async () => ({
            code: 0,
            salesorder: {
              salesorder_id: '789',
              salesorder_number: 'SO-789',
              customer_id: '555',
              status: 'open',
              total: 500,
            },
          }),
        };
      }
      if (url.pathname.endsWith('/salesorders')) {
        return {
          ok: true,
          status: 200,
          json: async () => ({
            code: 0,
            salesorders: [
              {
                salesorder_id: '789',
                salesorder_number: 'SO-789',
                customer_id: '555',
                status: 'open',
                total: 500,
                packages: [{ tracking_number: 'TRACK-789' }],
              },
            ],
            page_context: { has_more_page: false },
          }),
        };
      }
      throw new Error(`Unexpected test request: ${url.pathname}`);
    };

    const token = jwt.sign(
      { uid: 'customer-1', mobile: '8281292173', role: 'customer' },
      process.env.JWT_SECRET,
    );
    const headers = {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
    };

    try {
      const update = await fetch(`${baseUrl}/cart`, {
        method: 'PUT',
        headers,
        body: JSON.stringify({
          items: [{ productId: '123', quantity: 2 }],
        }),
      });
      assert.equal(update.status, 200);

      const cart = await fetch(`${baseUrl}/cart`, { headers });
      assert.equal((await cart.json()).subtotal, 500);

      const unpaidOrder = await fetch(`${baseUrl}/orders`, {
          method: 'POST',
          headers: { ...headers, 'Idempotency-Key': 'unpaid-order-789' },
          body: JSON.stringify({ paymentMethod: 'direct' }),
        });
      assert.equal(unpaidOrder.status, 400);
      assert.equal(salesOrderCreates, 0);

      const orders = await fetch(`${baseUrl}/orders`, { headers });
      const orderList = await orders.json();
      assert.equal(orderList.orders[0].number, 'SO-789');
      assert.equal(orderList.orders[0].packages[0].tracking_number, 'TRACK-789');
      const clearedCart = await fetch(`${baseUrl}/cart`, { headers });
      assert.equal((await clearedCart.json()).items.length, 1);
    } finally {
      app.setFirestoreForTests(null);
      global.fetch = originalFetch;
    }
  });

test('Razorpay checkout verifies captured payment before confirming the Zoho order', async () => {
  const database = new MemoryFirestore();
  app.setFirestoreForTests(database);
  const originalFetch = global.fetch;
  const originalKeyId = process.env.RAZORPAY_KEY_ID;
  const originalKeySecret = process.env.RAZORPAY_KEY_SECRET;
  process.env.RAZORPAY_KEY_ID = 'rzp_test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test-secret';
  let salesOrderCreates = 0;

  global.fetch = async (input, options = {}) => {
    const url = new URL(input);
    if (url.hostname === '127.0.0.1') return originalFetch(input, options);
    if (url.hostname === 'accounts.zoho.in') {
      return Response.json({ access_token: 'test-access-token', expires_in: 3600 });
    }
    if (url.hostname === 'api.razorpay.com' && url.pathname === '/v1/orders') {
      const request = JSON.parse(options.body);
      assert.equal(request.amount, 50000);
      assert.equal(request.currency, 'INR');
      return Response.json({
        id: 'order_test123',
        amount: request.amount,
        currency: request.currency,
      });
    }
    if (
      url.hostname === 'api.razorpay.com' &&
      url.pathname === '/v1/payments/pay_test123'
    ) {
      return Response.json({
        id: 'pay_test123',
        order_id: 'order_test123',
        amount: 50000,
        currency: 'INR',
        status: 'captured',
      });
    }
    if (url.pathname.endsWith('/items')) {
      return Response.json({
        code: 0,
        items: [
          {
            item_id: '123',
            name: 'Pipe',
            sku: 'PIPE-01',
            category_name: 'Pipes',
            rate: 250,
            available_stock: 10,
            can_be_sold: true,
          },
        ],
        page_context: { has_more_page: false },
      });
    }
    if (url.pathname.endsWith('/contacts')) {
      return Response.json({
        code: 0,
        contacts: [
          {
            contact_id: '555',
            contact_name: 'App Customer',
            contact_type: 'customer',
            mobile: '+91 82812 92173',
          },
        ],
        page_context: { has_more_page: false },
      });
    }
    if (url.pathname.endsWith('/salesorders') && options.method === 'POST') {
      salesOrderCreates += 1;
      const payload = JSON.parse(options.body);
      assert.equal(payload.reference_number.startsWith('WTW-'), true);
      assert.equal(payload.line_items[0].item_id, '123');
      return Response.json({
        code: 0,
        salesorder: {
          salesorder_id: '789',
          salesorder_number: 'SO-789',
          customer_id: '555',
          status: 'open',
          total: 500,
        },
      });
    }
    throw new Error(`Unexpected test request: ${url.hostname}${url.pathname}`);
  };

  const token = jwt.sign(
    { uid: 'customer-payment-1', mobile: '8281292173', role: 'customer' },
    process.env.JWT_SECRET,
  );
  const headers = {
    authorization: `Bearer ${token}`,
    'content-type': 'application/json',
    'Idempotency-Key': 'razorpay-checkout-123',
  };

  try {
    const cartUpdate = await fetch(`${baseUrl}/cart`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ items: [{ productId: '123', quantity: 2 }] }),
    });
    assert.equal(cartUpdate.status, 200);

    const checkoutResponse = await fetch(`${baseUrl}/payments/razorpay/orders`, {
      method: 'POST',
      headers,
    });
    assert.equal(checkoutResponse.status, 201);
    const checkout = await checkoutResponse.json();
    assert.deepEqual(checkout.checkout, {
      key_id: 'rzp_test_key',
      order_id: 'order_test123',
      amount: 50000,
      currency: 'INR',
    });
    assert.equal(salesOrderCreates, 1);

    const signature = createHmac('sha256', 'test-secret')
      .update('order_test123|pay_test123')
      .digest('hex');
    const verified = await fetch(`${baseUrl}/payments/razorpay/verify`, {
      method: 'POST',
      headers: { authorization: headers.authorization, 'content-type': 'application/json' },
      body: JSON.stringify({
        orderId: 'order_test123',
        paymentId: 'pay_test123',
        signature,
      }),
    });
    assert.equal(verified.status, 200);
    const result = await verified.json();
    assert.equal(result.order.number, 'SO-789');
    assert.equal(result.order.payment_status, 'paid');
    assert.equal(result.payment.status, 'captured');

    const clearedCart = await fetch(`${baseUrl}/cart`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.deepEqual((await clearedCart.json()).items, []);
    const payment = await database
      .collection('order_payments')
      .doc('789')
      .get();
    assert.equal(payment.data().payment_status, 'paid');
  } finally {
    app.setFirestoreForTests(null);
    global.fetch = originalFetch;
    if (originalKeyId === undefined) delete process.env.RAZORPAY_KEY_ID;
    else process.env.RAZORPAY_KEY_ID = originalKeyId;
    if (originalKeySecret === undefined) delete process.env.RAZORPAY_KEY_SECRET;
    else process.env.RAZORPAY_KEY_SECRET = originalKeySecret;
  }
});

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: 'A valid mobile number and role are required',
  });
});
