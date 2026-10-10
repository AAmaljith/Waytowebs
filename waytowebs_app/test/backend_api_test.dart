import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:waytowebs_app/models/app_role.dart';
import 'package:waytowebs_app/services/backend_api.dart';

void main() {
  test(
    'checks dealer eligibility before Firebase sends a verification code',
    () async {
      late http.Request capturedRequest;
      final api = BackendApi(
        client: MockClient((request) async {
          capturedRequest = request;
          return http.Response('{"message":"OTP sent"}', 200);
        }),
      );

      await api.checkEligibility(mobile: '8281292173', role: AppRole.dealer);

      expect(capturedRequest.url.path, '/auth/check-eligibility');
      expect(jsonDecode(capturedRequest.body), {
        'mobile': '8281292173',
        'role': 'dealer',
      });
      api.close();
    },
  );

  test(
    'exchanges a verified Firebase ID token for a backend session',
    () async {
      late http.Request capturedRequest;
      final api = BackendApi(
        client: MockClient((request) async {
          capturedRequest = request;
          return http.Response('{"token":"backend-jwt"}', 200);
        }),
      );

      final token = await api.createFirebaseSession(
        firebaseIdToken: 'firebase-id-token',
        role: AppRole.customer,
      );

      expect(token, 'backend-jwt');
      expect(capturedRequest.url.path, '/auth/firebase-session');
      expect(jsonDecode(capturedRequest.body), {
        'idToken': 'firebase-id-token',
        'role': 'customer',
      });
      api.close();
    },
  );

  test(
    'uses the returned JWT and preserves role-specific product fields',
    () async {
      final api = BackendApi(
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer demo-token');
          return http.Response(
            jsonEncode({
              'role': 'dealer',
              'products': [
                {
                  'id': '1',
                  'name': 'Pipe',
                  'sku': 'PIPE-01',
                  'category': 'Pipes',
                  'description': 'Potable water pipe',
                  'brand': 'Waytowebs',
                  'manufacturer': 'Pipe Works',
                  'unit': 'piece',
                  'weight': '1 kg',
                  'dimensions': '1 m',
                  'image_available': true,
                  'retail_price': 250,
                  'dealer_price': 225,
                  'stock': 14,
                },
              ],
            }),
            200,
          );
        }),
      );

      final products = await api.getProducts(
        token: 'demo-token',
        role: AppRole.dealer,
      );

      expect(products, hasLength(1));
      expect(products.single.price, 225);
      expect(products.single.retailPrice, 250);
      expect(products.single.stock, 14);
      expect(products.single.inStock, isNull);
      expect(products.single.description, 'Potable water pipe');
      expect(products.single.brand, 'Waytowebs');
      expect(products.single.manufacturer, 'Pipe Works');
      expect(products.single.unit, 'piece');
      expect(products.single.weight, '1 kg');
      expect(products.single.dimensions, '1 m');
      expect(products.single.imageAvailable, isTrue);
      api.close();
    },
  );

  test('does not expose exact stock in the customer product model', () async {
    final api = BackendApi(
      client: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'role': 'customer',
            'products': [
              {
                'id': '1',
                'name': 'Pipe',
                'sku': 'PIPE-01',
                'category': 'Pipes',
                'price': 250,
                'in_stock': true,
              },
            ],
          }),
          200,
        );
      }),
    );

    final products = await api.getProducts(
      token: 'demo-token',
      role: AppRole.customer,
    );

    expect(products.single.price, 250);
    expect(products.single.inStock, isTrue);
    expect(products.single.stock, isNull);
    expect(products.single.retailPrice, isNull);
    api.close();
  });

  test('builds authenticated product image requests against the backend', () {
    final api = BackendApi();
    expect(
      api.productImageUri('123'),
      Uri.parse('$apiBaseUrl/products/123/image'),
    );
    expect(api.productImageHeaders('demo-token'), {
      'Authorization': 'Bearer demo-token',
    });
    api.close();
  });

  test(
    'loads and updates a Zoho-priced cart without sending client prices',
    () async {
      final requests = <http.Request>[];
      final api = BackendApi(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'items': [
                  {
                    'product_id': '123',
                    'name': 'Pipe',
                    'sku': 'PIPE-01',
                    'category': 'Pipes',
                    'quantity': 2,
                    'unit_price': 225,
                    'line_total': 450,
                    'stock': 14,
                  },
                ],
                'subtotal': 450,
              }),
              200,
            );
          }
          return http.Response('{"updated":true,"item_count":1}', 200);
        }),
      );

      final cart = await api.getCart(token: 'demo-token', role: AppRole.dealer);
      expect(cart.items.single.productId, '123');
      expect(cart.items.single.quantity, 2);
      expect(cart.items.single.stock, 14);
      expect(cart.subtotal, 450);

      await api.updateCart(token: 'demo-token', items: cart.items);
      expect(requests[1].method, 'PUT');
      expect(jsonDecode(requests[1].body), {
        'items': [
          {'productId': '123', 'quantity': 2},
        ],
      });
      expect(requests[1].headers['authorization'], 'Bearer demo-token');
      api.close();
    },
  );

  test(
    'loads Zoho dealer credit and creates an idempotent pending order',
    () async {
      final requests = <http.Request>[];
      final api = BackendApi(
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/dealer/credit') {
            return http.Response(
              '{"enabled_terms":[90],"credit_limit":50000,'
              '"outstanding_balance":10000,"available_credit":40000}',
              200,
            );
          }
          return http.Response(
            '{"order":{"id":"12345","number":"SO-1","status":"open",'
            '"total":250,"payment_method":"credit","payment_status":"pending",'
            '"credit_term_days":90},'
            '"payment":{"status":"pending","message":"Not configured"}}',
            201,
          );
        }),
      );

      final credit = await api.getDealerCredit(token: 'demo-token');
      expect(credit.enabledTerms, [90]);
      expect(credit.availableCredit, 40000);

      final order = await api.createOrder(
        token: 'demo-token',
        idempotencyKey: 'request-key-123',
        paymentMethod: 'credit',
        creditTermDays: 90,
      );
      expect(order.id, '12345');
      expect(order.paymentStatus, 'pending');
      expect(requests.last.headers['idempotency-key'], 'request-key-123');
      expect(jsonDecode(requests.last.body), {
        'paymentMethod': 'credit',
        'creditTermDays': 90,
      });
      api.close();
    },
  );

  test('loads tracking details from Zoho order records', () async {
    final api = BackendApi(
      client: MockClient((request) async {
        return http.Response(
          '{"orders":[{"id":"123","number":"SO-1","status":"shipped",'
          '"total":450,"date":"2026-01-01","shipment_date":"2026-01-02",'
          '"packages":[{"tracking_number":"TRACK-123"}]}]}',
          200,
        );
      }),
    );

    final orders = await api.getOrders(token: 'demo-token');
    expect(orders.single.number, 'SO-1');
    expect(orders.single.status, 'shipped');
    expect(orders.single.packages.single['tracking_number'], 'TRACK-123');
    api.close();
  });

  test('loads an individual order and shipment details from Zoho', () async {
    final api = BackendApi(
      client: MockClient((request) async {
        expect(request.url.path, '/orders/123');
        return http.Response(
          '{"order":{"id":"123","number":"SO-1","status":"shipped",'
          '"date":"2026-01-01","shipment_date":"2026-01-02",'
          '"line_items":[{"name":"Pipe","quantity":2}],'
          '"packages":[{"tracking_number":"TRACK-123"}]}}',
          200,
        );
      }),
    );

    final order = await api.getOrder(token: 'demo-token', orderId: '123');
    expect(order.number, 'SO-1');
    expect(order.lineItems.single['name'], 'Pipe');
    expect(order.packages.single['tracking_number'], 'TRACK-123');
    api.close();
  });

  test('loads admin dashboard sections and reports from the backend', () async {
    final api = BackendApi(
      client: MockClient((request) async {
        expect(request.url.path, '/admin/dashboard');
        return http.Response(
          '{"customers":[{"id":"1","name":"Customer"}],'
          '"dealers":[],"plumbers":[],"products":[],"orders":[],"payments":[],"'
          'razorpay_orders":[],"reports":{"customer_count":1}}',
          200,
        );
      }),
    );

    final dashboard = await api.getAdminDashboard(token: 'admin-token');
    expect(dashboard.customers.single['name'], 'Customer');
    expect(dashboard.reports['customer_count'], 1);
    api.close();
  });
}
