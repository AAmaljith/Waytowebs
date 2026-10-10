# Waytowebs API Endpoint List

Base URL for the local proof of concept: `http://localhost:3000`

Requests and responses use JSON unless otherwise noted. Protected routes use:

```http
Authorization: Bearer <backend JWT>
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
| `GET` | `/products/:productId/image` | Any valid JWT | Proxy a Zoho product image without exposing Zoho credentials to the app. |
| `GET`, `PUT` | `/cart` | Customer or dealer JWT | Read or replace the caller's Firestore cart; prices and availability are resolved from Zoho. |
| `GET` | `/dealer/credit` | Dealer JWT | Read approved Zoho payment terms and available credit. |
| `POST` | `/orders` | Customer or dealer JWT | Revalidate the cart and create a Zoho Inventory Sales Order. Payment remains pending until a payment provider is integrated. |
| `GET` | `/orders` | Customer or dealer JWT | List only Zoho Sales Orders belonging to the caller's Zoho contact. |
| `GET` | `/orders/:orderId` | Customer or dealer JWT | Return an order only when its Zoho customer contact belongs to the caller. |

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
      "description": "Product description",
      "brand": "Brand",
      "manufacturer": "Manufacturer",
      "unit": "piece",
      "weight": "1 kg",
      "dimensions": "1 m",
      "image_available": true,
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
      "description": "Product description",
      "brand": "Brand",
      "manufacturer": "Manufacturer",
      "unit": "piece",
      "weight": "1 kg",
      "dimensions": "1 m",
      "image_available": true,
      "price": 250,
      "in_stock": true
    }
  ]
}
```

Unauthenticated or invalid-token requests receive `401`. Product loading
failures receive `500`.

### `GET /products/:productId/image`

Requires a valid backend JWT and a numeric Zoho item ID. The backend fetches
the image from Zoho Inventory and streams the bytes with the image content type.
Zoho OAuth credentials and tokens remain server-side. Invalid IDs return `400`,
missing or invalid JWTs return `401`, and Zoho/image failures return `502`.

### `GET /cart` and `PUT /cart`

Cart data is persisted per authenticated customer/dealer in Firestore. `GET`
returns Zoho-resolved names, current prices, line totals, and availability;
only dealers receive exact stock. `PUT` replaces the cart and accepts product
IDs and quantities only:

```json
{
  "items": [
    { "productId": "<Zoho item ID>", "quantity": 2 }
  ]
}
```

Every cart update checks that the product exists, is sellable, and has enough
available stock in Zoho. Client-supplied prices and stock are ignored.

### `GET /dealer/credit`

Rechecks the dealer in Zoho and returns the contact's configured `payment_terms`,
`credit_limit`, and `outstanding_receivable_amount`. A 30- or 90-day term is
enabled only when that exact Zoho payment term and a positive credit limit are
present. If Zoho does not provide a usable limit/balance, credit is disabled.

### `POST /orders`

Requires a unique `Idempotency-Key` header (8–128 alphanumeric, `_` or `-`
characters). The backend rereads Zoho inventory, recalculates prices, checks stock, and
creates the final Sales Order in Zoho. It matches a customer by verified mobile
number and, if no contact exists, creates a Zoho customer contact from that
customer's registered Firestore profile. Dealers are reverified against Zoho
when ordering.

Request body:

```json
{
  "paymentMethod": "direct"
}
```

Customers use `direct`; dealers use `upfront` or `credit`. Credit orders accept
`creditTermDays` 30 or 90 only when the verified Zoho dealer contact's
`payment_terms` exactly matches the requested term. New Zoho Sales Orders are
reported as payment-pending; this API does not charge a card or mark payment as
received. A payment provider/webhook must be integrated before claiming a
customer has paid.

### `GET /orders` and `GET /orders/:orderId`

Read Sales Orders from Zoho Inventory. The backend filters the list and checks
ownership on details so users can only see orders attached to their Zoho
customer contact. The response includes Zoho fulfillment packages and tracking
information when those exist.

## Other proposed production API (not implemented)

| Method | Endpoint | Access | Purpose |
|---|---|---|---|
| `GET` | `/categories` | Authenticated | List catalogue categories. |
| `GET` | `/products/:productId` | Authenticated | Return a role-filtered product detail. |
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
