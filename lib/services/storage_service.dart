import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/slurm_models.dart';
import '../models/app_skin.dart';

class StorageService {
  final _secure = const FlutterSecureStorage();
  // Async preferences bypass isolate-local caches in the UI and service engines.
  late final prefs = SharedPreferencesAsync();
  Future<List<ServerConfig>> readServers() async {
    final raw = await _secure.read(key: 'slurm_servers_v1');
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map(
          (e) =>
              ServerConfig.fromSecureJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList();
  }

  Future<void> saveServers(List<ServerConfig> servers) => _secure.write(
    key: 'slurm_servers_v1',
    value: jsonEncode(servers.map((s) => s.toSecureJson()).toList()),
  );
  Future<int> readInterval() async =>
      (await prefs.getInt('refresh_seconds') ?? 10).clamp(2, 3600);
  Future<void> saveInterval(int value) =>
      prefs.setInt('refresh_seconds', value.clamp(2, 3600));
  Future<AppSkin> readSkin() async =>
      AppSkin.parse(await prefs.getString('appearance_skin'));
  Future<void> saveSkin(AppSkin skin) =>
      prefs.setString('appearance_skin', skin.name);
  Future<Map<String, dynamic>> readMap(String key) async {
    final raw = await prefs.getString(key);
    if (raw == null) return {};
    try {
      final value = jsonDecode(raw);
      return value is Map ? Map<String, dynamic>.from(value) : {};
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }

  Future<void> saveMap(String key, Map<String, dynamic> value) =>
      prefs.setString(key, jsonEncode(value));

  Future<Map<String, dynamic>> saveMonitorCache(
    Map<String, dynamic> value,
  ) async {
    final servers = await readServers();
    final valid = readSnapshots(value, servers);
    final ids = valid.map((s) => s.serverId).toSet();
    Map<String, dynamic> dates(String key) {
      final raw = value[key];
      return raw is Map
          ? {
              for (final entry in raw.entries)
                if (entry.key is String &&
                    ids.contains(entry.key) &&
                    entry.value is String &&
                    DateTime.tryParse(entry.value as String) != null)
                  entry.key as String: entry.value,
            }
          : {};
    }

    final filtered = <String, dynamic>{
      'snapshots': valid.map((s) => s.toJson()).toList(),
      'accountingCursor': dates('accountingCursor'),
      'historyBackfill': dates('historyBackfill'),
    };
    await saveMap('monitor_cache', filtered);
    return filtered;
  }
}
