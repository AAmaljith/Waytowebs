require('dotenv').config();
const { createHash, randomUUID } = require('node:crypto');
const express = require('express');
const jwt = require('jsonwebtoken');
const {
  applicationDefault,
  cert,
  getApps,
  initializeApp,
} = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const {
  normalize,
  checkDealer,
  findCustomerContact,
  createCustomerContact,
  getItems,
  getItemImage,
  createSalesOrder,
  getSalesOrders,
  getSalesOrder,
} = require('./zoho');
const {
  getKeyId,
  createOrder: createRazorpayOrder,
  getPayment: getRazorpayPayment,
  capturePayment: captureRazorpayPayment,
  verifyPaymentSignature,
  verifyWebhookSignature,
} = require('./razorpay');

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) throw new Error('JWT_SECRET must be set in .env');

const app = express();
app.post(
  '/webhooks/razorpay',
  express.raw({ type: 'application/json', limit: '1mb' }),
  async (req, res) => {
    const signature = req.get('X-Razorpay-Signature');
    if (!Buffer.isBuffer(req.body) || !verifyWebhookSignature(req.body, signature)) {
      return res.status(400).json({ error: 'Invalid Razorpay webhook signature' });
    }

    let event;
    try {
      event = JSON.parse(req.body.toString('utf8'));
    } catch {
      return res.status(400).json({ error: 'Invalid Razorpay webhook payload' });
    }
    if (event.event !== 'payment.captured') return res.json({ received: true });

    const payment = event.payload?.payment?.entity;
    if (
      typeof payment?.order_id !== 'string' ||
      typeof payment?.id !== 'string' ||
      !Number.isSafeInteger(payment.amount) ||
      typeof payment.currency !== 'string'
    ) {
      return res.status(400).json({ error: 'Invalid captured payment details' });
    }

    try {
      const paymentRef = getDatabase()
        .collection('razorpay_orders')
        .doc(payment.order_id);
      const snapshot = await paymentRef.get();
      if (!snapshot.exists) {
        return res.status(500).json({ error: 'Payment order is not ready for webhook processing' });
      }
      const record = snapshot.data();
      if (payment.amount !== record.amount || payment.currency !== record.currency) {
        return res.status(400).json({ error: 'Captured payment does not match the checkout amount' });
      }
      await markPaymentCaptured(paymentRef, record, payment);
      return res.json({ received: true });
    } catch (error) {
      console.error('Razorpay webhook processing failed:', error);
      return res.status(500).json({ error: 'Could not process Razorpay webhook' });
    }
  },
);
app.use(express.json());

const APPROVED_PLUMBERS = new Set(['9000000001']);
let firestoreOverrideForTests;
function getFirebaseApp() {
  if (!process.env.FIREBASE_PROJECT_ID) {
    throw new Error('FIREBASE_PROJECT_ID must be set in .env');
  }
  let app = getApps()[0];
  if (!app) {
    let credential;
    if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
      let serviceAccount;
      try {
        serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
      } catch {
        throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON must contain valid JSON');
      }
      if (
        serviceAccount.project_id !== process.env.FIREBASE_PROJECT_ID ||
        typeof serviceAccount.client_email !== 'string' ||
        typeof serviceAccount.private_key !== 'string'
      ) {
        throw new Error('Firebase service-account JSON does not match FIREBASE_PROJECT_ID');
      }
      credential = cert(serviceAccount);
    } else {
      credential = applicationDefault();
    }
    app = initializeApp({
      credential,
      projectId: process.env.FIREBASE_PROJECT_ID,
    });
  }
  return app;
}

function getFirebaseAuth() {
  return getAuth(getFirebaseApp());
}

function getDatabase() {
  if (firestoreOverrideForTests) return firestoreOverrideForTests;
  return getFirestore(getFirebaseApp());
}

function setFirestoreForTests(database) {
  firestoreOverrideForTests = database;
}

app.post('/auth/check-eligibility', async (req, res) => {
  const role = String(req.body?.role || '').toLowerCase();
  const mobile = normalize(req.body?.mobile);
  if (!['dealer', 'plumber'].includes(role) || !/^\d{10}$/.test(mobile)) {
    return res.status(400).json({ error: 'A valid mobile number and role are required' });
  }

  try {
    if (role === 'dealer') {
      const result = await checkDealer(mobile);
      if (!result.allowed) {
        const maskedMobile = `${'*'.repeat(mobile.length - 2)}${mobile.slice(-2)}`;
        console.log(`[DEALER REJECTED] ${maskedMobile}: ${result.reason}`);
        return res.status(403).json({
          error: 'We could not verify this number for dealer access. Contact your admin.',
        });
      }
    } else if (!APPROVED_PLUMBERS.has(mobile)) {
      return res.status(403).json({
        error: 'We could not verify this number for plumber access. Contact your admin.',
      });
    }
    return res.json({ eligible: true });
  } catch (error) {
    console.error('Role eligibility check failed:', error);
    return res.status(500).json({ error: 'Could not verify access right now' });
  }
});

app.post('/auth/firebase-session', async (req, res) => {
  const role = String(req.body?.role || '').toLowerCase();
  const idToken = req.body?.idToken;
  if (!['customer', 'dealer', 'plumber'].includes(role) || typeof idToken !== 'string' || !idToken) {
    return res.status(400).json({ error: 'A Firebase ID token and valid role are required' });
  }

  let decoded;
  try {
    decoded = await getFirebaseAuth().verifyIdToken(idToken);
  } catch (error) {
    console.error('Firebase ID token verification failed:', error);
    const invalidTokenCodes = new Set([
      'auth/argument-error',
      'auth/id-token-expired',
      'auth/invalid-id-token',
    ]);
    const status = invalidTokenCodes.has(error.code) ? 401 : 503;
    return res.status(status).json({
      error: status === 401
        ? 'Firebase login has expired. Please verify your phone again.'
        : 'Firebase authentication is not configured on the backend.',
    });
  }

  const mobile = normalize(decoded.phone_number);
  if (!/^\d{10}$/.test(mobile)) {
    return res.status(403).json({ error: 'Firebase account has no valid phone number' });
  }

  let contactId = null;
  try {
    if (role === 'dealer') {
      const result = await checkDealer(mobile);
      if (!result.allowed) {
        return res.status(403).json({
          error: 'We could not verify this number for dealer access. Contact your admin.',
        });
      }
      contactId = result.contactId;
    } else if (role === 'plumber' && !APPROVED_PLUMBERS.has(mobile)) {
      return res.status(403).json({
        error: 'We could not verify this number for plumber access. Contact your admin.',
      });
    }
  } catch (error) {
    console.error('Post-login role verification failed:', error);
    return res.status(500).json({ error: 'Could not verify access right now' });
  }

  const uid = decoded.uid || decoded.sub;
  if (typeof uid !== 'string' || !uid) {
    return res.status(403).json({ error: 'Firebase account has no valid user ID' });
  }
  const token = jwt.sign({ uid, mobile, role, contactId }, JWT_SECRET, { expiresIn: '7d' });
  return res.json({ token, role, mobile });
});

function auth(allowedRoles) {
  return (req, res, next) => {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) return res.status(401).json({ error: 'Login required' });
    try {
      req.user = jwt.verify(token, JWT_SECRET);
    } catch {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    if (allowedRoles && !allowedRoles.includes(req.user.role))
      return res.status(403).json({ error: 'Not allowed for your role' });
    next();
  };
}

const DEALER_DISCOUNT = 0.1;
const MAX_CART_LINES = 100;
const MAX_CART_QUANTITY = 100000;

class ApiError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function cartDocument(user) {
  const identity = user.uid || user.mobile;
  const id = createHash('sha256')
    .update(`${user.role}:${identity}`)
    .digest('hex');
  return getDatabase().collection('carts').doc(id);
}

function orderRequestDocument(user, idempotencyKey) {
  const id = createHash('sha256')
    .update(`${user.role}:${user.uid || user.mobile}:${idempotencyKey}`)
    .digest('hex');
  return getDatabase().collection('order_requests').doc(id);
}

function razorpayRequestDocument(user, idempotencyKey) {
  const id = createHash('sha256')
    .update(`${user.role}:${user.uid || user.mobile}:${idempotencyKey}`)
    .digest('hex');
  return getDatabase().collection('razorpay_requests').doc(id);
}

async function markPaymentCaptured(paymentRef, record, payment) {
  if (
    payment.order_id !== record.razorpay_order_id ||
    payment.amount !== record.amount ||
    payment.currency !== record.currency
  ) {
    throw new Error('Razorpay payment does not match the stored checkout');
  }
  const current = await paymentRef.get();
  if (!current.exists) throw new Error('Razorpay order record is missing');
  if (current.data()?.status !== 'captured') {
    await paymentRef.set({
      ...record,
      status: 'captured',
      payment_id: payment.id,
      capturedAt: FieldValue.serverTimestamp(),
    });
  }
  await getDatabase()
    .collection('order_payments')
    .doc(record.salesorder_id)
    .set({
      provider: 'razorpay',
      payment_status: 'paid',
      payment_id: payment.id,
      amount: record.amount,
      currency: record.currency,
      capturedAt: FieldValue.serverTimestamp(),
    });
  const cartRef = cartDocument({
    uid: record.uid,
    mobile: record.mobile,
    role: record.role,
  });
  const cartSnapshot = await cartRef.get();
  const currentItems = cartSnapshot.exists ? cartSnapshot.data()?.items : [];
  if (JSON.stringify(currentItems) === JSON.stringify(record.cart_items)) {
    await cartRef.delete();
  }
}

function parseCartInput(body) {
  if (!Array.isArray(body?.items) || body.items.length > MAX_CART_LINES) {
    throw new ApiError(400, 'Cart must contain a valid items list of at most 100 products');
  }

  const seen = new Set();
  return body.items.map((line) => {
    if (
      typeof line?.productId !== 'string' ||
      !/^\d+$/.test(line.productId) ||
      typeof line.quantity !== 'number' ||
      !Number.isFinite(line.quantity) ||
      line.quantity <= 0 ||
      line.quantity > MAX_CART_QUANTITY
    ) {
      throw new ApiError(400, 'Each cart item needs a valid product ID and quantity');
    }
    if (seen.has(line.productId)) {
      throw new ApiError(400, 'A product may appear only once in the cart');
    }
    seen.add(line.productId);
    return { productId: line.productId, quantity: line.quantity };
  });
}

function resolveCartLines(cart, items, role) {
  const itemById = new Map(items.map((item) => [String(item.id), item]));
  return cart.map((line) => {
    const item = itemById.get(line.productId);
    if (!item || item.canBeSold === false) {
      throw new ApiError(409, 'A product in the cart is no longer available');
    }
    const stock = Number(item.stock);
    const price = Number(item.price);
    if (!Number.isFinite(stock) || !Number.isFinite(price) || price < 0) {
      throw new ApiError(502, 'Zoho returned invalid stock or pricing for a product');
    }
    if (line.quantity > stock) {
      throw new ApiError(409, `Only ${stock} units of ${item.name} are currently available`);
    }
    const unitPrice = role === 'dealer'
      ? Math.round(price * (1 - DEALER_DISCOUNT) * 100) / 100
      : price;
    return {
      id: String(item.id),
      name: item.name,
      sku: item.sku,
      category: item.category,
      quantity: line.quantity,
      unitPrice,
      lineTotal: Math.round(unitPrice * line.quantity * 100) / 100,
      taxId: item.taxId,
      taxPercentage: item.taxPercentage,
      stock,
    };
  });
}

function toCartResponse(lines, role) {
  const items = lines.map((line) => ({
    product_id: line.id,
    name: line.name,
    sku: line.sku,
    category: line.category,
    quantity: line.quantity,
    unit_price: line.unitPrice,
    line_total: line.lineTotal,
    ...(role === 'dealer'
      ? { stock: line.stock }
      : { in_stock: line.stock > 0 }),
  }));
  return {
    items,
    subtotal: Math.round(
      items.reduce((total, line) => total + line.line_total, 0) * 100,
    ) / 100,
  };
}

async function getOrderContact(user, { createCustomer = false } = {}) {
  if (user.role === 'dealer') {
    const dealer = await checkDealer(user.mobile);
    if (!dealer.allowed) {
      throw new ApiError(403, 'Dealer verification is no longer valid');
    }
    return dealer;
  }

  const existingContact = await findCustomerContact(user.mobile);
  if (existingContact) return existingContact;
  if (!createCustomer) return null;
  if (typeof user.uid !== 'string' || !user.uid) {
    throw new ApiError(403, 'Sign in again to place an order');
  }
  const profileSnapshot = await getDatabase()
    .collection('users')
    .doc(user.uid)
    .get();
  const profile = profileSnapshot.data();
  if (!profileSnapshot.exists || profile?.role !== 'customer') {
    throw new ApiError(409, 'Complete your customer profile before placing an order');
  }
  return createCustomerContact({
    name: profile.name,
    mobile: user.mobile,
  });
}

app.get('/products', auth(), async (req, res) => {
  try {
    const items = await getItems();
    const isDealer = req.user.role === 'dealer';

    const products = items.map((item) =>
      isDealer
        ? {
            id: item.id,
            name: item.name,
            sku: item.sku,
            category: item.category,
            description: item.description,
            brand: item.brand,
            manufacturer: item.manufacturer,
            unit: item.unit,
            weight: item.weight,
            dimensions: item.dimensions,
            image_available: item.imageAvailable,
            retail_price: item.price,
            dealer_price: Math.round(item.price * (1 - DEALER_DISCOUNT) * 100) / 100,
            stock: item.stock,
          }
        : {
            id: item.id,
            name: item.name,
            sku: item.sku,
            category: item.category,
            description: item.description,
            brand: item.brand,
            manufacturer: item.manufacturer,
            unit: item.unit,
            weight: item.weight,
            dimensions: item.dimensions,
            image_available: item.imageAvailable,
            price: item.price,
            in_stock: item.stock > 0,
          }
    );
    res.json({ role: req.user.role, products });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'Could not load products' });
  }
});

app.get('/cart', auth(['customer', 'dealer']), async (req, res) => {
  try {
    const snapshot = await cartDocument(req.user).get();
    const storedItems = snapshot.exists ? snapshot.data()?.items : [];
    if (!Array.isArray(storedItems)) {
      throw new Error('Stored cart has an invalid format');
    }
    const cart = parseCartInput({ items: storedItems });
    const lines = cart.length === 0
      ? []
      : resolveCartLines(cart, await getItems(), req.user.role);
    return res.json(toCartResponse(lines, req.user.role));
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({
        error: error.message,
        ...(error.code ? { code: error.code } : {}),
      });
    }
    console.error('Cart retrieval failed:', error);
    return res.status(500).json({ error: 'Could not retrieve the cart' });
  }
});

app.put('/cart', auth(['customer', 'dealer']), async (req, res) => {
  let cart;
  try {
    cart = parseCartInput(req.body);
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }

  try {
    if (cart.length > 0) {
      resolveCartLines(cart, await getItems(), req.user.role);
    }
    await cartDocument(req.user).set({
      items: cart,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return res.json({ updated: true, item_count: cart.length });
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({
        error: error.message,
        ...(error.code ? { code: error.code } : {}),
      });
    }
    console.error('Cart update failed:', error);
    return res.status(500).json({ error: 'Could not update the cart' });
  }
});

app.post('/payments/razorpay/orders', auth(['customer', 'dealer']), async (req, res) => {
  const idempotencyKey = req.get('Idempotency-Key');
  if (typeof idempotencyKey !== 'string' || !/^[A-Za-z0-9_-]{8,128}$/.test(idempotencyKey)) {
    return res.status(400).json({ error: 'A valid Idempotency-Key header is required' });
  }

  let keyId;
  try {
    keyId = getKeyId();
  } catch (error) {
    console.error('Razorpay configuration is unavailable:', error);
    return res.status(503).json({ error: 'Razorpay payments are not configured yet' });
  }

  const requestRef = razorpayRequestDocument(req.user, idempotencyKey);
  try {
    const priorRequest = await requestRef.get();
    if (priorRequest.exists) {
      const previous = priorRequest.data();
      if (previous.status === 'checkout_created' && previous.response) {
        return res.status(200).json(previous.response);
      }
      return res.status(409).json({
        error: 'This payment request is already being processed or needs support review',
        reference_number: previous.reference_number,
      });
    }

    const cartRef = cartDocument(req.user);
    const cartSnapshot = await cartRef.get();
    const storedItems = cartSnapshot.exists ? cartSnapshot.data()?.items : [];
    if (!Array.isArray(storedItems) || storedItems.length === 0) {
      throw new ApiError(400, 'Add products to your cart before paying');
    }
    const cart = parseCartInput({ items: storedItems });
    const contact = await getOrderContact(req.user, { createCustomer: true });
    const lines = resolveCartLines(
      cart,
      await getItems({ refresh: true }),
      req.user.role,
    );
    const referenceNumber = `WTW-${randomUUID()}`;
    const db = getDatabase();
    const reservation = await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(requestRef);
      if (existing.exists) return { existing: existing.data() };
      transaction.create(requestRef, {
        status: 'processing',
        reference_number: referenceNumber,
        createdAt: FieldValue.serverTimestamp(),
      });
      return { referenceNumber };
    });
    if (reservation.existing) {
      const previous = reservation.existing;
      if (previous.status === 'checkout_created' && previous.response) {
        return res.status(200).json(previous.response);
      }
      return res.status(409).json({
        error: 'This payment request is already being processed or needs support review',
        reference_number: previous.reference_number,
      });
    }

    let zohoOrder;
    try {
      zohoOrder = await createSalesOrder({
        customer_id: contact.contactId,
        reference_number: referenceNumber,
        payment_terms: 0,
        line_items: lines.map((line) => ({
          item_id: line.id,
          rate: line.unitPrice,
          quantity: line.quantity,
          ...(line.taxId ? { tax_id: line.taxId } : {}),
        })),
        notes: `Waytowebs app order. Payment via Razorpay; status pending. Reference: ${referenceNumber}.`,
      });
    } catch (error) {
      console.error(`Zoho order ${referenceNumber} could not be confirmed for Razorpay checkout:`, error);
      await requestRef.update({ status: 'review_required' });
      return res.status(502).json({ error: 'Could not prepare the order in Zoho for payment' });
    }

    const total = Number(zohoOrder.total);
    const amount = Math.round(total * 100);
    if (!Number.isFinite(total) || total <= 0 || !Number.isSafeInteger(amount) || amount < 100) {
      await requestRef.update({
        status: 'review_required',
        salesorder_id: String(zohoOrder.salesorder_id),
      });
      throw new ApiError(502, 'Zoho returned an invalid total for payment');
    }

    const razorpayOrder = await createRazorpayOrder({
      amount,
      currency: 'INR',
      receipt: referenceNumber,
      notes: { salesorder_id: String(zohoOrder.salesorder_id) },
    });
    if (
      razorpayOrder.amount !== amount ||
      razorpayOrder.currency !== 'INR'
    ) {
      throw new Error('Razorpay order amount did not match the Zoho sales order');
    }

    const response = {
      checkout: {
        key_id: keyId,
        order_id: razorpayOrder.id,
        amount,
        currency: 'INR',
      },
      order: {
        id: String(zohoOrder.salesorder_id),
        number: zohoOrder.salesorder_number || referenceNumber,
        status: zohoOrder.status || 'open',
        total,
        payment_status: 'pending',
      },
    };
    await db.collection('razorpay_orders').doc(razorpayOrder.id).set({
      razorpay_order_id: razorpayOrder.id,
      salesorder_id: String(zohoOrder.salesorder_id),
      salesorder_number: response.order.number,
      reference_number: referenceNumber,
      uid: req.user.uid || null,
      mobile: req.user.mobile,
      role: req.user.role,
      amount,
      currency: 'INR',
      cart_items: cart,
      status: 'created',
      request_id: requestRef.id,
      createdAt: FieldValue.serverTimestamp(),
    });
    await requestRef.update({
      status: 'checkout_created',
      response,
      salesorder_id: String(zohoOrder.salesorder_id),
      razorpay_order_id: razorpayOrder.id,
    });
    return res.status(201).json(response);
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({ error: error.message });
    }
    console.error('Razorpay checkout order creation failed:', error);
    return res.status(502).json({ error: 'Could not start Razorpay checkout' });
  }
});

app.post('/payments/razorpay/verify', auth(['customer', 'dealer']), async (req, res) => {
  const { orderId, paymentId, signature } = req.body || {};
  if (
    typeof orderId !== 'string' ||
    !/^order_[A-Za-z0-9]+$/.test(orderId) ||
    typeof paymentId !== 'string' ||
    !/^pay_[A-Za-z0-9]+$/.test(paymentId) ||
    typeof signature !== 'string'
  ) {
    return res.status(400).json({ error: 'Razorpay payment details are invalid' });
  }
  try {
    if (!verifyPaymentSignature(orderId, paymentId, signature)) {
      return res.status(400).json({ error: 'Razorpay payment signature is invalid' });
    }
    const paymentRef = getDatabase().collection('razorpay_orders').doc(orderId);
    const snapshot = await paymentRef.get();
    if (!snapshot.exists) return res.status(404).json({ error: 'Razorpay order was not found' });
    const record = snapshot.data();
    if (
      record.uid !== req.user.uid ||
      record.role !== req.user.role ||
      record.razorpay_order_id !== orderId
    ) {
      return res.status(403).json({ error: 'Razorpay order does not belong to this account' });
    }

    let payment = await getRazorpayPayment(paymentId);
    if (
      payment.id !== paymentId ||
      payment.order_id !== orderId ||
      payment.amount !== record.amount ||
      payment.currency !== record.currency
    ) {
      return res.status(400).json({ error: 'Razorpay payment does not match the order amount' });
    }
    if (payment.status === 'authorized') {
      await captureRazorpayPayment(paymentId, {
        amount: record.amount,
        currency: record.currency,
      });
      payment = await getRazorpayPayment(paymentId);
    }
    if (payment.status !== 'captured') {
      return res.status(409).json({ error: 'Razorpay has not captured this payment yet' });
    }

    await markPaymentCaptured(paymentRef, record, payment);
    return res.json({
      order: {
        id: record.salesorder_id,
        number: record.salesorder_number,
        status: 'open',
        total: record.amount / 100,
        payment_method: 'razorpay',
        payment_status: 'paid',
      },
      payment: {
        provider: 'razorpay',
        status: 'captured',
        payment_id: paymentId,
      },
    });
  } catch (error) {
    console.error('Razorpay payment verification failed:', error);
    return res.status(502).json({ error: 'Could not verify Razorpay payment' });
  }
});

app.get('/dealer/credit', auth(['dealer']), async (req, res) => {
  try {
    const dealer = await checkDealer(req.user.mobile);
    if (!dealer.allowed) {
      return res.status(403).json({ error: 'Dealer verification is no longer valid' });
    }
    const configuredLimit = dealer.creditLimit !== null && dealer.creditLimit > 0;
    const availableCredit = configuredLimit && dealer.outstandingReceivable !== null
      ? Math.max(0, dealer.creditLimit - dealer.outstandingReceivable)
      : null;
    const enabledTerms =
      configuredLimit &&
      availableCredit !== null &&
      [30, 90].includes(dealer.paymentTerms)
        ? [dealer.paymentTerms]
        : [];
    return res.json({
      enabled_terms: enabledTerms,
      credit_limit: dealer.creditLimit,
      outstanding_balance: dealer.outstandingReceivable,
      available_credit: availableCredit,
    });
  } catch (error) {
    console.error('Zoho dealer credit lookup failed:', error);
    return res.status(502).json({ error: 'Could not retrieve dealer credit settings from Zoho' });
  }
});

app.post('/orders', auth(['customer', 'dealer']), async (req, res) => {
  const idempotencyKey = req.get('Idempotency-Key');
  if (typeof idempotencyKey !== 'string' || !/^[A-Za-z0-9_-]{8,128}$/.test(idempotencyKey)) {
    return res.status(400).json({
      error: 'A valid Idempotency-Key header is required to create an order',
    });
  }

  const paymentMethod = req.body?.paymentMethod;
  const creditTermDays = req.body?.creditTermDays;
  if (req.user.role !== 'dealer' || paymentMethod !== 'credit') {
    return res.status(400).json({
      error: 'Customer and dealer upfront orders must use Razorpay checkout',
    });
  }
  if (
    paymentMethod === 'credit' &&
    ![30, 90].includes(creditTermDays)
  ) {
    return res.status(400).json({ error: 'Select an available 30- or 90-day credit term' });
  }
  if (paymentMethod !== 'credit' && creditTermDays !== undefined) {
    return res.status(400).json({ error: 'Credit term is only valid for credit orders' });
  }

  try {
    const db = getDatabase();
    const requestRef = orderRequestDocument(req.user, idempotencyKey);
    const priorRequest = await requestRef.get();
    if (priorRequest.exists) {
      const previous = priorRequest.data();
      if (previous.status === 'completed' && previous.response) {
        return res.status(200).json(previous.response);
      }
      return res.status(409).json({
        error: 'This order request is already being processed or needs support review',
        reference_number: previous.reference_number,
      });
    }

    const cartRef = cartDocument(req.user);
    const cartSnapshot = await cartRef.get();
    const storedItems = cartSnapshot.exists ? cartSnapshot.data()?.items : [];
    if (!Array.isArray(storedItems) || storedItems.length === 0) {
      throw new ApiError(400, 'Add products to your cart before placing an order');
    }

    const contact = await getOrderContact(req.user, { createCustomer: true });
    if (
      paymentMethod === 'credit' &&
      contact.paymentTerms !== creditTermDays
    ) {
      throw new ApiError(
        403,
        'This credit term is not enabled for your Zoho dealer account',
        'CREDIT_TERM_NOT_ENABLED',
      );
    }

    const cart = parseCartInput({ items: storedItems });
    const lines = resolveCartLines(
      cart,
      await getItems({ refresh: true }),
      req.user.role,
    );
    if (paymentMethod === 'credit') {
      const { creditLimit, outstandingReceivable } = contact;
      if (
        typeof creditLimit !== 'number' ||
        typeof outstandingReceivable !== 'number' ||
        creditLimit <= 0
      ) {
        throw new ApiError(
          403,
          'Credit is unavailable because the Zoho account has no valid credit limit',
          'CREDIT_TERM_NOT_ENABLED',
        );
      }
      if (lines.some((line) => line.taxId && line.taxPercentage === null)) {
        throw new ApiError(
          409,
          'Credit order total cannot be verified until Zoho tax details are available',
        );
      }
      const estimatedTotal = lines.reduce((total, line) => {
        const tax = line.taxPercentage === null
          ? 0
          : line.lineTotal * line.taxPercentage / 100;
        return total + line.lineTotal + tax;
      }, 0);
      const availableCredit = Math.max(0, creditLimit - outstandingReceivable);
      if (estimatedTotal > availableCredit) {
        throw new ApiError(
          409,
          'The order exceeds the available Zoho credit balance',
          'CREDIT_LIMIT_EXCEEDED',
        );
      }
    }
    const referenceNumber = `WTW-${randomUUID()}`;
    const reservation = await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(requestRef);
      if (existing.exists) return { existing: existing.data() };
      transaction.create(requestRef, {
        status: 'processing',
        reference_number: referenceNumber,
        createdAt: FieldValue.serverTimestamp(),
      });
      return { referenceNumber };
    });

    if (reservation.existing) {
      const previous = reservation.existing;
      if (previous.status === 'completed' && previous.response) {
        return res.status(200).json(previous.response);
      }
      return res.status(409).json({
        error: 'This order request is already being processed or needs support review',
        reference_number: previous.reference_number,
      });
    }

    const orderLines = lines.map((line) => ({
      item_id: line.id,
      rate: line.unitPrice,
      quantity: line.quantity,
      ...(line.taxId ? { tax_id: line.taxId } : {}),
    }));
    let order;
    try {
      order = await createSalesOrder({
        customer_id: contact.contactId,
        reference_number: referenceNumber,
        payment_terms: paymentMethod === 'credit' ? creditTermDays : 0,
        line_items: orderLines,
        notes: `Waytowebs app order. Payment method: ${paymentMethod}. Payment status: pending.`,
      });
    } catch (error) {
      console.error(`Zoho order request ${referenceNumber} could not be confirmed:`, error);
      try {
        await requestRef.update({
          status: 'review_required',
          failureRecordedAt: FieldValue.serverTimestamp(),
        });
      } catch (recordError) {
        console.error(`Could not record the Zoho order failure for ${referenceNumber}:`, recordError);
      }
      return res.status(502).json({
        error: 'Zoho could not confirm the order. Contact support before retrying.',
        reference_number: referenceNumber,
      });
    }
    const response = {
      order: {
        id: String(order.salesorder_id),
        number: order.salesorder_number || referenceNumber,
        reference_number: referenceNumber,
        status: order.status || 'open',
        total: order.total ?? null,
        payment_method: paymentMethod,
        payment_status: 'pending',
        ...(paymentMethod === 'credit'
          ? { credit_term_days: creditTermDays }
          : {}),
      },
      payment: {
        status: 'pending',
        message: 'Payment capture is not configured yet.',
      },
    };

    try {
      await requestRef.update({
        status: 'completed',
        response,
        salesorder_id: String(order.salesorder_id),
        completedAt: FieldValue.serverTimestamp(),
      });
    } catch (error) {
      console.error(
        `Zoho order ${referenceNumber} was created but its idempotency record could not be saved:`,
        error,
      );
      return res.status(201).json({
        ...response,
        warning: 'Order created in Zoho; confirmation record needs support review.',
      });
    }

    try {
      await cartRef.delete();
    } catch (error) {
      console.error(`Zoho order ${referenceNumber} was created but the cart could not be cleared:`, error);
    }
    return res.status(201).json(response);
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({
        error: error.message,
        ...(error.code ? { code: error.code } : {}),
      });
    }
    console.error('Zoho order creation failed:', error);
    return res.status(502).json({ error: 'Could not create the order in Zoho' });
  }
});

app.get('/orders', auth(['customer', 'dealer']), async (req, res) => {
  try {
    const contact = await getOrderContact(req.user);
    if (!contact) return res.json({ orders: [] });
    const orders = await getSalesOrders(contact.contactId);
    return res.json({
      orders: orders
        .filter((order) => String(order.customer_id) === String(contact.contactId))
        .map((order) => ({
          id: String(order.salesorder_id),
          number: order.salesorder_number,
          status: order.status,
          total: order.total,
          date: order.date,
          shipment_date: order.shipment_date,
          packages: order.packages || [],
        })),
    });
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({ error: error.message });
    }
    console.error('Zoho order list failed:', error);
    return res.status(502).json({ error: 'Could not retrieve orders from Zoho' });
  }
});

app.get('/orders/:orderId', auth(['customer', 'dealer']), async (req, res) => {
  if (!/^\d+$/.test(req.params.orderId)) {
    return res.status(400).json({ error: 'A valid Zoho sales order ID is required' });
  }
  try {
    const contact = await getOrderContact(req.user);
    if (!contact) return res.status(404).json({ error: 'Order not found' });
    const order = await getSalesOrder(req.params.orderId);
    if (String(order.customer_id) !== String(contact.contactId)) {
      return res.status(404).json({ error: 'Order not found' });
    }
    return res.json({
      order: {
        id: String(order.salesorder_id),
        number: order.salesorder_number,
        status: order.status,
        total: order.total,
        date: order.date,
        shipment_date: order.shipment_date,
        line_items: order.line_items || [],
        packages: order.packages || [],
        invoices: order.invoices || [],
      },
    });
  } catch (error) {
    if (error instanceof ApiError) {
      return res.status(error.status).json({ error: error.message });
    }
    console.error('Zoho order retrieval failed:', error);
    return res.status(502).json({ error: 'Could not retrieve the order from Zoho' });
  }
});

app.get('/products/:productId/image', auth(), async (req, res) => {
  if (!/^\d+$/.test(req.params.productId)) {
    return res.status(400).json({ error: 'A valid product ID is required' });
  }

  try {
    const { image, contentType } = await getItemImage(req.params.productId);
    res
      .set('Content-Type', contentType)
      .set('Cache-Control', 'private, max-age=300')
      .send(image);
  } catch (error) {
    console.error('Product image request failed:', error);
    res.status(502).json({ error: 'Could not load product image' });
  }
});

app.get('/me', auth(), (req, res) => res.json(req.user));
app.get('/', (req, res) => res.send('Backend running'));

const PORT = process.env.PORT || 3000;
if (require.main === module) {
  app.listen(PORT, () => console.log(`Server on http://localhost:${PORT}`));
}

module.exports = app;
module.exports.setFirestoreForTests = setFirestoreForTests;
