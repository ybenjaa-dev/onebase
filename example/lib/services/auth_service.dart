import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Dev-token auth against the generated `/token` endpoint. In a real app,
/// replace this with your auth provider (Supabase, Firebase, Auth0, ...) and
/// point mongo_easy's TokenProvider at its access token.
class AuthService {
  static const _tokenKey = 'mongo_easy_example.token';
  static const _emailKey = 'mongo_easy_example.email';

  String? token;
  String? email;

  bool get isSignedIn => token != null;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString(_tokenKey);
    email = prefs.getString(_emailKey);
  }

  Future<void> signIn(String email) async {
    final response = await http.post(
      Uri.parse(AppConfig.tokenUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    if (response.statusCode != 200) {
      throw Exception('Login failed (HTTP ${response.statusCode}): '
          '${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, Object?>;
    token = body['token']! as String;
    this.email = email;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token!);
    await prefs.setString(_emailKey, email);
  }

  Future<void> signOut() async {
    token = null;
    email = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
  }
}
