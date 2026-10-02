import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

const _moduleHeaders = <String, String>{'X-App-Module': 'couple_schedule'};

class AvailabilityInvitation {
  const AvailabilityInvitation({
    required this.id,
    required this.username,
    required this.expiresAt,
  });

  final String id;
  final String username;
  final DateTime expiresAt;

  factory AvailabilityInvitation.fromJson(Map<String, dynamic> json) =>
      AvailabilityInvitation(
        id: json['invitation_id']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

class CodeInvitation {
  const CodeInvitation({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  factory CodeInvitation.fromJson(Map<String, dynamic> json) => CodeInvitation(
        code: json['code']?.toString() ?? '',
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

class AvailabilityStatus {
  const AvailabilityStatus({
    required this.state,
    this.partnerUsername = '',
    this.inviteType = '',
    this.outgoing,
    this.invitations = const [],
  });

  final String state;
  final String partnerUsername;
  final String inviteType;
  final AvailabilityInvitation? outgoing;
  final List<AvailabilityInvitation> invitations;

  bool get connected => state == 'connected';

  factory AvailabilityStatus.fromJson(Map<String, dynamic> json) {
    final outgoing = json['outgoing'];
    final expires = json['expires_at'];
    return AvailabilityStatus(
      state: json['state']?.toString() ?? 'disconnected',
      inviteType: json['invite_type']?.toString() ?? '',
      partnerUsername:
          (json['partner'] is Map ? (json['partner'] as Map)['username'] : null)
                  ?.toString() ??
              '',
      outgoing: outgoing is Map && expires is String
          ? AvailabilityInvitation.fromJson({
              'invitation_id': outgoing['invitation_id'],
              'username': outgoing['username'],
              'expires_at': expires,
            })
          : null,
      invitations: [
        for (final item in (json['invitations'] as List? ?? const []))
          if (item is Map<String, dynamic>)
            AvailabilityInvitation.fromJson(item),
      ],
    );
  }
}

class AvailabilityDay {
  const AvailabilityDay({
    required this.day,
    required this.date,
    required this.states,
  });

  final int day;
  final DateTime date;
  final List<String> states;

  factory AvailabilityDay.fromJson(Map<String, dynamic> json) =>
      AvailabilityDay(
        day: (json['day'] as num).toInt(),
        date: DateTime.parse(json['date'] as String),
        states:
            (json['states'] as List).map((item) => item.toString()).toList(),
      );
}

class AvailabilityWeek {
  const AvailabilityWeek({
    required this.partnerUsername,
    required this.sectionCount,
    required this.days,
  });

  final String partnerUsername;
  final int sectionCount;
  final List<AvailabilityDay> days;

  factory AvailabilityWeek.fromJson(Map<String, dynamic> json) =>
      AvailabilityWeek(
        partnerUsername: (json['partner'] as Map)['username']?.toString() ?? '',
        sectionCount: (json['section_count'] as num).toInt(),
        days: [
          for (final item in json['days'] as List)
            AvailabilityDay.fromJson(item as Map<String, dynamic>),
        ],
      );
}

abstract interface class SharedAvailabilityApi {
  Future<AvailabilityStatus> status();
  Future<List<String>> searchUsers(String query);
  Future<void> invite(String username);
  Future<CodeInvitation> createCodeInvite();
  Future<void> claimCode(String code);
  Future<void> cancelCodeInvite();
  Future<void> respond(String invitationId, {required bool accept});
  Future<void> cancel(String invitationId);
  Future<void> disconnect();
  Future<AvailabilityWeek> week(DateTime monday);
}

class SharedAvailabilityRepository implements SharedAvailabilityApi {
  SharedAvailabilityRepository(this._dio);

  final Dio _dio;

  Options get _options => Options(headers: _moduleHeaders);

  Map<String, dynamic> _data(Response<Map<String, dynamic>> response) =>
      response.data!['data'] as Map<String, dynamic>;

  @override
  Future<AvailabilityStatus> status() async => AvailabilityStatus.fromJson(
        _data(await _dio.get<Map<String, dynamic>>(
          '/api/couple-schedule/status',
          options: _options,
        )),
      );

  @override
  Future<List<String>> searchUsers(String query) async {
    final data = _data(await _dio.get<Map<String, dynamic>>(
      '/api/couple-schedule/users/search',
      queryParameters: {'q': query.trim()},
      options: _options,
    ));
    return [
      for (final item in (data['items'] as List? ?? const []))
        if (item is Map && item['username'] is String)
          item['username'] as String,
    ];
  }

  @override
  Future<void> invite(String username) async {
    await _dio.post<void>(
      '/api/couple-schedule/invites',
      data: {'username': username.trim()},
      options: _options,
    );
  }

  @override
  Future<CodeInvitation> createCodeInvite() async => CodeInvitation.fromJson(
        _data(await _dio.post<Map<String, dynamic>>(
          '/api/couple-schedule/invites',
          options: _options,
        )),
      );

  @override
  Future<void> claimCode(String code) async {
    await _dio.post<void>(
      '/api/couple-schedule/claim',
      data: {'code': code.trim().toUpperCase()},
      options: _options,
    );
  }

  @override
  Future<void> cancelCodeInvite() async {
    await _dio.delete<void>(
      '/api/couple-schedule/invite-code',
      options: _options,
    );
  }

  @override
  Future<void> respond(String invitationId, {required bool accept}) async {
    await _dio.post<void>(
      '/api/couple-schedule/invites/respond',
      data: {'invitation_id': invitationId, 'accept': accept},
      options: _options,
    );
  }

  @override
  Future<void> cancel(String invitationId) async {
    await _dio.delete<void>(
      '/api/couple-schedule/invites/${Uri.encodeComponent(invitationId)}',
      options: _options,
    );
  }

  @override
  Future<void> disconnect() async {
    await _dio.delete<void>(
      '/api/couple-schedule/connection',
      options: _options,
    );
  }

  @override
  Future<AvailabilityWeek> week(DateTime monday) async {
    final date = '${monday.year.toString().padLeft(4, '0')}-'
        '${monday.month.toString().padLeft(2, '0')}-'
        '${monday.day.toString().padLeft(2, '0')}';
    return AvailabilityWeek.fromJson(
      _data(await _dio.get<Map<String, dynamic>>(
        '/api/couple-schedule/week',
        queryParameters: {'week_start': date},
        options: _options,
      )),
    );
  }
}

final sharedAvailabilityRepositoryProvider = Provider<SharedAvailabilityApi>(
  (ref) => SharedAvailabilityRepository(ref.read(dioProvider)),
);
