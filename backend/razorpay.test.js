const assert = require('node:assert/strict');
const { createHmac } = require('node:crypto');
const { afterEach, test } = require('node:test');
const razorpay = require('./razorpay');

const originalFetch = global.fetch;
const originalKeyId = process.env.RAZORPAY_KEY_ID;
const originalKeySecret = process.env.RAZORPAY_KEY_SECRET;
const originalWebhookSecret = process.env.RAZORPAY_WEBHOOK_SECRET;

afterEach(() => {
  global.fetch = originalFetch;
  for (const [key, original] of [
    ['RAZORPAY_KEY_ID', originalKeyId],
    ['RAZORPAY_KEY_SECRET', originalKeySecret],
    ['RAZORPAY_WEBHOOK_SECRET', originalWebhookSecret],
  ]) {
    if (original === undefined) delete process.env[key];
    else process.env[key] = original;
  }
});

test('creates a Razorpay order on the server using the configured credentials', async () => {
  process.env.RAZORPAY_KEY_ID = 'rzp_test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test-secret';
  let request;
  global.fetch = async (url, options) => {
    request = { url, options };
    return Response.json({
      id: 'order_test_123',
      amount: 25000,
      currency: 'INR',
    });
  };

  const order = await razorpay.createOrder({
    amount: 25000,
    currency: 'INR',
    receipt: 'WTW-test-reference',
    notes: { salesorder_id: '12345' },
  });

  assert.equal(order.id, 'order_test_123');
  assert.equal(request.url, 'https://api.razorpay.com/v1/orders');
  assert.equal(
    request.options.headers.Authorization,
    `Basic ${Buffer.from('rzp_test_key:test-secret').toString('base64')}`,
  );
  assert.deepEqual(JSON.parse(request.options.body), {
    amount: 25000,
    currency: 'INR',
    receipt: 'WTW-test-reference',
    notes: { salesorder_id: '12345' },
  });
});

test('verifies checkout and webhook signatures using timing-safe HMAC validation', () => {
  process.env.RAZORPAY_KEY_ID = 'rzp_test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test-secret';
  process.env.RAZORPAY_WEBHOOK_SECRET = 'webhook-secret';
  const checkoutSignature = createHmac('sha256', 'test-secret')
    .update('order_test_123|pay_test_123')
    .digest('hex');
  const webhookBody = Buffer.from('{"event":"payment.captured"}');
  const webhookSignature = createHmac('sha256', 'webhook-secret')
    .update(webhookBody)
    .digest('hex');

  assert.equal(
    razorpay.verifyPaymentSignature(
      'order_test_123',
      'pay_test_123',
      checkoutSignature,
    ),
    true,
  );
  assert.equal(
    razorpay.verifyPaymentSignature(
      'order_test_123',
      'pay_test_123',
      '0'.repeat(64),
    ),
    false,
  );
  assert.equal(
    razorpay.verifyWebhookSignature(webhookBody, webhookSignature),
    true,
  );
  assert.equal(
    razorpay.verifyWebhookSignature(webhookBody, 'not-a-signature'),
    false,
  );
});

test('rejects payment orders when server credentials are not configured', () => {
  delete process.env.RAZORPAY_KEY_ID;
  delete process.env.RAZORPAY_KEY_SECRET;
  assert.throws(razorpay.getKeyId, /Razorpay test or live API keys are not configured/);
});
