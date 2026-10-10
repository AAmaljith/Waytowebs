const { createHmac, timingSafeEqual } = require('node:crypto');

const API = 'https://api.razorpay.com/v1';

function getConfiguration() {
  const keyId = process.env.RAZORPAY_KEY_ID;
  const keySecret = process.env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) {
    throw new Error('Razorpay test or live API keys are not configured');
  }
  return { keyId, keySecret };
}

function getKeyId() {
  return getConfiguration().keyId;
}

async function razorpayRequest(path, { method = 'GET', body } = {}) {
  const { keyId, keySecret } = getConfiguration();
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Basic ${Buffer.from(`${keyId}:${keySecret}`).toString('base64')}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  let data;
  try {
    data = await response.json();
  } catch {
    throw new Error(`Razorpay returned an invalid response (${response.status})`);
  }
  if (!response.ok) {
    const description = data?.error?.description;
    throw new Error(
      `Razorpay request failed (${response.status}): ${
        typeof description === 'string' ? description : 'Unknown Razorpay error'
      }`,
    );
  }
  return data;
}

async function createOrder({ amount, currency, receipt, notes }) {
  const order = await razorpayRequest('/orders', {
    method: 'POST',
    body: { amount, currency, receipt, notes },
  });
  if (
    typeof order.id !== 'string' ||
    !Number.isSafeInteger(order.amount) ||
    typeof order.currency !== 'string'
  ) {
    throw new Error('Razorpay order response is missing required fields');
  }
  return order;
}

async function getPayment(paymentId) {
  return razorpayRequest(`/payments/${encodeURIComponent(paymentId)}`);
}

async function capturePayment(paymentId, { amount, currency }) {
  return razorpayRequest(`/payments/${encodeURIComponent(paymentId)}/capture`, {
    method: 'POST',
    body: { amount, currency },
  });
}

function matchesHmac(secret, content, signature) {
  if (
    typeof secret !== 'string' ||
    !secret ||
    typeof signature !== 'string' ||
    !/^[a-f0-9]{64}$/i.test(signature)
  ) {
    return false;
  }
  const expected = createHmac('sha256', secret).update(content).digest();
  const actual = Buffer.from(signature, 'hex');
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function verifyPaymentSignature(orderId, paymentId, signature) {
  const { keySecret } = getConfiguration();
  return matchesHmac(keySecret, `${orderId}|${paymentId}`, signature);
}

function verifyWebhookSignature(body, signature) {
  return matchesHmac(
    process.env.RAZORPAY_WEBHOOK_SECRET,
    body,
    signature,
  );
}

module.exports = {
  getKeyId,
  createOrder,
  getPayment,
  capturePayment,
  verifyPaymentSignature,
  verifyWebhookSignature,
};
