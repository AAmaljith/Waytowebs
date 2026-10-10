const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');

process.env.JWT_SECRET ||= 'test-jwt-secret';
const app = require('./server');

let server;
let baseUrl;

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

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: 'A valid mobile number and role are required',
  });
});
