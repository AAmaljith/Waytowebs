# Waytowebs API Endpoint List

Base URL for the local proof of concept: `http://localhost:3000`

Requests and responses use JSON unless otherwise noted. Protected routes use:

```http
Authorization: Bearer <JWT>
```

## Zoho Inventory integration

The backend uses the Zoho Inventory API in the India data center for dealer
verification and the product catalog. It reads contacts, contact custom
fields, items, prices, and stock. List requests follow Zoho's pagination and
catalog data is cached for five minutes. OAuth credentials and the organization
ID are configured only in the backend environment; never put them in the
mobile app.

## Implemented in the Express proof of concept

| Method | Endpoint | Access | Purpose |
|---|---|---|---|
| `GET` | `/` | Public | Health check; responds with `Backend running`. |
| `POST` | `/auth/check-eligibility` | Public | Check Zoho dealer verification or plumber approval before starting Firebase phone verification. |
| `POST` | `/auth/firebase-session` | Public; Firebase ID token required | Verify the Firebase ID token, enforce role eligibility, and return a seven-day backend JWT. |
| `GET` | `/me` | Any valid JWT | Return the authenticated JWT claims: mobile, role, and dealer contact ID when applicable. |
| `GET` | `/products` | Any valid JWT | Return Zoho Inventory products filtered for the caller's role. |

### `POST /auth/check-eligibility`

Request:

```json
{
  "mobile": "<10-digit-mobile>",
  "role": "dealer"
}
```

Only dealer and plumber roles are accepted. Mobile numbers are normalized to
ten digits. A dealer must match exactly one Zoho contact with both `Is Dealer`
and `Verified` set. Plumbers must be in the demo's approved-number set. The
Flutter app calls this before Firebase sends or accepts a phone code.

Success (`200`):

```json
{ "eligible": true }
```

Eligibility failure returns `403`; invalid role or mobile returns `400`.

### `POST /auth/firebase-session`

After Firebase phone verification, the app sends the Firebase ID token:

```json
{
  "idToken": "<Firebase ID token>",
  "role": "customer"
}
```

The backend verifies the token with Firebase Admin SDK, derives the verified
phone number from its claims (never from client input), rechecks dealer/plumber
eligibility, and issues a seven-day backend JWT.

Success (`200`; token value omitted):

```json
{
  "token": "<JWT>",
  "role": "dealer",
  "mobile": "<10-digit-mobile>"
}
```

Invalid or expired Firebase tokens return `401`; missing Firebase Admin
configuration returns `503`; role eligibility failures return `403`.
Configure `FIREBASE_PROJECT_ID` and Application Default Credentials for the
Firebase Admin SDK on the backend. Firebase OTP sending and verification are
handled by Firebase Authentication, not these backend routes.

### `GET /products`

Requires a valid JWT. The proof of concept reads items from Zoho and caches
them for five minutes.

Dealer product shape:

```json
{
  "role": "dealer",
  "products": [
    {
      "id": "<Zoho item ID>",
      "name": "PVC Pipe 1 inch",
      "sku": "PVC-001",
      "category": "General",
      "retail_price": 250,
      "dealer_price": 225,
      "stock": 100
    }
  ]
}
```

Customer and plumber product shape deliberately excludes exact stock:

```json
{
  "role": "customer",
  "products": [
    {
      "id": "<Zoho item ID>",
      "name": "PVC Pipe 1 inch",
      "sku": "PVC-001",
      "category": "General",
      "price": 250,
      "in_stock": true
    }
  ]
}
```

Unauthenticated or invalid-token requests receive `401`. Product loading
failures receive `500`.

## Proposed production API (not implemented)

These routes connect the current proof of concept to the planned app screens.
They are a design proposal, not routes available on the running server.

| Method | Endpoint | Access | Purpose |
|---|---|---|---|
| `GET` | `/categories` | Authenticated | List catalogue categories. |
| `GET` | `/products/:productId` | Authenticated | Return a role-filtered product detail. |
| `GET` | `/cart` | Authenticated | Retrieve the caller's server-side cart. |
| `PUT` | `/cart` | Authenticated | Add/update/remove cart lines; server recalculates price. |
| `POST` | `/orders` | Customer or dealer JWT | Request order using product IDs, quantities, payment method, and (for dealer credit) selected term. The client must not send authoritative price or stock; backend recalculates both. |
| `GET` | `/orders` | Authenticated | List only orders visible to the caller. |
| `GET` | `/orders/:orderId` | Order owner or admin | Return order details, payment state, and Zoho sync status. |
| `GET` | `/dealer/credit` | Dealer | Return enabled terms, limit, synced outstanding/overdue balance, and available credit. |
| `POST` | `/payments/webhook` | Public route; gateway signature required | Verify a server-to-server payment event and idempotency; never trust a client callback as proof of payment. |
| `GET` | `/plumber/activities` | Approved plumber | List assigned work and statuses. |
| `GET` | `/plumber/notifications` | Approved plumber | List in-app notifications. |
| `GET` | `/admin/customers` | Admin | Search and manage customer accounts. |
| `GET`, `PATCH` | `/admin/dealers/:dealerId` | Admin | Review dealer account and manage application credit limit/terms. |
| `GET`, `POST`, `PATCH` | `/admin/plumbers` and `/admin/plumbers/:plumberId` | Admin | Review applications and approve/reject plumbers. |
| `GET`, `POST`, `PATCH` | `/admin/products` and `/admin/products/:productId` | Admin | Manage catalogue presentation and sync status; Zoho remains the inventory source. |
| `GET`, `PATCH` | `/admin/orders` and `/admin/orders/:orderId` | Admin | Review orders and resolve pending Zoho synchronization. |
| `GET` | `/admin/payments` | Admin | Review payment and refund status. |
| `GET` | `/admin/reports` | Admin | View sales, payment, credit, and operational reports. |

### Proposed `POST /orders` input and credit errors

The client submits product identifiers and requested quantities, but no price,
discount, stock level, tax amount, or credit balance:

```json
{
  "items": [
    { "productId": "zoho-item-id", "quantity": 2 }
  ],
  "paymentMethod": "credit",
  "creditTermDays": 30
}
```

The backend loads current authoritative prices and availability, computes
taxes/charges, checks role permissions and (for credit orders) the current
balance snapshot, then returns a server-calculated quote/order. Proposed
credit errors should use stable codes, for example:

| Status | Error code | Meaning |
|---|---|---|
| `403` | `CREDIT_TERM_NOT_ENABLED` | Selected 30-/90-day term is not enabled for this dealer. |
| `409` | `CREDIT_LIMIT_EXCEEDED` | Outstanding balance plus order total exceeds the admin-set limit. |
| `403` | `OVERDUE_INVOICES` | Business policy blocks new credit while invoices are overdue. |
| `503` | `CREDIT_BALANCE_UNAVAILABLE` | Zoho is down or the balance snapshot is too stale to safely approve credit. |

The overdue-invoice block is a proposed policy to confirm with the business.
For upfront orders, payment is confirmed by a verified gateway webhook before
Zoho sales-order creation.

Production should add pagination and filtering to collection routes, validate
all request bodies, enforce ownership and role authorization, and return
stable error codes. Order creation and Zoho synchronization should use
idempotency keys and durable retries. Dealer credit should fail closed when
the balance snapshot is stale or unavailable.
