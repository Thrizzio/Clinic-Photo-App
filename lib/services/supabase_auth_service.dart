import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import 'config_service.dart';

/// Service managing Supabase authentication for clinic staff / doctor.
///
/// Ensures all reads and writes to `patients` and `patient_sources` occur under
/// an authenticated Supabase user session, satisfying PostgreSQL Row-Level Security (RLS).
class SupabaseAuthService {
  final SupabaseClient client;
  final ConfigService? configService;

  SupabaseAuthService({
    required this.client,
    this.configService,
  });

  /// True if a user is currently authenticated with a valid session.
  bool get isAuthenticated =>
      client.auth.currentUser != null && client.auth.currentSession != null;

  /// The currently authenticated Supabase user, or null.
  User? get currentUser => client.auth.currentUser;

  /// The email of the currently authenticated user, or null.
  String? get currentEmail => client.auth.currentUser?.email;

  /// Stream of authentication state changes.
  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  /// Signs in to Supabase using a Google ID token obtained from Google Sign-In.
  ///
  /// Verifies that Supabase establishes an authenticated session and currentUser.
  /// Fails explicitly if the session cannot be created.
  Future<AuthResponse> signInWithGoogle({
    required String idToken,
    String? accessToken,
  }) async {
    final response = await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );

    if (response.session == null || response.user == null) {
      throw const AuthException('Failed to establish Supabase session with Google credentials.');
    }

    debugPrint('SupabaseAuthService: Successfully authenticated via Google ID token as ${response.user?.email} (${response.user?.id})');
    return response;
  }

  /// Signs in an existing clinic doctor account with email and password.
  @Deprecated('Obsolete password-based authentication. Use signInWithGoogle().')
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final response = await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );

    if (response.session != null && configService != null) {
      // ignore: deprecated_member_use_from_same_package
      await configService!.setDoctorEmail(email.trim());
      // ignore: deprecated_member_use_from_same_package
      await configService!.setDoctorPassword(password);
    }

    return response;
  }

  /// Registers a new clinic doctor account with email and password.
  /// (Supabase PostgreSQL auto-confirms the email immediately).
  @Deprecated('Obsolete password-based authentication. Use signInWithGoogle().')
  Future<AuthResponse> signUp({
    required String email,
    required String password,
  }) async {
    final response = await client.auth.signUp(
      email: email.trim(),
      password: password,
    );

    // If session is already created by signup
    if (response.session != null && configService != null) {
      // ignore: deprecated_member_use_from_same_package
      await configService!.setDoctorEmail(email.trim());
      // ignore: deprecated_member_use_from_same_package
      await configService!.setDoctorPassword(password);
      return response;
    }

    // Otherwise, immediately sign in with the new credentials
    return signIn(email: email, password: password);
  }

  /// Signs out the current Supabase user.
  Future<void> signOut() async {
    await client.auth.signOut();
  }

  /// Automatically ensures the doctor is authenticated.
  ///
  /// 1. If an active session is already loaded by FlutterAuthStorage, returns true.
  /// 2. If stored credentials exist in ConfigService, attempts sign-in with those.
  /// 3. Otherwise, signs in or registers using default clinic credentials from AppConfig.
  @Deprecated('Obsolete password-based authentication. Use signInWithGoogle().')
  Future<bool> ensureAuthenticated() async {
    if (isAuthenticated) {
      return true;
    }

    // Try credentials from ConfigService or AppConfig defaults
    final email = configService?.getDoctorEmail() ?? AppConfig.defaultDoctorEmail;
    final password = configService?.getDoctorPassword() ?? AppConfig.defaultDoctorPassword;

    if (email.isEmpty || password.isEmpty) {
      return false;
    }

    try {
      final res = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (res.session != null) {
        debugPrint('SupabaseAuthService: Successfully authenticated as $email');
        return true;
      }
    } catch (signInErr) {
      debugPrint('SupabaseAuthService: signInWithPassword notice ($email): $signInErr');
      // If user does not exist yet in Supabase, auto-register once
      try {
        final upRes = await client.auth.signUp(
          email: email,
          password: password,
        );
        if (upRes.session != null) {
          debugPrint('SupabaseAuthService: Auto-registered and authenticated as $email');
          return true;
        }
        // If signUp succeeded without immediate session, sign in now
        final retryIn = await client.auth.signInWithPassword(
          email: email,
          password: password,
        );
        return retryIn.session != null;
      } catch (signUpErr) {
        debugPrint('SupabaseAuthService: signUp notice ($email): $signUpErr');
      }
    }

    return isAuthenticated;
  }
}
