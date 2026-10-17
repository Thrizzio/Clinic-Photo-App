import 'dart:async';
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis_auth/googleapis_auth.dart';
import '../config.dart';

enum GoogleAuthState {
  ready,
  notSignedIn,
  scopesRequired,
  networkUnavailable,
  missingConfiguration,
  failed,
}

class GoogleAuthStatus {
  final GoogleAuthState state;

  const GoogleAuthStatus(this.state);

  bool get isReady => state == GoogleAuthState.ready;

  String get userMessage => switch (state) {
        GoogleAuthState.ready => 'Google access ready',
        GoogleAuthState.notSignedIn => 'Sign in to Google to sync the clinic sheet',
        GoogleAuthState.scopesRequired => 'Google Sheets/Drive access is required',
        GoogleAuthState.networkUnavailable => 'Google is temporarily unavailable; showing cached data',
        GoogleAuthState.missingConfiguration => 'Google Sign-In is not configured',
        GoogleAuthState.failed => 'Google authorization could not be completed',
      };
}

class GoogleAuthService {
  final GoogleSignIn _googleSignIn;
  GoogleSignInAccount? _currentAccount;
  bool _initialized = false;
  Future<void>? _initFuture;
  Future<GoogleSignInAccount?>? _silentAccountFuture;
  Future<AuthClient?>? _silentClientFuture;
  Future<GoogleSignInAccount?>? _interactiveSignInFuture;
  bool _interactiveRecoveryAttempted = false;
  GoogleAuthStatus _lastStatus = const GoogleAuthStatus(GoogleAuthState.notSignedIn);

  /// Resets the one-time interactive recovery attempt flag.
  void resetRecoveryAttempt() {
    _interactiveRecoveryAttempted = false;
  }

  GoogleAuthService([GoogleSignIn? googleSignIn])
      : _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  GoogleSignInAccount? get currentAccount => _currentAccount;
  GoogleAuthStatus get lastStatus => _lastStatus;

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
    if (AppConfig.serverClientId.trim().isEmpty) {
      _lastStatus = const GoogleAuthStatus(GoogleAuthState.missingConfiguration);
      return;
    }
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
      _lastStatus = _classifyError(e);
      debugPrint('GoogleSignIn initialization warning: $e');
    }
  }

  /// Attempts lightweight (silent) sign-in without user interaction.
  Future<GoogleSignInAccount?> signInSilently() {
    final active = _silentAccountFuture;
    if (active != null) return active;

    final future = _signInSilently();
    _silentAccountFuture = future;
    future.then<void>(
      (_) {
        if (identical(_silentAccountFuture, future)) _silentAccountFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_silentAccountFuture, future)) _silentAccountFuture = null;
      },
    );
    return future;
  }

  Future<GoogleSignInAccount?> _signInSilently() async {
    await ensureInitialized();
    if (!_initialized) return null;
    try {
      final attempt = _googleSignIn.attemptLightweightAuthentication();
      final account = attempt != null ? await attempt : null;
      _currentAccount = account;
      _lastStatus = account == null
          ? const GoogleAuthStatus(GoogleAuthState.notSignedIn)
          : const GoogleAuthStatus(GoogleAuthState.scopesRequired);
      return account;
    } catch (e) {
      _lastStatus = _classifyError(e);
      debugPrint('Silent sign-in failed: $e');
      return null;
    }
  }

  /// Triggers interactive Google Sign-In prompt.
  Future<GoogleSignInAccount?> signIn() {
    final active = _interactiveSignInFuture;
    if (active != null) return active;

    final future = _signInInteractively();
    _interactiveSignInFuture = future;
    future.then<void>(
      (_) {
        if (identical(_interactiveSignInFuture, future)) _interactiveSignInFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_interactiveSignInFuture, future)) _interactiveSignInFuture = null;
      },
    );
    return future;
  }

  Future<GoogleSignInAccount?> _signInInteractively() async {
    await ensureInitialized();
    if (!_initialized) return null;
    try {
      final account = await _googleSignIn.authenticate(
        scopeHint: AppConfig.googleScopes,
      );
      _currentAccount = account;
      _lastStatus = const GoogleAuthStatus(GoogleAuthState.scopesRequired);
      return account;
    } catch (e) {
      _lastStatus = _classifyError(e);
      debugPrint('Interactive sign-in error: $e');
      rethrow;
    }
  }

  /// Signs the doctor out of the Google account.
  Future<void> signOut() async {
    await ensureInitialized();
    await _googleSignIn.signOut();
    _currentAccount = null;
    _interactiveRecoveryAttempted = false;
  }

  static const _silentZoneKey = #_googleAuthSilentRequest;

  /// Obtains an authenticated HTTP client for Google APIs calls.
  ///
  /// Uses [extension_google_sign_in_as_googleapis_auth] with [GoogleSignInClientAuthorization.authClient].
  Future<AuthClient?> getAuthenticatedClient() async {
    final isSilentInZone = Zone.current[_silentZoneKey] == true;
    final allowInteractive = !isSilentInZone;
    return _getAuthenticatedClient(allowInteractive: allowInteractive);
  }

  /// Gets a client without ever requesting a new OAuth scope prompt. Test
  /// doubles that override [getAuthenticatedClient] continue to work because
  /// this method delegates through the overridable entry point.
  Future<AuthClient?> getAuthenticatedClientSilently() {
    final active = _silentClientFuture;
    if (active != null) return active;

    final future = runZoned(
      () => getAuthenticatedClient(),
      zoneValues: {_silentZoneKey: true},
    );
    _silentClientFuture = future;
    future.then<void>(
      (_) {
        if (identical(_silentClientFuture, future)) _silentClientFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_silentClientFuture, future)) _silentClientFuture = null;
      },
    );
    return future;
  }

  /// Warms up the existing Google account and requested scopes without ever
  /// opening an interactive prompt. This runs after the first frame so local
  /// patients and photos remain usable while Google authorization settles.
  Future<GoogleAuthStatus> warmUpSilently() async {
    await getAuthenticatedClientSilently();
    return _lastStatus;
  }

  Future<AuthClient?> _getAuthenticatedClient({required bool allowInteractive}) async {
    // A silent queue/WorkManager request must not start Credential Manager or
    // any other user-facing authentication flow. Foreground callers retain
    // the existing lightweight sign-in behavior.
    var account = _currentAccount ?? await signInSilently();
    if (account == null) {
      if (allowInteractive && !_interactiveRecoveryAttempted) {
        _interactiveRecoveryAttempted = true;
        try {
          account = await signIn();
        } catch (e) {
          _lastStatus = _classifyError(e);
          debugPrint('Interactive Google sign-in recovery error: $e');
          return null;
        }
      }
      if (account == null) {
        _lastStatus = const GoogleAuthStatus(GoogleAuthState.notSignedIn);
        return null;
      }
    }

    try {
      // Check existing authorization for scopes first without prompt
      var authz = await account.authorizationClient.authorizationForScopes(
        AppConfig.googleScopes,
      );

      // A queue worker must never open an authorization prompt. UI callers
      // use the default true value and may request scopes interactively.
      if (authz == null && !allowInteractive) {
        _lastStatus = const GoogleAuthStatus(GoogleAuthState.scopesRequired);
        debugPrint('Google API scopes are not authorized; silent worker access deferred.');
        return null;
      }
      authz ??= await account.authorizationClient.authorizeScopes(AppConfig.googleScopes);

      _lastStatus = const GoogleAuthStatus(GoogleAuthState.ready);
      _interactiveRecoveryAttempted = false;
      return authz.authClient(scopes: AppConfig.googleScopes);
    } catch (e) {
      _lastStatus = _classifyError(e);
      debugPrint('Error getting authenticated client: $e');
      return null;
    }
  }

  GoogleAuthStatus _classifyError(Object error) {
    if (error is GoogleSignInException) {
      switch (error.code) {
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          return const GoogleAuthStatus(GoogleAuthState.missingConfiguration);
        case GoogleSignInExceptionCode.canceled:
        case GoogleSignInExceptionCode.interrupted:
        case GoogleSignInExceptionCode.uiUnavailable:
          return const GoogleAuthStatus(GoogleAuthState.scopesRequired);
        case GoogleSignInExceptionCode.unknownError:
        case GoogleSignInExceptionCode.userMismatch:
          break;
      }
    }

    final message = error.toString().toLowerCase();
    if (message.contains('socketexception') ||
        message.contains('failed host lookup') ||
        message.contains('network') ||
        message.contains('timeout')) {
      return const GoogleAuthStatus(GoogleAuthState.networkUnavailable);
    }
    return const GoogleAuthStatus(GoogleAuthState.failed);
  }
}
