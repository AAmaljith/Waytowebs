import 'package:firebase_auth/firebase_auth.dart';

class PhoneAuthService {
  PhoneAuthService({FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  String? _verificationId;

  Future<void> sendOtp({
    required String phoneNumber,
    required void Function() onCodeSent,
    required void Function(UserCredential credential) onVerificationCompleted,
    required void Function(String message) onError,
  }) {
    return _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (credential) async {
        try {
          final result = await _auth.signInWithCredential(credential);
          onVerificationCompleted(result);
        } on FirebaseAuthException catch (error) {
          onError(error.message ?? 'Phone verification failed.');
        }
      },
      verificationFailed: (error) {
        onError(error.message ?? 'Phone verification failed.');
      },
      codeSent: (verificationId, _) {
        _verificationId = verificationId;
        onCodeSent();
      },
      codeAutoRetrievalTimeout: (verificationId) {
        _verificationId = verificationId;
      },
    );
  }

  Future<UserCredential> verifyOtp(String code) async {
    final verificationId = _verificationId;
    if (verificationId == null) {
      throw FirebaseAuthException(
        code: 'missing-verification-id',
        message: 'Request a new verification code and try again.',
      );
    }
    final credential = PhoneAuthProvider.credential(
      verificationId: verificationId,
      smsCode: code,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<void> signOut() => _auth.signOut();
}
