import 'dart:async';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import '../config.dart';

class GoogleAuthService {
  final GoogleSignIn _googleSignIn;
  GoogleSignInAccount? _currentAccount;
  bool _initialized = false;
  Future<void>? _initFuture;

  GoogleAuthService([GoogleSignIn? googleSignIn])
      : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  GoogleSignInAccount? get currentAccount => _currentAccount;

  /// Ensures GoogleSignIn is initialized exactly once before authentication.
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    _initFuture = _doInitialize();
    await _initFuture;
  }

  Future<void> _doInitialize() async {
    try {
      // Modern Google Identity Services on Android requires the Web OAuth 2.0
      // client ID as serverClientId. Do not pass Android client ID as clientId.
      await _googleSignIn.initialize(
        serverClientId: AppConfig.serverClientId,
      );
      _initialized = true;

      _googleSignIn.authenticationEvents.listen((event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _currentAccount = event.user;
        } else if (event is GoogleSignInAuthenticationEventSignOut) {
          _currentAccount = null;
        }
      });
    } catch (e) {
      debugPrint('GoogleSignIn initialization warning: $e');
    }
  }

  /// Attempts lightweight (silent) sign-in without user interaction.
  Future<GoogleSignInAccount?> signInSilently() async {
    await ensureInitialized();
    try {
      final attempt = _googleSignIn.attemptLightweightAuthentication();
      final account = attempt != null ? await attempt : null;
      _currentAccount = account;
      return account;
    } catch (e) {
      debugPrint('Silent sign-in failed: $e');
      return null;
    }
  }

  /// Triggers interactive Google Sign-In prompt.
  Future<GoogleSignInAccount?> signIn() async {
    await ensureInitialized();
    try {
      final account = await _googleSignIn.authenticate(
        scopeHint: AppConfig.googleScopes,
      );
      _currentAccount = account;
      return account;
    } catch (e) {
      debugPrint('Interactive sign-in error: $e');
      rethrow;
    }
  }

  /// Signs the doctor out of the Google account.
  Future<void> signOut() async {
    await ensureInitialized();
    await _googleSignIn.signOut();
    _currentAccount = null;
  }

  /// Obtains an authenticated HTTP client for Google APIs calls.
  ///
  /// Uses [extension_google_sign_in_as_googleapis_auth] with [GoogleSignInClientAuthorization.authClient].
  Future<AuthClient?> getAuthenticatedClient() async {
    final account = _currentAccount ?? await signInSilently();
    if (account == null) {
      return null;
    }

    try {
      // Check existing authorization for scopes first without prompt
      var authz = await account.authorizationClient.authorizationForScopes(
        AppConfig.googleScopes,
      );

      // If not yet authorized, request authorization
      authz ??= await account.authorizationClient.authorizeScopes(
        AppConfig.googleScopes,
      );

      return authz.authClient(scopes: AppConfig.googleScopes);
    } catch (e) {
      debugPrint('Error getting authenticated client: $e');
      return null;
    }
  }
}
