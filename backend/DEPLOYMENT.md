# Deploying the Waytowebs backend

The repository-level `render.yaml` defines a Render Free Web Service for this
backend. Connect the repository containing this project to Render and create
a Blueprint from `render.yaml`.

Render generates `JWT_SECRET` and sets `FIREBASE_PROJECT_ID`. In the service
Environment settings, provide the following values as secrets; do not commit
them or put them in the APK:

- `FIREBASE_SERVICE_ACCOUNT_JSON`: the full JSON content of a Firebase Admin
  service-account key for `waytowebs-interview-app`.
- `ZOHO_CLIENT_ID`
- `ZOHO_CLIENT_SECRET`
- `ZOHO_REFRESH_TOKEN`
- `ZOHO_ORG_ID`
- `RAZORPAY_KEY_ID`: Razorpay **Test Mode** Key ID (`rzp_test_...`) during
  development.
- `RAZORPAY_KEY_SECRET`: matching Razorpay Test Mode secret.
- `RAZORPAY_WEBHOOK_SECRET`: secret configured for the Razorpay webhook below;
  this is separate from the API key secret.

Enable Cloud Firestore for the configured Firebase project. The Firebase Admin
service account must be able to read/write Firestore; the backend stores carts
and order idempotency records there. The Zoho refresh token must have permissions to read/create contacts, read
items and product images, and read/create Sales Orders. Reauthorize it in Zoho
if order requests fail due to missing scopes.

After deployment, verify `https://<service>.onrender.com/` returns
`Backend running`. Free services can sleep while idle, so allow time for the
first request to wake the service.

Build the interview APK with the deployed HTTPS URL:

```powershell
cd C:\Users\Amal\AndroidStudioProjects\waytowebs_task\waytowebs_app
flutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com
```

## Razorpay test payments

1. In the Razorpay Dashboard, enable **Test Mode** and create an API key pair.
   Add the Key ID and Key Secret to the Render service's Environment settings
   using the exact variable names above. Never put the Key Secret in Flutter,
   source control, or chat.
2. In Razorpay's Webhooks settings, add
   `https://<service>.onrender.com/webhooks/razorpay`, configure a webhook
   secret, and subscribe to `payment.captured`. Add the same webhook secret to
   Render as `RAZORPAY_WEBHOOK_SECRET`, then save and deploy.
3. Customers and dealers paying upfront go through Razorpay Checkout. The
   backend verifies the payment with Razorpay before reporting it as paid.
   Dealer credit orders continue through the existing Zoho credit flow.
   Creating a checkout also creates a Zoho Sales Order marked payment-pending;
   abandoned or failed checkouts may therefore remain as unpaid Zoho orders.
4. Use Razorpay's Test Mode payment details when testing; do not use live keys
   until live payments are explicitly enabled and tested separately.

The local `.env` is excluded from Git. Keep any downloaded Firebase Admin
service-account key outside the repository and never share it in chat.
