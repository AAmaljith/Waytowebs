# Waytowebs Flutter app

This Android Flutter demo connects to Firebase Authentication, Cloud
Firestore, the Node.js backend, and Zoho Inventory. Firebase verifies mobile
numbers; customer profiles are stored in Firestore; the backend validates
Firebase ID tokens and applies dealer/plumber access rules before returning
the authenticated product catalogue.

## Run with the existing backend

1. Start the Node/Zoho backend in a separate terminal:

   ```powershell
   cd C:\Users\Amal\AndroidStudioProjects\waytowebs_task\backend
   node server.js
   ```

   If `backend\.env` does not exist yet, copy `backend\.env.example` to
   `backend\.env`. Set `JWT_SECRET`, `FIREBASE_PROJECT_ID`, the path to your
   Firebase Admin service-account JSON in `GOOGLE_APPLICATION_CREDENTIALS`,
   and the Zoho Inventory credentials and organization ID before starting the
   server. Keep the service-account JSON and Zoho credentials out of source
   control and out of the APK.

2. Start the app from another terminal. By default, it uses the deployed
   interview backend at `https://waytowebs.onrender.com`. To use a local
   backend instead, pass the appropriate `API_BASE_URL`:

   ```powershell
   cd C:\Users\Amal\AndroidStudioProjects\waytowebs_task\waytowebs_app
   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
   ```

   `10.0.2.2` reaches the host computer from the Android emulator. For a
   physical phone on the same network, use the computer's LAN IPv4 address:

   ```powershell
   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:3000
   ```

   Replace `192.168.1.10` with the IPv4 address shown by `ipconfig`; allow
   inbound TCP port 3000 through the development firewall if required.

The Android manifest permits cleartext HTTP for local development. Use HTTPS
and remove that allowance before production.

## Current integration

- Register the Android application in Firebase with package name
  `com.waytowebs.waytowebs_app`. Add the SHA-1 and SHA-256 fingerprints of the
  signing certificate used to build the APK to the Firebase Android app.
- Enable Phone sign-in in Firebase Authentication. Add an interview test phone
  number and fixed code under Phone numbers for testing. Test numbers verify
  without sending SMS; real phone numbers require Firebase billing for SMS.
- Create a Cloud Firestore database and publish the least-privilege rules from
  `..\backend\firestore.rules`. A customer can read their own profile and create
  only their own `customer` profile; clients cannot grant themselves dealer or
  plumber access.
- FlutterFire generated `lib\firebase_options.dart` and
  `android\app\google-services.json` for `waytowebs-interview-app`. Rerun
  `dart pub global run flutterfire_cli:flutterfire configure
  --project=waytowebs-interview-app --platforms=android` if you add platforms
  or change Firebase app settings.
- Backend `POST /auth/check-eligibility` checks dealer Zoho verification and
  plumber approval before requesting a Firebase code.
- After Firebase phone verification, the app exchanges the Firebase ID token
  with `POST /auth/firebase-session`. The backend verifies it with Firebase
  Admin SDK, rechecks role eligibility, and returns the backend JWT used by
  `GET /products`.
- Customers can register their name after phone verification; customer profiles
  are stored at `users/{firebaseUid}` in Firestore. Sign-in checks for an
  existing customer profile and directs new customers to complete registration.
- Dealer access continues to use verified Zoho contacts and custom fields.
  Plumber access continues to use the backend's admin-approved number list.
- Products and inventory are retrieved server-side from Zoho Inventory.
  Customer/plumber models expose only an availability flag; the dealer model
  exposes exact stock and dealer pricing. Zoho descriptions, brand,
  manufacturer, unit, weight, dimensions, and image availability are returned
  as product metadata. Product images are proxied through the authenticated
  backend so Zoho credentials never enter the app. Tapping a product opens its
  detail view; customers and plumbers see availability only, while dealers see
  stock quantity.
- Customers and dealers can add available products to a server-side cart. The
  backend stores cart product IDs and quantities in Firestore, then recalculates
  the price and stock from Zoho whenever the cart is read or changed.
- Customer and dealer upfront checkout creates a Zoho Sales Order and a
  Razorpay order using the server-calculated Zoho total. Razorpay Checkout runs
  in Test Mode when test credentials are configured. The backend verifies the
  checkout signature and payment status with Razorpay before reporting payment
  as paid. No card details are stored by the app or backend. Abandoned or
  failed checkouts can leave payment-pending Zoho Sales Orders.
- Approved dealer credit checkout remains separate and uses the existing Zoho
  credit terms and limits; it does not invoke Razorpay.
- An in-app admin dashboard provides protected customer, dealer, plumber,
  product, order, payment, and report sections. Admin login uses Firebase phone
  OTP and is enabled only for phone numbers listed in the backend
  `ADMIN_MOBILES` environment variable. Zoho-backed customer/dealer/product and
  shipment edits are written to Zoho; plumber approvals are stored in backend
  Firestore. Payment data is read-only in the app.
- Order history and tracking details are read from Zoho Sales Orders. Tapping
  an order opens a refreshable shipment timeline with the Zoho status, order
  date, shipment date, package tracking details, and ordered items when
  available, including product thumbnails loaded securely through the
  authenticated backend image proxy. Estimated arrival is shown as unavailable
  unless Zoho provides an ETA; the app does not invent delivery dates or
  simulate carrier progress.
- To enable payments, configure `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, and
  `RAZORPAY_WEBHOOK_SECRET` in the backend environment and follow
  `..\backend\DEPLOYMENT.md` to set up the Test Mode webhook. Keep the key
  secret server-side; Flutter receives only the public Key ID.
- The API base URL defaults to the public interview backend and can be overridden
  with the `API_BASE_URL` Dart define.

For an APK shared with interviewers outside your local network, build against a
public HTTPS backend URL (the default is `https://waytowebs.onrender.com`). The
local emulator and LAN addresses in the examples are only reachable during
local development.
