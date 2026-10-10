import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/app_role.dart';
import '../models/commerce.dart';
import '../models/product.dart';

const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://waytowebs.onrender.com',
);

class BackendApiException implements Exception {
  const BackendApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackendApi {
  BackendApi({http.Client? client})
    : _client = client ?? http.Client(),
      _baseUri = Uri.parse(apiBaseUrl);

  final http.Client _client;
  final Uri _baseUri;

  Uri productImageUri(String productId) =>
      _baseUri.resolve('/products/${Uri.encodeComponent(productId)}/image');

  Map<String, String> productImageHeaders(String token) => {
    'Authorization': 'Bearer $token',
  };

  Future<void> checkEligibility({
    required String mobile,
    required AppRole role,
  }) async {
    await _request(
      'POST',
      '/auth/check-eligibility',
      body: {'mobile': mobile, 'role': role.apiValue},
    );
  }

  Future<String> createFirebaseSession({
    required String firebaseIdToken,
    required AppRole role,
  }) async {
    final response = await _request(
      'POST',
      '/auth/firebase-session',
      body: {'idToken': firebaseIdToken, 'role': role.apiValue},
    );
    final token = response['token'];
    if (token is! String || token.isEmpty) {
      throw const BackendApiException(
        'The backend response did not include a login token.',
      );
    }
    return token;
  }

  Future<List<Product>> getProducts({
    required String token,
    required AppRole role,
  }) async {
    final response = await _request('GET', '/products', token: token);
    final productData = response['products'];
    if (productData is! List) {
      throw const BackendApiException(
        'The backend returned an invalid product list.',
      );
    }
    return productData
        .whereType<Map<String, dynamic>>()
        .map((item) => Product.fromJson(item, role))
        .toList(growable: false);
  }

  Future<CartData> getCart({
    required String token,
    required AppRole role,
  }) async {
    final response = await _request('GET', '/cart', token: token);
    try {
      return CartData.fromJson(response, role);
    } on FormatException {
      throw const BackendApiException('The backend returned an invalid cart.');
    }
  }

  Future<void> updateCart({
    required String token,
    required List<CartLine> items,
  }) async {
    await _request(
      'PUT',
      '/cart',
      token: token,
      body: {
        'items': items
            .map(
              (item) => {
                'productId': item.productId,
                'quantity': item.quantity,
              },
            )
            .toList(growable: false),
      },
    );
  }

  Future<DealerCredit> getDealerCredit({required String token}) async {
    final response = await _request('GET', '/dealer/credit', token: token);
    return DealerCredit.fromJson(response);
  }

  Future<ZohoOrder> createOrder({
    required String token,
    required String idempotencyKey,
    required String paymentMethod,
    int? creditTermDays,
  }) async {
    final response = await _request(
      'POST',
      '/orders',
      token: token,
      body: {
        'paymentMethod': paymentMethod,
        if (creditTermDays case final int term) 'creditTermDays': term,
      },
      extraHeaders: {'Idempotency-Key': idempotencyKey},
    );
    final order = response['order'];
    if (order is! Map<String, dynamic>) {
      throw const BackendApiException(
        'The backend did not return a Zoho order.',
      );
    }
    return ZohoOrder.fromJson(order);
  }

  Future<RazorpayCheckout> createRazorpayCheckout({
    required String token,
    required String idempotencyKey,
  }) async {
    final response = await _request(
      'POST',
      '/payments/razorpay/orders',
      token: token,
      extraHeaders: {'Idempotency-Key': idempotencyKey},
    );
    try {
      return RazorpayCheckout.fromJson(response);
    } on FormatException {
      throw const BackendApiException(
        'The backend returned an invalid Razorpay checkout.',
      );
    }
  }

  Future<ZohoOrder> verifyRazorpayPayment({
    required String token,
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    final response = await _request(
      'POST',
      '/payments/razorpay/verify',
      token: token,
      body: {
        'orderId': orderId,
        'paymentId': paymentId,
        'signature': signature,
      },
    );
    final order = response['order'];
    if (order is! Map<String, dynamic>) {
      throw const BackendApiException(
        'The backend did not confirm the paid Zoho order.',
      );
    }
    return ZohoOrder.fromJson(order);
  }

  Future<List<OrderRecord>> getOrders({required String token}) async {
    final response = await _request('GET', '/orders', token: token);
    final orders = response['orders'];
    if (orders is! List) {
      throw const BackendApiException(
        'The backend returned an invalid order list.',
      );
    }
    return orders
        .whereType<Map<String, dynamic>>()
        .map(OrderRecord.fromJson)
        .toList(growable: false);
  }

  Future<OrderRecord> getOrder({
    required String token,
    required String orderId,
  }) async {
    final response = await _request(
      'GET',
      '/orders/${Uri.encodeComponent(orderId)}',
      token: token,
    );
    final order = response['order'];
    if (order is! Map<String, dynamic>) {
      throw const BackendApiException('The backend returned an invalid order.');
    }
    return OrderRecord.fromJson(order);
  }

  Future<AdminDashboardData> getAdminDashboard({required String token}) async {
    final response = await _request('GET', '/admin/dashboard', token: token);
    try {
      return AdminDashboardData.fromJson(response);
    } on FormatException {
      throw const BackendApiException(
        'The backend returned invalid admin dashboard data.',
      );
    }
  }

  Future<void> createAdminCustomer({
    required String token,
    required String name,
    required String mobile,
  }) async {
    await _request(
      'POST',
      '/admin/customers',
      token: token,
      body: {'name': name, 'mobile': mobile},
    );
  }

  Future<void> updateAdminCustomer({
    required String token,
    required String id,
    required String name,
    required String mobile,
  }) async {
    await _request(
      'PUT',
      '/admin/contacts/${Uri.encodeComponent(id)}',
      token: token,
      body: {'name': name, 'mobile': mobile},
    );
  }

  Future<void> updateAdminDealer({
    required String token,
    required String id,
    required int paymentTerms,
    required double creditLimit,
    required bool verified,
  }) async {
    await _request(
      'PUT',
      '/admin/dealers/${Uri.encodeComponent(id)}',
      token: token,
      body: {
        'paymentTerms': paymentTerms,
        'creditLimit': creditLimit,
        'verified': verified,
      },
    );
  }

  Future<void> updateAdminPlumber({
    required String token,
    required String mobile,
    required String name,
    required bool active,
  }) async {
    await _request(
      'PUT',
      '/admin/plumbers/${Uri.encodeComponent(mobile)}',
      token: token,
      body: {'name': name, 'active': active},
    );
  }

  Future<void> updateAdminProduct({
    required String token,
    required String id,
    required String name,
    required String sku,
    required double price,
    required String description,
    required bool active,
  }) async {
    await _request(
      'PUT',
      '/admin/products/${Uri.encodeComponent(id)}',
      token: token,
      body: {
        'name': name,
        'sku': sku,
        'price': price,
        'description': description,
        'active': active,
      },
    );
  }

  Future<void> updateAdminShipment({
    required String token,
    required String orderId,
    required String? shipmentDate,
    required String deliveryMethod,
  }) async {
    await _request(
      'PUT',
      '/admin/orders/${Uri.encodeComponent(orderId)}/shipment',
      token: token,
      body: {'shipmentDate': shipmentDate, 'deliveryMethod': deliveryMethod},
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = _baseUri.resolve(path);
    if (kDebugMode) debugPrint('[backend] $method $path started.');
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (token != null) headers['Authorization'] = 'Bearer $token';
    if (extraHeaders != null) headers.addAll(extraHeaders);

    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers)
        ..body = body == null ? '' : jsonEncode(body);
      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: 90));
      final response = await http.Response.fromStream(
        streamedResponse,
      ).timeout(const Duration(seconds: 90));
      if (kDebugMode) {
        debugPrint('[backend] $method $path returned ${response.statusCode}.');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (kDebugMode) {
            final contentType = response.headers['content-type'] ?? 'unknown';
            final preview = response.body
                .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
                .trim();
            final previewLength = preview.length < 240 ? preview.length : 240;
            debugPrint(
              '[backend] $method $path returned a non-JSON error '
              '(content-type: $contentType): '
              '${preview.substring(0, previewLength)}',
            );
          }
          throw BackendApiException(
            'Backend request failed (${response.statusCode}).',
          );
        }
        throw const BackendApiException(
          'The backend returned an invalid response.',
        );
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            decoded is Map<String, dynamic> && decoded['error'] is String
            ? decoded['error'] as String
            : 'Backend request failed (${response.statusCode}).';
        if (kDebugMode) {
          debugPrint(
            '[backend] $method $path error: $message '
            '(HTTP ${response.statusCode}).',
          );
        }
        throw BackendApiException(message);
      }
      if (decoded is! Map<String, dynamic>) {
        throw const BackendApiException(
          'The backend returned an invalid response.',
        );
      }
      return decoded;
    } on SocketException {
      if (kDebugMode) debugPrint('[backend] $method $path could not connect.');
      throw BackendApiException(
        'Cannot reach the backend at $apiBaseUrl. Check that it is running '
        'and that API_BASE_URL points to the right address.',
      );
    } on TimeoutException {
      if (kDebugMode) debugPrint('[backend] $method $path timed out.');
      throw const BackendApiException(
        'The backend took too long to respond. Please try again.',
      );
    } on http.ClientException catch (error) {
      if (kDebugMode) {
        debugPrint('[backend] $method $path failed: ${error.message}');
      }
      throw BackendApiException('Network request failed: ${error.message}');
    }
  }

  void close() => _client.close();
}
