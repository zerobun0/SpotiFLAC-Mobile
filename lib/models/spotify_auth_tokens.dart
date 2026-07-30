class SpotifyAuthTokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  const SpotifyAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  bool get isExpired => isExpiredAt(DateTime.now());
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  bool get needsRefresh => needsRefreshAt(DateTime.now());
  bool needsRefreshAt(DateTime now) =>
      now.isAfter(expiresAt.subtract(const Duration(seconds: 60)));

  factory SpotifyAuthTokens.fromTokenResponse(
    Map<String, dynamic> json, {
    required DateTime now,
    String? previousRefreshToken,
  }) {
    final expiresInSeconds = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return SpotifyAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken:
          (json['refresh_token'] as String?) ?? previousRefreshToken,
      expiresAt: now.add(Duration(seconds: expiresInSeconds)),
    );
  }

  factory SpotifyAuthTokens.fromStorageJson(Map<String, dynamic> json) {
    return SpotifyAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
  }

  Map<String, dynamic> toStorageJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.toIso8601String(),
  };
}
