import 'package:firedart/auth/firebase_auth.dart';
import 'package:grpc/grpc.dart';

class ApplicationDefaultAuthenticator {
  ApplicationDefaultAuthenticator({required this.useFirestoreEmulator});

  final bool useFirestoreEmulator;

  late final Future<HttpBasedAuthenticator> _delegate =
      applicationDefaultCredentialsAuthenticator([
    'https://www.googleapis.com/auth/datastore',
  ]);

  Future<void> authenticate(Map<String, String> metadata, String uri) async {
    // If we are using the firestore emulator, see if we should use the auth from the Auth emulator.
    // Otherwise, set placeholder credentials and do not use the production authentication
    if (useFirestoreEmulator) {
      if (FirebaseAuth.initialized && FirebaseAuth.instance.useEmulator) {
        return (await _delegate).authenticate(metadata, uri);
      }

      metadata['authorization'] = 'Bearer owner';

      return;
    }

    return (await _delegate).authenticate(metadata, uri);
  }
}
