require('dotenv').config();
const express = require('express');
const jwt = require('jsonwebtoken');
const {
  applicationDefault,
  cert,
  getApps,
  initializeApp,
} = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { normalize, checkDealer, getItems } = require('./zoho');

const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET) throw new Error('JWT_SECRET must be set in .env');

const app = express();
app.use(express.json());

const APPROVED_PLUMBERS = new Set(['9000000001']);
function getFirebaseAuth() {
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
  return getAuth(app);
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

  const token = jwt.sign({ mobile, role, contactId }, JWT_SECRET, { expiresIn: '7d' });
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
            retail_price: item.price,
            dealer_price: Math.round(item.price * (1 - DEALER_DISCOUNT) * 100) / 100,
            stock: item.stock,
          }
        : {
            id: item.id,
            name: item.name,
            sku: item.sku,
            category: item.category,
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

app.get('/me', auth(), (req, res) => res.json(req.user));
app.get('/', (req, res) => res.send('Backend running'));

const PORT = process.env.PORT || 3000;
if (require.main === module) {
  app.listen(PORT, () => console.log(`Server on http://localhost:${PORT}`));
}

module.exports = app;
