import 'app_role.dart';

class CartLine {
  const CartLine({
    required this.productId,
    required this.name,
    required this.sku,
    required this.category,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.stock,
    required this.inStock,
  });

  final String productId;
  final String name;
  final String sku;
  final String category;
  final double quantity;
  final double unitPrice;
  final double lineTotal;
  final int? stock;
  final bool? inStock;

  factory CartLine.fromJson(Map<String, dynamic> json, AppRole role) {
    double number(Object? value) =>
        value is num ? value.toDouble() : double.nan;

    return CartLine(
      productId: '${json['product_id'] ?? ''}',
      name: '${json['name'] ?? 'Unnamed product'}',
      sku: '${json['sku'] ?? ''}',
      category: '${json['category'] ?? 'General'}',
      quantity: number(json['quantity']),
      unitPrice: number(json['unit_price']),
      lineTotal: number(json['line_total']),
      stock: role == AppRole.dealer && json['stock'] is num
          ? (json['stock'] as num).toInt()
          : null,
      inStock: role == AppRole.dealer
          ? null
          : json['in_stock'] is bool
          ? json['in_stock'] as bool
          : null,
    );
  }
}

class CartData {
  const CartData({required this.items, required this.subtotal});

  final List<CartLine> items;
  final double subtotal;

  factory CartData.fromJson(Map<String, dynamic> json, AppRole role) {
    final rawItems = json['items'];
    final subtotal = json['subtotal'];
    if (rawItems is! List || subtotal is! num) {
      throw const FormatException('Invalid cart response');
    }
    return CartData(
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map((item) => CartLine.fromJson(item, role))
          .toList(growable: false),
      subtotal: subtotal.toDouble(),
    );
  }
}

class DealerCredit {
  const DealerCredit({
    required this.enabledTerms,
    required this.creditLimit,
    required this.outstandingBalance,
    required this.availableCredit,
  });

  final List<int> enabledTerms;
  final double? creditLimit;
  final double? outstandingBalance;
  final double? availableCredit;

  factory DealerCredit.fromJson(Map<String, dynamic> json) {
    double? number(Object? value) => value is num ? value.toDouble() : null;
    final terms = json['enabled_terms'];
    return DealerCredit(
      enabledTerms: terms is List
          ? terms.whereType<num>().map((term) => term.toInt()).toList()
          : const [],
      creditLimit: number(json['credit_limit']),
      outstandingBalance: number(json['outstanding_balance']),
      availableCredit: number(json['available_credit']),
    );
  }
}

class ZohoOrder {
  const ZohoOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.total,
    required this.paymentStatus,
    required this.creditTermDays,
  });

  final String id;
  final String number;
  final String status;
  final double? total;
  final String paymentStatus;
  final int? creditTermDays;

  factory ZohoOrder.fromJson(Map<String, dynamic> json) {
    final total = json['total'];
    final creditTermDays = json['credit_term_days'];
    return ZohoOrder(
      id: '${json['id'] ?? ''}',
      number: '${json['number'] ?? ''}',
      status: '${json['status'] ?? 'open'}',
      total: total is num ? total.toDouble() : null,
      paymentStatus: '${json['payment_status'] ?? 'pending'}',
      creditTermDays: creditTermDays is num ? creditTermDays.toInt() : null,
    );
  }
}

class RazorpayCheckout {
  const RazorpayCheckout({
    required this.keyId,
    required this.orderId,
    required this.amount,
    required this.currency,
    required this.order,
  });

  final String keyId;
  final String orderId;
  final int amount;
  final String currency;
  final ZohoOrder order;

  factory RazorpayCheckout.fromJson(Map<String, dynamic> json) {
    final checkout = json['checkout'];
    final order = json['order'];
    if (checkout is! Map<String, dynamic> ||
        order is! Map<String, dynamic> ||
        checkout['key_id'] is! String ||
        checkout['order_id'] is! String ||
        checkout['amount'] is! int ||
        checkout['currency'] is! String) {
      throw const FormatException('Invalid Razorpay checkout response');
    }
    return RazorpayCheckout(
      keyId: checkout['key_id'] as String,
      orderId: checkout['order_id'] as String,
      amount: checkout['amount'] as int,
      currency: checkout['currency'] as String,
      order: ZohoOrder.fromJson(order),
    );
  }
}

class OrderRecord {
  const OrderRecord({
    required this.id,
    required this.number,
    required this.status,
    required this.total,
    required this.date,
    required this.shipmentDate,
    required this.packages,
    required this.lineItems,
    required this.invoices,
  });

  final String id;
  final String number;
  final String status;
  final double? total;
  final String date;
  final String shipmentDate;
  final List<Map<String, dynamic>> packages;
  final List<Map<String, dynamic>> lineItems;
  final List<Map<String, dynamic>> invoices;

  factory OrderRecord.fromJson(Map<String, dynamic> json) {
    final total = json['total'];
    final packages = json['packages'];
    return OrderRecord(
      id: '${json['id'] ?? ''}',
      number: '${json['number'] ?? ''}',
      status: '${json['status'] ?? 'open'}',
      total: total is num ? total.toDouble() : null,
      date: '${json['date'] ?? ''}',
      shipmentDate: '${json['shipment_date'] ?? ''}',
      packages: packages is List
          ? packages.whereType<Map<String, dynamic>>().toList(growable: false)
          : const [],
      lineItems: json['line_items'] is List
          ? (json['line_items'] as List)
                .whereType<Map<String, dynamic>>()
                .toList(growable: false)
          : const [],
      invoices: json['invoices'] is List
          ? (json['invoices'] as List).whereType<Map<String, dynamic>>().toList(
              growable: false,
            )
          : const [],
    );
  }
}

class AdminDashboardData {
  const AdminDashboardData({
    required this.customers,
    required this.dealers,
    required this.plumbers,
    required this.products,
    required this.orders,
    required this.payments,
    required this.razorpayOrders,
    required this.reports,
  });

  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> dealers;
  final List<Map<String, dynamic>> plumbers;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> payments;
  final List<Map<String, dynamic>> razorpayOrders;
  final Map<String, dynamic> reports;

  factory AdminDashboardData.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> records(String key) {
      final value = json[key];
      return value is List
          ? value.whereType<Map<String, dynamic>>().toList(growable: false)
          : const [];
    }

    final reports = json['reports'];
    if (reports is! Map<String, dynamic>) {
      throw const FormatException('Invalid admin dashboard response');
    }
    return AdminDashboardData(
      customers: records('customers'),
      dealers: records('dealers'),
      plumbers: records('plumbers'),
      products: records('products'),
      orders: records('orders'),
      payments: records('payments'),
      razorpayOrders: records('razorpay_orders'),
      reports: reports,
    );
  }
}
