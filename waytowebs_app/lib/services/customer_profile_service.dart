import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CustomerProfileService {
  CustomerProfileService({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  Future<String?> getCustomerName(String uid) async {
    final snapshot = await _firestore.collection('users').doc(uid).get();
    if (!snapshot.exists) return null;

    final data = snapshot.data();
    if (data?['role'] != 'customer') {
      throw StateError('This account does not have a customer profile.');
    }
    final name = data?['name'];
    if (name is! String || name.trim().isEmpty) {
      throw StateError('The customer profile is missing a valid name.');
    }
    return name;
  }

  Future<void> registerCustomer({required String name}) async {
    final user = _auth.currentUser;
    if (user == null || user.phoneNumber == null) {
      throw StateError('Verify your mobile number before registering.');
    }
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'A customer name is required.');
    }

    await _firestore.collection('users').doc(user.uid).set({
      'name': normalizedName,
      'phone': user.phoneNumber,
      'role': 'customer',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
