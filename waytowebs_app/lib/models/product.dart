import 'app_role.dart';

class Product {
  const Product({
    required this.id,
    required this.name,
    required this.sku,
    required this.category,
    required this.price,
    required this.retailPrice,
    required this.stock,
    required this.inStock,
    required this.description,
    required this.brand,
    required this.manufacturer,
    required this.unit,
    required this.weight,
    required this.dimensions,
    required this.imageAvailable,
  });

  final String id;
  final String name;
  final String sku;
  final String category;
  final double? price;
  final double? retailPrice;
  final int? stock;
  final bool? inStock;
  final String description;
  final String brand;
  final String manufacturer;
  final String unit;
  final String weight;
  final String dimensions;
  final bool imageAvailable;

  factory Product.fromJson(Map<String, dynamic> json, AppRole role) {
    double? numberAsDouble(Object? value) =>
        value is num ? value.toDouble() : null;
    int? numberAsInt(Object? value) => value is num ? value.toInt() : null;

    return Product(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? 'Unnamed product'}',
      sku: '${json['sku'] ?? ''}',
      category: '${json['category'] ?? 'General'}',
      price: numberAsDouble(
        role == AppRole.dealer ? json['dealer_price'] : json['price'],
      ),
      retailPrice: numberAsDouble(json['retail_price']),
      stock: role == AppRole.dealer ? numberAsInt(json['stock']) : null,
      inStock: role == AppRole.dealer
          ? null
          : json['in_stock'] is bool
          ? json['in_stock'] as bool
          : null,
      description: '${json['description'] ?? ''}',
      brand: '${json['brand'] ?? ''}',
      manufacturer: '${json['manufacturer'] ?? ''}',
      unit: '${json['unit'] ?? ''}',
      weight: '${json['weight'] ?? ''}',
      dimensions: '${json['dimensions'] ?? ''}',
      imageAvailable: json['image_available'] == true,
    );
  }
}
