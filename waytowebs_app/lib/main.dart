import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'firebase_options.dart';
import 'models/app_role.dart';
import 'models/commerce.dart';
import 'models/product.dart';
import 'services/backend_api.dart';
import 'services/customer_profile_service.dart';
import 'services/phone_auth_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (error) {
    runApp(_FirebaseSetupScreen(message: error.message));
    return;
  }
  runApp(const WaytowebsApp());
}

class _FirebaseSetupScreen extends StatelessWidget {
  const _FirebaseSetupScreen({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Firebase could not be initialized. Confirm the Android app '
                'is registered in Firebase and its configuration is current.'
                '${message == null ? '' : '\n\n$message'}',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WaytowebsApp extends StatelessWidget {
  const WaytowebsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF087E78);
    return MaterialApp(
      title: 'Waytowebs',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          surface: const Color(0xFFF7F8F6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8F6),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE4E9E7)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE4E9E7)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: seed, width: 1.5),
          ),
        ),
      ),
      home: const AppFlow(),
    );
  }
}

enum _Screen { roles, mobile, otp, register, products, admin }

enum _CustomerMode { signIn, register }

class AppFlow extends StatefulWidget {
  const AppFlow({super.key});

  @override
  State<AppFlow> createState() => _AppFlowState();
}

class _AppFlowState extends State<AppFlow> {
  final _api = BackendApi();
  final _phoneAuth = PhoneAuthService();
  final _profiles = CustomerProfileService();
  final _mobileController = TextEditingController();
  final _otpController = TextEditingController();
  final _nameController = TextEditingController();
  _Screen _screen = _Screen.roles;
  _CustomerMode _customerMode = _CustomerMode.signIn;
  AppRole? _role;
  String? _token;
  String? _error;
  bool _busy = false;
  bool _firebaseVerificationCompleted = false;
  List<Product> _products = const [];
  String _query = '';
  String _category = 'All';

  @override
  void dispose() {
    _mobileController.dispose();
    _otpController.dispose();
    _nameController.dispose();
    _api.close();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    final mobile = _mobileController.text.trim();
    if (mobile.length != 10) {
      setState(() => _error = 'Enter a valid 10-digit mobile number.');
      return;
    }
    final role = _role;
    if (role == null) return;
    if (role == AppRole.customer &&
        _customerMode == _CustomerMode.register &&
        _nameController.text.trim().isEmpty) {
      setState(() => _error = 'Enter your name to create a customer account.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _firebaseVerificationCompleted = false;
    });
    try {
      if (role != AppRole.customer) {
        await _api.checkEligibility(mobile: mobile, role: role);
      }
      await _phoneAuth.sendOtp(
        phoneNumber: '+91$mobile',
        onCodeSent: () {
          if (!mounted || _firebaseVerificationCompleted) return;
          _otpController.clear();
          setState(() => _screen = _Screen.otp);
        },
        onVerificationCompleted: (credential) {
          _firebaseVerificationCompleted = true;
          _completeFirebaseSignIn(credential);
        },
        onError: (message) {
          if (mounted) setState(() => _error = message);
        },
      );
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? 'Could not send OTP.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from Firebase.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (kDebugMode) debugPrint('[auth] Submitting Firebase OTP.');
    try {
      final credential = await _phoneAuth.verifyOtp(otp);
      if (kDebugMode) debugPrint('[auth] Firebase OTP verification succeeded.');
      await _finishPhoneSignIn(credential);
    } on FirebaseAuthException catch (error) {
      if (kDebugMode) {
        debugPrint('[auth] Firebase OTP verification failed: ${error.code}.');
      }
      if (mounted) {
        setState(() => _error = error.message ?? 'Invalid verification code.');
      }
    } on FirebaseException catch (error) {
      if (kDebugMode) {
        debugPrint('[auth] Firebase operation failed: ${error.code}.');
      }
      if (mounted) {
        setState(
          () =>
              _error = error.message ?? 'Could not load your customer profile.',
        );
      }
    } on BackendApiException catch (error) {
      if (kDebugMode) debugPrint('[auth] Backend operation failed: $error');
      if (mounted) setState(() => _error = error.message);
    } on StateError catch (error) {
      if (kDebugMode) debugPrint('[auth] Sign-in flow stopped: $error');
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeFirebaseSignIn(UserCredential credential) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _finishPhoneSignIn(credential);
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? 'Phone verification failed.');
      }
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error.message ?? 'Could not load your customer profile.',
        );
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishPhoneSignIn(UserCredential credential) async {
    final role = _role;
    final user = credential.user;
    if (role == null || user == null) {
      throw StateError('Firebase did not return an authenticated user.');
    }

    if (role == AppRole.customer) {
      final customerName = await _profiles.getCustomerName(user.uid);
      if (customerName == null) {
        if (_customerMode == _CustomerMode.register) {
          await _profiles.registerCustomer(name: _nameController.text);
          await _openProducts(user);
        } else if (mounted) {
          setState(() {
            _nameController.clear();
            _screen = _Screen.register;
          });
        }
        return;
      }
      if (_customerMode == _CustomerMode.register) {
        throw StateError('This phone already has an account. Choose Sign in.');
      }
    }

    await _openProducts(user);
  }

  Future<void> _completeCustomerRegistration() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _nameController.text.trim();
      if (name.isEmpty) {
        setState(() => _error = 'Enter your name to finish registration.');
        return;
      }
      await _profiles.registerCustomer(name: name);
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw StateError('Please verify your phone number first.');
      }
      await _openProducts(user);
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'Could not save your profile.',
        );
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openProducts(User user) async {
    final role = _role!;
    if (kDebugMode) {
      debugPrint('[auth] Requesting Firebase ID token for backend session.');
    }
    final firebaseIdToken = await user.getIdToken();
    if (firebaseIdToken == null || firebaseIdToken.isEmpty) {
      throw StateError('Could not obtain a Firebase login token.');
    }
    if (kDebugMode) {
      debugPrint('[auth] Exchanging Firebase token with backend.');
    }
    final token = await _api.createFirebaseSession(
      firebaseIdToken: firebaseIdToken,
      role: role,
    );
    if (role == AppRole.admin) {
      if (!mounted) return;
      setState(() {
        _token = token;
        _screen = _Screen.admin;
      });
      return;
    }
    if (kDebugMode) {
      debugPrint('[auth] Backend session created; loading products.');
    }
    final products = await _api.getProducts(token: token, role: role);
    if (kDebugMode) {
      debugPrint(
        '[auth] Product request succeeded (${products.length} items).',
      );
    }
    if (mounted) {
      setState(() {
        _token = token;
        _products = products;
        _category = 'All';
        _query = '';
        _screen = _Screen.products;
      });
    }
  }

  Future<void> _reloadProducts() async {
    final role = _role;
    final token = _token;
    if (role == null || token == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final products = await _api.getProducts(token: token, role: role);
      if (mounted) setState(() => _products = products);
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectRole(AppRole role) {
    setState(() {
      _role = role;
      _customerMode = _CustomerMode.signIn;
      _mobileController.clear();
      _otpController.clear();
      _nameController.clear();
      _error = null;
      _screen = _Screen.mobile;
    });
  }

  void _goBack() {
    setState(() {
      _error = null;
      _screen = switch (_screen) {
        _Screen.otp => _Screen.mobile,
        _Screen.register => _Screen.otp,
        _Screen.mobile => _Screen.roles,
        _ => _Screen.roles,
      };
    });
  }

  Future<void> _signOut() async {
    try {
      await _phoneAuth.signOut();
    } on FirebaseAuthException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? 'Could not sign out.');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _token = null;
      _role = null;
      _products = const [];
      _mobileController.clear();
      _otpController.clear();
      _nameController.clear();
      _error = null;
      _screen = _Screen.roles;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_screen) {
      _Screen.roles => _RoleScreen(onSelect: _selectRole),
      _Screen.mobile => _MobileScreen(
        role: _role!,
        controller: _mobileController,
        nameController: _nameController,
        customerMode: _customerMode,
        busy: _busy,
        error: _error,
        onBack: _goBack,
        onContinue: _requestOtp,
        onCustomerModeChanged: (mode) => setState(() {
          _customerMode = mode;
          _error = null;
        }),
      ),
      _Screen.otp => _OtpScreen(
        role: _role!,
        mobile: _mobileController.text.trim(),
        controller: _otpController,
        busy: _busy,
        error: _error,
        onBack: _goBack,
        onVerify: _verifyOtp,
        onResend: _requestOtp,
      ),
      _Screen.register => _CustomerRegistrationScreen(
        controller: _nameController,
        mobile: _mobileController.text.trim(),
        busy: _busy,
        error: _error,
        onBack: _goBack,
        onContinue: _completeCustomerRegistration,
      ),
      _Screen.products => _ProductsScreen(
        role: _role!,
        products: _products,
        api: _api,
        token: _token!,
        query: _query,
        category: _category,
        busy: _busy,
        error: _error,
        onQueryChanged: (value) => setState(() => _query = value),
        onCategoryChanged: (value) => setState(() => _category = value),
        onRefresh: _reloadProducts,
        onSignOut: _signOut,
      ),
      _Screen.admin => _AdminDashboardScreen(
        api: _api,
        token: _token!,
        onSignOut: _signOut,
      ),
    };
  }
}

class _AdminDashboardScreen extends StatefulWidget {
  const _AdminDashboardScreen({
    required this.api,
    required this.token,
    required this.onSignOut,
  });

  final BackendApi api;
  final String token;
  final VoidCallback onSignOut;

  @override
  State<_AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<_AdminDashboardScreen> {
  AdminDashboardData? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getAdminDashboard(token: widget.token);
      if (mounted) setState(() => _data = data);
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, String>?> _editDialog({
    required String title,
    required Map<String, String> fields,
  }) async {
    final controllers = {
      for (final field in fields.entries)
        field.key: TextEditingController(text: field.value),
    };
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in controllers.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: field.value,
                    keyboardType: switch (field.key) {
                      'Mobile' ||
                      'Price' ||
                      'Credit limit' ||
                      'Payment terms' => TextInputType.number,
                      'Description' => TextInputType.multiline,
                      _ => TextInputType.text,
                    },
                    maxLines: field.key == 'Description' ? 3 : 1,
                    decoration: InputDecoration(labelText: field.key),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              for (final field in controllers.entries)
                field.key: field.value.text.trim(),
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final controller in controllers.values) {
      controller.dispose();
    }
    return result;
  }

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Changes saved.')));
      }
    } on BackendApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _editCustomer(Map<String, dynamic> record) async {
    final values = await _editDialog(
      title: 'Edit customer',
      fields: {
        'Name': '${record['name'] ?? ''}',
        'Mobile': '${record['mobile'] ?? ''}'.replaceAll('+91', ''),
      },
    );
    if (values == null) return;
    await _perform(
      () => widget.api.updateAdminCustomer(
        token: widget.token,
        id: '${record['id']}',
        name: values['Name']!,
        mobile: values['Mobile']!,
      ),
    );
  }

  Future<void> _addCustomer() async {
    final values = await _editDialog(
      title: 'Add customer',
      fields: {'Name': '', 'Mobile': ''},
    );
    if (values == null) return;
    await _perform(
      () => widget.api.createAdminCustomer(
        token: widget.token,
        name: values['Name']!,
        mobile: values['Mobile']!,
      ),
    );
  }

  Future<void> _editDealer(Map<String, dynamic> record) async {
    final currentTerms = [0, 30, 90].contains(record['payment_terms'])
        ? '${record['payment_terms']}'
        : '0';
    final values = await _editDialog(
      title: 'Dealer verification and credit',
      fields: {
        'Payment terms': currentTerms,
        'Credit limit': '${record['credit_limit'] ?? 0}',
        'Verified (Yes/No)': record['verified'] == true ? 'Yes' : 'No',
      },
    );
    if (values == null) return;
    final terms = int.tryParse(values['Payment terms']!);
    final limit = double.tryParse(values['Credit limit']!);
    if (terms == null || limit == null) {
      _showMessage('Enter a valid payment term and credit limit.');
      return;
    }
    await _perform(
      () => widget.api.updateAdminDealer(
        token: widget.token,
        id: '${record['id']}',
        paymentTerms: terms,
        creditLimit: limit,
        verified: [
          'yes',
          'true',
        ].contains(values['Verified (Yes/No)']!.toLowerCase()),
      ),
    );
  }

  Future<void> _editPlumber(Map<String, dynamic> record) async {
    final values = await _editDialog(
      title: 'Manage plumber access',
      fields: {
        'Mobile': '${record['mobile'] ?? ''}',
        'Name': '${record['name'] ?? ''}',
      },
    );
    if (values == null) return;
    final mobile = values['Mobile']!;
    await _perform(
      () => widget.api.updateAdminPlumber(
        token: widget.token,
        mobile: mobile,
        name: values['Name']!,
        active: record['active'] != true,
      ),
    );
  }

  Future<void> _editProduct(Map<String, dynamic> record) async {
    final values = await _editDialog(
      title: 'Edit Zoho product',
      fields: {
        'Name': '${record['name'] ?? ''}',
        'SKU': '${record['sku'] ?? ''}',
        'Price': '${record['price'] ?? 0}',
        'Description': '${record['description'] ?? ''}',
        'Active (Yes/No)': record['active'] == true ? 'Yes' : 'No',
      },
    );
    if (values == null) return;
    final price = double.tryParse(values['Price']!);
    if (price == null) {
      _showMessage('Enter a valid product price.');
      return;
    }
    await _perform(
      () => widget.api.updateAdminProduct(
        token: widget.token,
        id: '${record['id']}',
        name: values['Name']!,
        sku: values['SKU']!,
        price: price,
        description: values['Description']!,
        active: [
          'yes',
          'true',
        ].contains(values['Active (Yes/No)']!.toLowerCase()),
      ),
    );
  }

  Future<void> _editShipment(Map<String, dynamic> record) async {
    final values = await _editDialog(
      title: 'Update shipment details',
      fields: {
        'Shipment date': '${record['shipment_date'] ?? ''}',
        'Delivery method': '${record['delivery_method'] ?? ''}',
      },
    );
    if (values == null) return;
    final date = values['Shipment date']!;
    if (date.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      _showMessage('Use the date format YYYY-MM-DD.');
      return;
    }
    await _perform(
      () => widget.api.updateAdminShipment(
        token: widget.token,
        orderId: '${record['id']}',
        shipmentDate: date.isEmpty ? null : date,
        deliveryMethod: values['Delivery method']!,
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _displayValue(Object? value) {
    if (value == null || value == '') return 'Not set';
    if (value is num) return value.toString();
    return '$value';
  }

  List<Widget> _records(
    List<Map<String, dynamic>> records, {
    required String title,
    required String Function(Map<String, dynamic>) subtitle,
    Future<void> Function(Map<String, dynamic>)? onEdit,
  }) {
    if (records.isEmpty) return [const _AdminEmptyState()];
    return [
      for (final record in records)
        Card(
          child: ListTile(
            title: Text(
              '${record['name'] ?? record['number'] ?? record['id'] ?? title}',
            ),
            subtitle: Text(subtitle(record)),
            isThreeLine: true,
            trailing: onEdit == null
                ? null
                : IconButton(
                    tooltip: 'Manage',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => onEdit(record),
                  ),
          ),
        ),
    ];
  }

  Widget _reportCards(Map<String, dynamic> reports) => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final entry in reports.entries)
        SizedBox(
          width: 155,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayValue(entry.value),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_label(entry.key)),
                ],
              ),
            ),
          ),
        ),
    ],
  );

  String _label(String value) => value
      .split('_')
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');

  Widget _section(List<Widget> children) =>
      ListView(padding: const EdgeInsets.all(16), children: children);

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin dashboard'),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _reload,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Reports'),
              Tab(text: 'Customers'),
              Tab(text: 'Dealers'),
              Tab(text: 'Plumbers'),
              Tab(text: 'Products'),
              Tab(text: 'Orders'),
              Tab(text: 'Payments'),
            ],
          ),
        ),
        body: _loading && data == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && data == null
            ? Padding(
                padding: const EdgeInsets.all(20),
                child: _ErrorBox(message: _error!),
              )
            : data == null
            ? const _AdminEmptyState()
            : Column(
                children: [
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: _ErrorBox(message: _error!),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _section([
                          _reportCards(data.reports),
                          const SizedBox(height: 16),
                          const Text(
                            'Summary uses records currently returned by Zoho '
                            'and the latest 200 locally stored payments.',
                          ),
                        ]),
                        _section([
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: _addCustomer,
                              icon: const Icon(Icons.person_add_alt_1),
                              label: const Text('Add customer'),
                            ),
                          ),
                          ..._records(
                            data.customers,
                            title: 'Customer',
                            subtitle: (record) =>
                                '${record['mobile'] ?? ''}\n${record['status'] ?? ''}',
                            onEdit: _editCustomer,
                          ),
                        ]),
                        _section(
                          _records(
                            data.dealers,
                            title: 'Dealer',
                            subtitle: (record) =>
                                '${record['mobile'] ?? ''} · '
                                '${record['verified'] == true ? 'Verified' : 'Not verified'}\n'
                                'Credit ${_displayValue(record['available_credit'])} · '
                                '${_displayValue(record['payment_terms'])}-day terms',
                            onEdit: _editDealer,
                          ),
                        ),
                        _section([
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              onPressed: () async {
                                final values = await _editDialog(
                                  title: 'Add plumber',
                                  fields: {'Mobile': '', 'Name': ''},
                                );
                                if (values == null) return;
                                await _perform(
                                  () => widget.api.updateAdminPlumber(
                                    token: widget.token,
                                    mobile: values['Mobile']!,
                                    name: values['Name']!,
                                    active: true,
                                  ),
                                );
                              },
                              icon: const Icon(Icons.person_add_alt_1),
                              label: const Text('Add plumber'),
                            ),
                          ),
                          ..._records(
                            data.plumbers,
                            title: 'Plumber',
                            subtitle: (record) =>
                                '${record['mobile'] ?? ''} · '
                                '${record['active'] == true ? 'Approved' : 'Disabled'}\n'
                                '${record['source'] ?? ''}',
                            onEdit: _editPlumber,
                          ),
                        ]),
                        _section(
                          _records(
                            data.products,
                            title: 'Product',
                            subtitle: (record) =>
                                '${record['sku'] ?? ''} · '
                                'Price ${_displayValue(record['price'])} · '
                                'Stock ${_displayValue(record['stock'])}\n'
                                '${record['active'] == true ? 'Active' : 'Inactive'}',
                            onEdit: _editProduct,
                          ),
                        ),
                        _section(
                          _records(
                            data.orders,
                            title: 'Order',
                            subtitle: (record) =>
                                '${record['status'] ?? ''} · '
                                '${_displayValue(record['total'])}\n'
                                'Shipment ${record['shipment_date'] ?? 'not set'}',
                            onEdit: _editShipment,
                          ),
                        ),
                        _section([
                          const Text(
                            'Payment records are managed by Razorpay and '
                            'Zoho. This view is read-only.',
                          ),
                          const SizedBox(height: 12),
                          ..._records(
                            data.payments,
                            title: 'Payment',
                            subtitle: (record) =>
                                '${record['provider'] ?? 'Razorpay'} · '
                                '${record['payment_status'] ?? 'unknown'}\n'
                                '${record['currency'] ?? ''} '
                                '${record['amount'] ?? ''}',
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Pending Razorpay checkouts',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                          ..._records(
                            data.razorpayOrders,
                            title: 'Razorpay checkout',
                            subtitle: (record) =>
                                '${record['status'] ?? ''} · '
                                '${record['currency'] ?? ''} '
                                '${record['amount'] ?? ''}\n'
                                'Zoho order ${record['salesorder_number'] ?? record['salesorder_id'] ?? ''}',
                          ),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _AdminEmptyState extends StatelessWidget {
  const _AdminEmptyState();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text('No records are available in this section yet.'),
    ),
  );
}

class _RoleScreen extends StatelessWidget {
  const _RoleScreen({required this.onSelect});

  final ValueChanged<AppRole> onSelect;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _BrandMark(),
                  const SizedBox(height: 32),
                  Text(
                    'Welcome to\nWaytowebs',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Choose how you use Waytowebs.',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF687572),
                    ),
                  ),
                  const SizedBox(height: 28),
                  for (final role in AppRole.values) ...[
                    _RoleCard(role: role, onTap: () => onSelect(role)),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                  const Center(
                    child: Text(
                      'Secure sign-in with your mobile number',
                      style: TextStyle(color: Color(0xFF75817E), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.role, required this.onTap});

  final AppRole role;
  final VoidCallback onTap;

  IconData get _icon => switch (role) {
    AppRole.customer => Icons.shopping_bag_outlined,
    AppRole.dealer => Icons.storefront_outlined,
    AppRole.plumber => Icons.plumbing_outlined,
    AppRole.admin => Icons.admin_panel_settings_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F4F1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(_icon, color: const Color(0xFF087E78)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      role.description,
                      style: const TextStyle(
                        color: Color(0xFF75817E),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF75817E)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileScreen extends StatelessWidget {
  const _MobileScreen({
    required this.role,
    required this.controller,
    required this.nameController,
    required this.customerMode,
    required this.busy,
    required this.error,
    required this.onBack,
    required this.onContinue,
    required this.onCustomerModeChanged,
  });

  final AppRole role;
  final TextEditingController controller;
  final TextEditingController nameController;
  final _CustomerMode customerMode;
  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onContinue;
  final ValueChanged<_CustomerMode> onCustomerModeChanged;

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Your mobile number',
      subtitle: 'We’ll use it to sign you in as a ${role.label.toLowerCase()}.',
      onBack: onBack,
      error: error,
      children: [
        if (role == AppRole.customer) ...[
          SegmentedButton<_CustomerMode>(
            segments: const [
              ButtonSegment(
                value: _CustomerMode.signIn,
                label: Text('Sign in'),
              ),
              ButtonSegment(
                value: _CustomerMode.register,
                label: Text('Create account'),
              ),
            ],
            selected: {customerMode},
            onSelectionChanged: busy
                ? null
                : (selection) => onCustomerModeChanged(selection.first),
          ),
          const SizedBox(height: 18),
          if (customerMode == _CustomerMode.register) ...[
            const Text(
              'Your name',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(hintText: 'Full name'),
            ),
            const SizedBox(height: 16),
          ],
        ],
        const Text(
          'Mobile number',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.phone,
          maxLength: 10,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            counterText: '',
            prefixText: '+91  ',
            hintText: '10-digit mobile number',
          ),
          onSubmitted: (_) {
            if (!busy) onContinue();
          },
        ),
        if (role == AppRole.dealer) ...[
          const SizedBox(height: 14),
          const _InfoBox(
            icon: Icons.verified_user_outlined,
            text:
                'Dealer access is checked against the verified Zoho contact before a code is issued.',
          ),
        ],
        if (role == AppRole.plumber) ...[
          const SizedBox(height: 14),
          const _InfoBox(
            icon: Icons.admin_panel_settings_outlined,
            text: 'Only admin-approved plumbers can request a sign-in code.',
          ),
        ],
        const SizedBox(height: 22),
        _PrimaryButton(label: 'Continue', busy: busy, onPressed: onContinue),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            'No password needed',
            style: TextStyle(color: Color(0xFF75817E), fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _OtpScreen extends StatelessWidget {
  const _OtpScreen({
    required this.role,
    required this.mobile,
    required this.controller,
    required this.busy,
    required this.error,
    required this.onBack,
    required this.onVerify,
    required this.onResend,
  });

  final AppRole role;
  final String mobile;
  final TextEditingController controller;
  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onVerify;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Enter your code',
      subtitle: 'A 6-digit code was requested for +91 $mobile.',
      onBack: onBack,
      error: error,
      children: [
        const _InfoBox(
          icon: Icons.sms_outlined,
          text:
              'Enter the code sent by Firebase. For interview testing, use the configured Firebase test phone number and code; test numbers do not receive SMS.',
        ),
        const SizedBox(height: 20),
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            letterSpacing: 12,
            fontWeight: FontWeight.w700,
          ),
          decoration: const InputDecoration(
            counterText: '',
            hintText: '• • • • • •',
          ),
          onSubmitted: (_) {
            if (!busy) onVerify();
          },
        ),
        const SizedBox(height: 20),
        _PrimaryButton(
          label: 'Verify and view products',
          busy: busy,
          onPressed: onVerify,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: busy ? null : onResend,
          child: const Text('Request a new code'),
        ),
        if (role == AppRole.dealer)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Your Zoho dealer verification was completed before this code was issued.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF75817E), fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _CustomerRegistrationScreen extends StatelessWidget {
  const _CustomerRegistrationScreen({
    required this.controller,
    required this.mobile,
    required this.busy,
    required this.error,
    required this.onBack,
    required this.onContinue,
  });

  final TextEditingController controller;
  final String mobile;
  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return _AuthScaffold(
      title: 'Complete your account',
      subtitle: 'Verified number: +91 $mobile',
      onBack: onBack,
      error: error,
      children: [
        const Text('Your name', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: 'Full name'),
          onSubmitted: (_) {
            if (!busy) onContinue();
          },
        ),
        const SizedBox(height: 22),
        _PrimaryButton(
          label: 'Create customer account',
          busy: busy,
          onPressed: onContinue,
        ),
      ],
    );
  }
}

class _ProductsScreen extends StatelessWidget {
  const _ProductsScreen({
    required this.role,
    required this.products,
    required this.api,
    required this.token,
    required this.query,
    required this.category,
    required this.busy,
    required this.error,
    required this.onQueryChanged,
    required this.onCategoryChanged,
    required this.onRefresh,
    required this.onSignOut,
  });

  final AppRole role;
  final List<Product> products;
  final BackendApi api;
  final String token;
  final String query;
  final String category;
  final bool busy;
  final String? error;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onCategoryChanged;
  final Future<void> Function() onRefresh;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final categories = <String>{
      'All',
      ...products.map((product) => product.category),
    }.toList();
    final visibleProducts = products.where((product) {
      final matchesCategory = category == 'All' || product.category == category;
      final search = query.trim().toLowerCase();
      final matchesQuery =
          search.isEmpty ||
          product.name.toLowerCase().contains(search) ||
          product.sku.toLowerCase().contains(search);
      return matchesCategory && matchesQuery;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const _BrandMark(compact: true),
        actions: [
          if (role != AppRole.plumber)
            IconButton(
              tooltip: 'Shopping cart',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      _CartScreen(api: api, token: token, role: role),
                ),
              ),
              icon: const Icon(Icons.shopping_cart_outlined),
            ),
          IconButton(
            tooltip: 'Refresh products',
            onPressed: busy ? null : onRefresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: onSignOut,
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          switch (role) {
                            AppRole.customer => 'Find what you need',
                            AppRole.dealer => 'Dealer catalogue',
                            AppRole.plumber => 'Product catalogue',
                            AppRole.admin => 'Product catalogue',
                          },
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      _RoleBadge(role: role),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${products.length} products from Zoho Inventory',
                    style: const TextStyle(color: Color(0xFF75817E)),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    onChanged: onQueryChanged,
                    decoration: const InputDecoration(
                      hintText: 'Search by product or SKU',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: categories.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final item = categories[index];
                        return ChoiceChip(
                          label: Text(item),
                          selected: item == category,
                          onSelected: (_) => onCategoryChanged(item),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _ErrorBox(message: error!),
              ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: visibleProducts.isEmpty && !busy
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          products.isEmpty
                              ? 'No products were returned from Zoho.'
                              : 'No products match your search.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFF75817E)),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      itemCount: visibleProducts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final product = visibleProducts[index];
                        return _ProductCard(
                          product: product,
                          role: role,
                          imageUrl: api.productImageUri(product.id).toString(),
                          imageHeaders: api.productImageHeaders(token),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _ProductDetailsScreen(
                                product: product,
                                role: role,
                                api: api,
                                token: token,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({
    required this.product,
    required this.role,
    required this.imageUrl,
    required this.imageHeaders,
    required this.onTap,
  });

  final Product product;
  final AppRole role;
  final String imageUrl;
  final Map<String, String> imageHeaders;
  final VoidCallback onTap;

  String _money(double? amount) =>
      amount == null ? 'Price unavailable' : '₹${amount.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final isDealer = role == AppRole.dealer;
    final price = isDealer ? product.retailPrice : product.price;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE8ECEA)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ProductImage(
                imageUrl: imageUrl,
                headers: imageHeaders,
                available: product.imageAvailable,
                width: 64,
                height: 64,
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${product.sku.isEmpty ? 'No SKU' : product.sku} · ${product.category}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF75817E),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (isDealer && product.retailPrice != null)
                      Text(
                        'Retail ${_money(product.retailPrice)}',
                        style: const TextStyle(
                          color: Color(0xFF75817E),
                          fontSize: 12,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    Text(
                      isDealer
                          ? 'Dealer ${_money(product.price ?? product.retailPrice)}'
                          : _money(price),
                      style: const TextStyle(
                        color: Color(0xFF087E78),
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 7),
                    _Availability(product: product, isDealer: isDealer),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Color(0xFF75817E)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductDetailsScreen extends StatefulWidget {
  const _ProductDetailsScreen({
    required this.product,
    required this.role,
    required this.api,
    required this.token,
  });

  final Product product;
  final AppRole role;
  final BackendApi api;
  final String token;

  @override
  State<_ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<_ProductDetailsScreen> {
  bool _addingToCart = false;
  String? _error;

  String _money(double? amount) =>
      amount == null ? 'Price unavailable' : '₹${amount.toStringAsFixed(2)}';

  Future<void> _addToCart() async {
    if (kDebugMode) {
      debugPrint(
        '[cart] Add button tapped for product ${widget.product.id} '
        '(${widget.product.name}).',
      );
    }
    setState(() {
      _addingToCart = true;
      _error = null;
    });
    try {
      if (kDebugMode) debugPrint('[cart] Loading current cart.');
      final cart = await widget.api.getCart(
        token: widget.token,
        role: widget.role,
      );
      if (kDebugMode) {
        debugPrint('[cart] Current cart has ${cart.items.length} item(s).');
      }
      final existing = cart.items.where(
        (line) => line.productId == widget.product.id,
      );
      final quantity = existing.isEmpty ? 1.0 : existing.first.quantity + 1;
      final updatedItems = [
        ...cart.items.where((line) => line.productId != widget.product.id),
        CartLine(
          productId: widget.product.id,
          name: widget.product.name,
          sku: widget.product.sku,
          category: widget.product.category,
          quantity: quantity,
          unitPrice: widget.product.price ?? 0,
          lineTotal: quantity * (widget.product.price ?? 0),
          stock: widget.product.stock,
          inStock: widget.product.inStock,
        ),
      ];
      if (kDebugMode) {
        debugPrint(
          '[cart] Saving ${updatedItems.length} item(s); '
          'product ${widget.product.id} quantity $quantity.',
        );
      }
      await widget.api.updateCart(token: widget.token, items: updatedItems);
      if (kDebugMode) debugPrint('[cart] Cart update succeeded.');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _CartScreen(
            api: widget.api,
            token: widget.token,
            role: widget.role,
          ),
        ),
      );
    } on BackendApiException catch (error) {
      if (kDebugMode) debugPrint('[cart] Add failed: ${error.message}');
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _addingToCart = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final product = widget.product;
    final role = widget.role;
    final isDealer = role == AppRole.dealer;
    final price = isDealer
        ? product.price ?? product.retailPrice
        : product.price;
    final inStock = isDealer
        ? (product.stock ?? 0) > 0
        : product.inStock ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Product details')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _ProductImage(
              imageUrl: widget.api.productImageUri(product.id).toString(),
              headers: widget.api.productImageHeaders(widget.token),
              available: product.imageAvailable,
              width: double.infinity,
              height: 220,
              radius: 24,
            ),
            const SizedBox(height: 24),
            Text(
              product.name,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              product.category,
              style: const TextStyle(color: Color(0xFF75817E)),
            ),
            const SizedBox(height: 20),
            _ProductDetailRow(
              label: 'SKU',
              value: product.sku.isEmpty ? 'Not available' : product.sku,
            ),
            _ProductDetailRow(
              label: isDealer ? 'Dealer price' : 'Price',
              value: _money(price),
            ),
            if (isDealer && product.retailPrice != null)
              _ProductDetailRow(
                label: 'Retail price',
                value: _money(product.retailPrice),
              ),
            _ProductDetailRow(
              label: 'Availability',
              value: inStock ? 'In stock' : 'Out of stock',
            ),
            if (product.description.isNotEmpty)
              _ProductDetailRow(
                label: 'Description',
                value: product.description,
              ),
            if (product.brand.isNotEmpty)
              _ProductDetailRow(label: 'Brand', value: product.brand),
            if (product.manufacturer.isNotEmpty)
              _ProductDetailRow(
                label: 'Manufacturer',
                value: product.manufacturer,
              ),
            if (product.unit.isNotEmpty)
              _ProductDetailRow(label: 'Unit', value: product.unit),
            if (product.weight.isNotEmpty)
              _ProductDetailRow(label: 'Weight', value: product.weight),
            if (product.dimensions.isNotEmpty)
              _ProductDetailRow(label: 'Dimensions', value: product.dimensions),
            if (isDealer)
              _ProductDetailRow(
                label: 'Stock quantity',
                value: '${product.stock ?? 0}',
              ),
          ],
        ),
      ),
      bottomNavigationBar: role == AppRole.plumber
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error != null) ...[
                      _ErrorBox(message: _error!),
                      const SizedBox(height: 10),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _addingToCart || !inStock
                            ? null
                            : _addToCart,
                        icon: _addingToCart
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_shopping_cart),
                        label: Text(inStock ? 'Add to cart' : 'Out of stock'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ProductImage extends StatelessWidget {
  const _ProductImage({
    required this.imageUrl,
    required this.headers,
    required this.available,
    required this.width,
    required this.height,
    this.radius = 15,
  });

  final String imageUrl;
  final Map<String, String> headers;
  final bool available;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F4F1),
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.inventory_2_outlined,
        size: 46,
        color: Color(0xFF087E78),
      ),
    );

    if (!available) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        imageUrl,
        width: width,
        height: height,
        fit: BoxFit.contain,
        headers: headers,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : SizedBox(
                width: width,
                height: height,
                child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
      ),
    );
  }
}

class _ProductDetailRow extends StatelessWidget {
  const _ProductDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF75817E)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _CartScreen extends StatefulWidget {
  const _CartScreen({
    required this.api,
    required this.token,
    required this.role,
  });

  final BackendApi api;
  final String token;
  final AppRole role;

  @override
  State<_CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<_CartScreen> {
  CartData? _cart;
  String? _error;
  bool _loading = true;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _loadCart();
  }

  Future<void> _loadCart() async {
    try {
      final cart = await widget.api.getCart(
        token: widget.token,
        role: widget.role,
      );
      if (mounted) {
        setState(() {
          _cart = cart;
          _error = null;
        });
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setQuantity(CartLine line, double quantity) async {
    final cart = _cart;
    if (cart == null) return;
    final items = cart.items
        .where((item) => item.productId != line.productId)
        .toList(growable: false);
    final updated = quantity <= 0
        ? items
        : [
            ...items,
            CartLine(
              productId: line.productId,
              name: line.name,
              sku: line.sku,
              category: line.category,
              quantity: quantity,
              unitPrice: line.unitPrice,
              lineTotal: line.unitPrice * quantity,
              stock: line.stock,
              inStock: line.inStock,
            ),
          ];
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      await widget.api.updateCart(token: widget.token, items: updated);
      await _loadCart();
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  String _money(double amount) => '₹${amount.toStringAsFixed(2)}';

  String _quantity(double quantity) => quantity == quantity.truncateToDouble()
      ? quantity.toInt().toString()
      : quantity.toString();

  @override
  Widget build(BuildContext context) {
    final cart = _cart;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your cart'),
        actions: [
          IconButton(
            tooltip: 'Track orders',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    _OrdersScreen(api: widget.api, token: widget.token),
              ),
            ),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && cart == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _ErrorBox(message: _error!),
              ),
            )
          : cart == null || cart.items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.shopping_cart_outlined,
                      size: 52,
                      color: Color(0xFF8A9693),
                    ),
                    const SizedBox(height: 12),
                    const Text('Your cart is empty'),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Continue shopping'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _ErrorBox(message: _error!),
                  ),
                if (_updating) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: cart.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final line = cart.items[index];
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE8ECEA)),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.inventory_2_outlined,
                              color: Color(0xFF087E78),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${_money(line.unitPrice)} each · ${_money(line.lineTotal)}',
                                    style: const TextStyle(
                                      color: Color(0xFF687572),
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (widget.role == AppRole.dealer)
                                    Text(
                                      '${line.stock ?? 0} available',
                                      style: const TextStyle(
                                        color: Color(0xFF687572),
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove one',
                              onPressed: _updating
                                  ? null
                                  : () => _setQuantity(line, line.quantity - 1),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            Text(_quantity(line.quantity)),
                            IconButton(
                              tooltip: 'Add one',
                              onPressed: _updating
                                  ? null
                                  : () => _setQuantity(line, line.quantity + 1),
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('Subtotal')),
                            Text(
                              _money(cart.subtotal),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _updating
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => _CheckoutScreen(
                                        api: widget.api,
                                        token: widget.token,
                                        role: widget.role,
                                      ),
                                    ),
                                  ),
                            child: const Text('Continue to checkout'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _CheckoutScreen extends StatefulWidget {
  const _CheckoutScreen({
    required this.api,
    required this.token,
    required this.role,
  });

  final BackendApi api;
  final String token;
  final AppRole role;

  @override
  State<_CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<_CheckoutScreen> {
  late final Razorpay _razorpay;
  CartData? _cart;
  DealerCredit? _dealerCredit;
  ZohoOrder? _order;
  RazorpayCheckout? _pendingCheckout;
  String _paymentMethod = 'direct';
  int? _creditTermDays;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay()
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, _handleRazorpaySuccess)
      ..on(Razorpay.EVENT_PAYMENT_ERROR, _handleRazorpayFailure)
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
    if (widget.role == AppRole.dealer) _paymentMethod = 'upfront';
    _loadCheckout();
  }

  @override
  void dispose() {
    _razorpay.clear();
    super.dispose();
  }

  void _handleRazorpaySuccess(PaymentSuccessResponse response) {
    final checkout = _pendingCheckout;
    final paymentId = response.paymentId;
    final orderId = response.orderId;
    final signature = response.signature;
    if (checkout == null ||
        paymentId == null ||
        orderId != checkout.orderId ||
        signature == null) {
      if (mounted) {
        setState(() {
          _error =
              'Razorpay returned incomplete payment details. '
              'Please contact support before trying to pay again.';
          _submitting = false;
        });
      }
      return;
    }
    _confirmRazorpayPayment(
      checkout: checkout,
      paymentId: paymentId,
      signature: signature,
    );
  }

  Future<void> _confirmRazorpayPayment({
    required RazorpayCheckout checkout,
    required String paymentId,
    required String signature,
  }) async {
    try {
      final order = await widget.api.verifyRazorpayPayment(
        token: widget.token,
        orderId: checkout.orderId,
        paymentId: paymentId,
        signature: signature,
      );
      if (mounted) {
        setState(() {
          _order = order;
          _pendingCheckout = null;
          _error = null;
        });
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _handleRazorpayFailure(PaymentFailureResponse response) {
    if (kDebugMode) {
      debugPrint(
        '[payment] Razorpay checkout failed (${response.code}): '
        '${response.message ?? 'No error message'}',
      );
    }
    if (mounted) {
      setState(() {
        _pendingCheckout = null;
        _submitting = false;
        _error = response.message ?? 'Razorpay could not complete the payment.';
      });
    }
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    if (kDebugMode) {
      debugPrint(
        '[payment] Razorpay external wallet selected: '
        '${response.walletName ?? 'unknown'}',
      );
    }
  }

  Future<void> _loadCheckout() async {
    try {
      final cart = await widget.api.getCart(
        token: widget.token,
        role: widget.role,
      );
      final credit = widget.role == AppRole.dealer
          ? await widget.api.getDealerCredit(token: widget.token)
          : null;
      if (mounted) {
        final terms = credit?.enabledTerms ?? const <int>[];
        setState(() {
          _cart = cart;
          _dealerCredit = credit;
          _creditTermDays = terms.isEmpty ? null : terms.first;
          _error = null;
        });
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _placeOrder() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    var waitingForPaymentCallback = false;
    try {
      final idempotencyKey =
          '${DateTime.now().microsecondsSinceEpoch}-${UniqueKey().hashCode}';
      if (_paymentMethod == 'credit') {
        final order = await widget.api.createOrder(
          token: widget.token,
          idempotencyKey: idempotencyKey,
          paymentMethod: _paymentMethod,
          creditTermDays: _creditTermDays,
        );
        if (mounted) setState(() => _order = order);
      } else {
        final checkout = await widget.api.createRazorpayCheckout(
          token: widget.token,
          idempotencyKey: idempotencyKey,
        );
        _pendingCheckout = checkout;
        waitingForPaymentCallback = true;
        _razorpay.open({
          'key': checkout.keyId,
          'order_id': checkout.orderId,
          'amount': checkout.amount,
          'currency': checkout.currency,
          'name': 'Waytowebs',
          'description': 'Order ${checkout.order.number}',
          'theme': {'color': '#087E78'},
        });
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted && !waitingForPaymentCallback) {
        setState(() => _submitting = false);
      }
    }
  }

  String _money(double? amount) =>
      amount == null ? 'Calculated by Zoho' : '₹${amount.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final cart = _cart;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Checkout')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (order != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Order confirmation')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: Color(0xFF087E78),
                ),
                const SizedBox(height: 16),
                Text(
                  'Order sent to Zoho',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Order ${order.number} · ${order.status}\n'
                  'Total: ${_money(order.total)}\n'
                  '${order.paymentStatus == 'paid' ? 'Payment captured by Razorpay.' : 'Payment is pending under your approved credit terms.'}',
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          _OrdersScreen(api: widget.api, token: widget.token),
                    ),
                  ),
                  child: const Text('Track orders'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
                  child: const Text('Back to catalogue'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: _error != null && cart == null
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: _ErrorBox(message: _error!),
            )
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        if (_error != null) ...[
                          _ErrorBox(message: _error!),
                          const SizedBox(height: 16),
                        ],
                        const Text(
                          'Order summary',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final item in cart?.items ?? const [])
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.name),
                            subtitle: Text(
                              '${item.quantity} × ${_money(item.unitPrice)}',
                            ),
                            trailing: Text(_money(item.lineTotal)),
                          ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Subtotal'),
                          trailing: Text(_money(cart?.subtotal)),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Payment option',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (widget.role == AppRole.customer)
                          const ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('Direct payment'),
                            subtitle: Text(
                              'Pay securely with Razorpay. Your order is sent '
                              'to Zoho after payment verification.',
                            ),
                          )
                        else
                          RadioGroup<String>(
                            groupValue: _paymentMethod,
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _paymentMethod = value);
                              }
                            },
                            child: Column(
                              children: [
                                const RadioListTile<String>(
                                  contentPadding: EdgeInsets.zero,
                                  value: 'upfront',
                                  title: Text('Upfront payment'),
                                  subtitle: Text('Pay securely with Razorpay.'),
                                ),
                                if (_dealerCredit?.enabledTerms.isNotEmpty ==
                                    true)
                                  RadioListTile<String>(
                                    contentPadding: EdgeInsets.zero,
                                    value: 'credit',
                                    title: const Text('Zoho-approved credit'),
                                    subtitle: Text(
                                      'Enabled for ${_dealerCredit!.enabledTerms.first} days',
                                    ),
                                  )
                                else
                                  const ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('Credit payment'),
                                    subtitle: Text(
                                      'No 30- or 90-day term is enabled in Zoho.',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (_paymentMethod == 'credit' && _dealerCredit != null)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('Available credit'),
                            trailing: Text(
                              _money(_dealerCredit!.availableCredit),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed:
                              _submitting || (cart?.items.isEmpty ?? true)
                              ? null
                              : _placeOrder,
                          child: _submitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _paymentMethod == 'credit'
                                      ? 'Create credit order in Zoho'
                                      : 'Pay with Razorpay',
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _OrdersScreen extends StatefulWidget {
  const _OrdersScreen({required this.api, required this.token});

  final BackendApi api;
  final String token;

  @override
  State<_OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<_OrdersScreen> {
  List<OrderRecord> _orders = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    try {
      final orders = await widget.api.getOrders(token: widget.token);
      if (mounted) {
        setState(() {
          _orders = orders;
          _error = null;
        });
      }
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order tracking'),
        actions: [
          IconButton(
            tooltip: 'Refresh orders',
            onPressed: _loading ? null : _loadOrders,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: _ErrorBox(message: _error!),
            )
          : _orders.isEmpty
          ? const Center(child: Text('No Zoho orders yet'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final order = _orders[index];
                final tracking = order.packages
                    .map((item) => item['tracking_number'])
                    .whereType<String>()
                    .where((number) => number.isNotEmpty)
                    .join(', ');
                return Card(
                  child: ListTile(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _OrderTrackingDetailScreen(
                          api: widget.api,
                          token: widget.token,
                          orderId: order.id,
                        ),
                      ),
                    ),
                    leading: const Icon(
                      Icons.local_shipping_outlined,
                      color: Color(0xFF087E78),
                    ),
                    title: Text(order.number.isEmpty ? order.id : order.number),
                    subtitle: Text(
                      'Status: ${order.status}'
                      '${order.shipmentDate.isEmpty ? '' : '\nShipment: ${order.shipmentDate}'}'
                      '${tracking.isEmpty ? '' : '\nTracking: $tracking'}',
                    ),
                    isThreeLine:
                        tracking.isNotEmpty || order.shipmentDate.isNotEmpty,
                    trailing: order.total == null
                        ? null
                        : Text('₹${order.total!.toStringAsFixed(2)}'),
                  ),
                );
              },
            ),
    );
  }
}

class _OrderTrackingDetailScreen extends StatefulWidget {
  const _OrderTrackingDetailScreen({
    required this.api,
    required this.token,
    required this.orderId,
  });

  final BackendApi api;
  final String token;
  final String orderId;

  @override
  State<_OrderTrackingDetailScreen> createState() =>
      _OrderTrackingDetailScreenState();
}

class _OrderTrackingDetailScreenState
    extends State<_OrderTrackingDetailScreen> {
  OrderRecord? _order;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadOrder();
  }

  Future<void> _loadOrder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final order = await widget.api.getOrder(
        token: widget.token,
        orderId: widget.orderId,
      );
      if (mounted) setState(() => _order = order);
    } on BackendApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _label(String value) => value
      .replaceAll('_', ' ')
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');

  String _date(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value.isEmpty ? 'Not available' : value;
    return MaterialLocalizations.of(context).formatMediumDate(parsed.toLocal());
  }

  bool get _isVoided {
    final status = _order?.status.toLowerCase() ?? '';
    return status.contains('void') || status.contains('cancel');
  }

  bool get _isShipped {
    final order = _order;
    if (order == null) return false;
    final status = order.status.toLowerCase();
    return order.shipmentDate.isNotEmpty ||
        order.packages.isNotEmpty ||
        status.contains('ship') ||
        status.contains('deliver');
  }

  bool get _isDelivered {
    final order = _order;
    if (order == null) return false;
    final orderStatus = order.status.toLowerCase();
    return orderStatus.contains('deliver') ||
        order.packages.any(
          (package) =>
              '${package['status'] ?? package['delivery_status'] ?? ''}'
                  .toLowerCase()
                  .contains('deliver'),
        );
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order tracking'),
        actions: [
          IconButton(
            tooltip: 'Refresh tracking',
            onPressed: _loading ? null : _loadOrder,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: _ErrorBox(message: _error!),
            )
          : order == null
          ? const Center(child: Text('Order details are unavailable.'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  order.number.isEmpty ? 'Order ${order.id}' : order.number,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Current Zoho status: ${_label(order.status)}',
                  style: const TextStyle(color: Color(0xFF75817E)),
                ),
                if (order.total != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Order total'),
                    trailing: Text('₹${order.total!.toStringAsFixed(2)}'),
                  ),
                const SizedBox(height: 20),
                const Text(
                  'Shipment progress',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 16),
                _TrackingStep(
                  title: _isVoided ? 'Order cancelled' : 'Order placed',
                  detail: _isVoided
                      ? 'Zoho status: ${_label(order.status)}'
                      : _date(order.date),
                  complete: true,
                  last: false,
                  cancelled: _isVoided,
                ),
                _TrackingStep(
                  title: 'Processing',
                  detail: _isVoided
                      ? 'This order will not proceed.'
                      : 'Zoho status: ${_label(order.status)}',
                  complete: !_isVoided,
                  last: false,
                  cancelled: false,
                ),
                _TrackingStep(
                  title: 'Shipped',
                  detail: order.shipmentDate.isNotEmpty
                      ? _date(order.shipmentDate)
                      : _isShipped
                      ? 'Shipment recorded by Zoho'
                      : 'Shipment information not available yet',
                  complete: _isShipped && !_isVoided,
                  last: false,
                  cancelled: false,
                ),
                _TrackingStep(
                  title: 'Delivered',
                  detail: _isDelivered
                      ? 'Delivery recorded by Zoho'
                      : 'Delivery status not provided by Zoho yet',
                  complete: _isDelivered && !_isVoided,
                  last: true,
                  cancelled: false,
                ),
                const SizedBox(height: 18),
                Text(
                  'Estimated arrival: Not provided by Zoho yet.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF75817E),
                  ),
                ),
                for (final package in order.packages) ...[
                  const SizedBox(height: 12),
                  _ShipmentPackageCard(package: package),
                ],
                if (order.lineItems.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Items in this order',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  for (final item in order.lineItems)
                    _OrderItemTile(
                      item: item,
                      api: widget.api,
                      token: widget.token,
                    ),
                ],
              ],
            ),
    );
  }
}

class _OrderItemTile extends StatelessWidget {
  const _OrderItemTile({
    required this.item,
    required this.api,
    required this.token,
  });

  final Map<String, dynamic> item;
  final BackendApi api;
  final String token;

  @override
  Widget build(BuildContext context) {
    final productId = '${item['item_id'] ?? item['product_id'] ?? ''}';
    final hasProductId = RegExp(r'^\d+$').hasMatch(productId);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _ProductImage(
        imageUrl: api.productImageUri(productId).toString(),
        headers: api.productImageHeaders(token),
        available: hasProductId,
        width: 60,
        height: 60,
      ),
      title: Text('${item['name'] ?? item['item_name'] ?? 'Product'}'),
      subtitle: Text('Quantity: ${item['quantity'] ?? '-'}'),
    );
  }
}

class _TrackingStep extends StatelessWidget {
  const _TrackingStep({
    required this.title,
    required this.detail,
    required this.complete,
    required this.last,
    required this.cancelled,
  });

  final String title;
  final String detail;
  final bool complete;
  final bool last;
  final bool cancelled;

  @override
  Widget build(BuildContext context) {
    final color = cancelled
        ? const Color(0xFFB3261E)
        : complete
        ? const Color(0xFF087E78)
        : const Color(0xFFB8C1BE);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Icon(
                  cancelled
                      ? Icons.cancel_outlined
                      : complete
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: color,
                  size: 22,
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: complete
                          ? const Color(0xFF087E78)
                          : const Color(0xFFE1E7E4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    style: const TextStyle(color: Color(0xFF75817E)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShipmentPackageCard extends StatelessWidget {
  const _ShipmentPackageCard({required this.package});

  final Map<String, dynamic> package;

  @override
  Widget build(BuildContext context) {
    final trackingNumber = package['tracking_number'];
    final carrier = package['delivery_method'] ?? package['carrier'];
    final shipmentDate = package['shipment_date'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shipment details',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            if (carrier is String && carrier.isNotEmpty)
              Text('Carrier: $carrier'),
            if (trackingNumber is String && trackingNumber.isNotEmpty)
              SelectableText('Tracking number: $trackingNumber'),
            if (shipmentDate is String && shipmentDate.isNotEmpty)
              Text('Shipment date: $shipmentDate'),
          ],
        ),
      ),
    );
  }
}

class _Availability extends StatelessWidget {
  const _Availability({required this.product, required this.isDealer});

  final Product product;
  final bool isDealer;

  @override
  Widget build(BuildContext context) {
    final inStock = isDealer
        ? (product.stock ?? 0) > 0
        : product.inStock ?? false;
    final text = isDealer
        ? '${product.stock ?? 0} in stock'
        : inStock
        ? 'In stock'
        : 'Out of stock';
    return Row(
      children: [
        Icon(
          inStock ? Icons.check_circle : Icons.remove_circle_outline,
          size: 15,
          color: inStock ? const Color(0xFF39856A) : const Color(0xFF9A6A44),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: inStock ? const Color(0xFF39856A) : const Color(0xFF9A6A44),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.children,
    this.error,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final List<Widget> children;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const _BrandMark(compact: true),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF687572),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 26),
                  if (error != null) ...[
                    _ErrorBox(message: error!),
                    const SizedBox(height: 16),
                  ],
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF087E78),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 21,
                height: 21,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 34 : 46,
          height: compact ? 34 : 46,
          decoration: BoxDecoration(
            color: const Color(0xFF087E78),
            borderRadius: BorderRadius.circular(compact ? 11 : 15),
          ),
          alignment: Alignment.center,
          child: Text(
            'W',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: compact ? 18 : 24,
            ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 11),
          const Text(
            'WAYTOWEBS',
            style: TextStyle(
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
              color: Color(0xFF24403C),
            ),
          ),
        ],
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});

  final AppRole role;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE8F4F1),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Text(
          role.label,
          style: const TextStyle(
            color: Color(0xFF087E78),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4F2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: const Color(0xFF087E78)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF365C56),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEFED),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFF9D352B), height: 1.35),
      ),
    );
  }
}
