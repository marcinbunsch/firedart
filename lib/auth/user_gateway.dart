import 'dart:convert';

import 'package:firedart/auth/client.dart';
import 'package:firedart/auth/token_provider.dart';

class UserGateway {
  final UserClient _client;
  final bool useEmulator;

  UserGateway(KeyClient client, TokenProvider tokenProvider, {this.useEmulator = false})
      : _client = UserClient(client, tokenProvider, useEmulator: useEmulator);

  Future<void> requestEmailVerification({String? langCode}) =>
      _post(
        'sendOobCode',
        {'requestType': 'VERIFY_EMAIL'},
        headers: {if (langCode != null) 'X-Firebase-Locale': langCode},
      );

  Future<User> getUser() async {
    var map = await _post('lookup', {});
    return User.fromMap(map['users'][0]);
  }

  Future<void> changePassword(String password) async {
    await _post('update', {
      'password': password,
    });
  }

  Future<void> updateProfile(String? displayName, String? photoUrl) async {
    assert(displayName != null || photoUrl != null);
    await _post('update', {
      if (displayName != null) 'displayName': displayName,
      if (photoUrl != null) 'photoUrl': photoUrl,
    });
  }

  Future<void> deleteAccount() async {
    await _post('delete', {});
  }

  Future<Map<String, dynamic>> _post<T>(String method,
      Map<String, dynamic> body,
      {Map<String, String>? headers}) async {

    final requestPath = 'identitytoolkit.googleapis.com/v1/accounts:$method';
    final requestUrl = useEmulator ? 'http://localhost:9099/$requestPath' : 'https://$requestPath';

    var response = await _client.post(
      Uri.parse(requestUrl),
      body: json.encode(body),
      headers: {'content-type': 'application/json'},
    );

    return json.decode(response.body);
  }
}

class User {
  final String id;
  final String? displayName;
  final String? photoUrl;
  final String? email;
  final bool? emailVerified;

  User.fromMap(Map<String, dynamic> map)
      : id = map['localId'],
        displayName = map['displayName'],
        photoUrl = map['photoUrl'],
        email = map['email'],
        emailVerified = map['emailVerified'];

  Map<String, dynamic> toMap() =>
      {
        'localId': id,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'email': email,
        'emailVerified': emailVerified,
      };

  @override
  String toString() => toMap().toString();
}
