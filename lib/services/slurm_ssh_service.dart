import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import '../models/slurm_models.dart';
import 'slurm_parser.dart';
import 'shell_utils.dart';
export 'shell_utils.dart';

abstract interface class SnapshotSource {
  Future<ServerSnapshot> fetch(ServerConfig server, {DateTime? since});
  void close([String? serverId]);
}

String collectionScript({DateTime? since, bool collectNodeCapacity = true}) {
  final cutoff = (since ?? DateTime.now().toUtc().subtract(jobHistoryRetention))
      .toUtc()
      .toIso8601String()
      .substring(0, 19);
  return '''
export LC_ALL=C TZ=UTC SLURM_TIME_FORMAT=standard
echo '===META==='
date -u +%s
SLURM_MONITOR_ERR=\$(mktemp)
if [ -z "\$SLURM_MONITOR_ERR" ]; then
  echo '===DETAIL:SQUEUE===Cannot create temporary file for command diagnostics'
  echo '===SQUEUE==='
  echo '===STATUS:SQUEUE:1==='
  exit 0
fi
trap 'rm -f -- "\$SLURM_MONITOR_ERR"' EXIT
slurm_monitor_status() {
  printf '===STATUS:%s:%s===\\n' "\$1" "\$2"
  if [ "\$2" -ne 0 ]; then
    head -c 2048 "\$SLURM_MONITOR_ERR" | while IFS= read -r SLURM_MONITOR_LINE || [ -n "\$SLURM_MONITOR_LINE" ]; do
      printf '===DETAIL:%s===%s\\n' "\$1" "\$SLURM_MONITOR_LINE"
    done
  fi
}
echo '===SQUEUE==='
QUEUE=\$(squeue --array -u "\$(id -un)" -h -o '%i|%j|%P|%T|%M|%l|%C|%m|%N|%r|%D|%V|%A|%Z' 2>"\$SLURM_MONITOR_ERR")
Q_STATUS=\$?
if [ -n "\$QUEUE" ]; then printf '%s\\n' "\$QUEUE"; fi
slurm_monitor_status SQUEUE "\$Q_STATUS"
if [ "\$Q_STATUS" -ne 0 ]; then exit 0; fi
echo '===SSTAT==='
RUN_IDS=\$(printf '%s\\n' "\$QUEUE" | awk -F'|' '\$4 == "RUNNING" {print (NF >= 13 && \$13 != "" ? \$13 : \$1)}' | grep -E '^[0-9]+([+][0-9]+)?\$' | paste -sd, -)
S_STATUS=0
if [ -n "\$RUN_IDS" ]; then
  sstat --allsteps -j "\$RUN_IDS" -P -n --format=JobID%80,AveCPU,AveRSS,MaxRSS,NTasks 2>"\$SLURM_MONITOR_ERR"
  S_STATUS=\$?
fi
slurm_monitor_status SSTAT "\$S_STATUS"
echo '===SACCT==='
slurm_monitor_sacct() {
  sacct "\$@" -u "\$(id -un)" -S '$cutoff' -P -n -X --format=JobID%80,JobName%200,Partition%80,State%40,Elapsed,AllocCPUS,ReqMem,MaxRSS,ExitCode,NNodes,NodeList%200,End,Submit,Reason%200,Timelimit,WorkDir%2048 2>"\$SLURM_MONITOR_ERR"
}
slurm_monitor_sacct --array
A_STATUS=\$?
# Older Slurm releases lack sacct --array; retry only this unsupported option.
if [ "\$A_STATUS" -ne 0 ] && grep -Eq -- '(unrecognized|unknown|invalid) option.*--array' "\$SLURM_MONITOR_ERR"; then
  slurm_monitor_sacct
  A_STATUS=\$?
fi
slurm_monitor_status SACCT "\$A_STATUS"
echo '===SINFO==='
sinfo -N -h -o '%P|%a|%N|%T|%C' 2>"\$SLURM_MONITOR_ERR"
slurm_monitor_status SINFO "\$?"
${collectNodeCapacity ? '''echo '===NODES==='
scontrol show nodes -o 2>"\$SLURM_MONITOR_ERR" | awk '{name="";mem=""; for(i=1;i<=NF;i++){if(\$i ~ /^NodeName=/) name=\$i; if(\$i ~ /^RealMemory=/) mem=\$i} if(name != "") print name,mem}'
N_PIPE=("\${PIPESTATUS[@]}")
N_STATUS=\${N_PIPE[0]}
if [ "\${N_PIPE[1]}" -ne 0 ]; then N_STATUS=\${N_PIPE[1]}; fi
slurm_monitor_status NODES "\$N_STATUS"''' : ''}
''';
}

List<SSHKeyPair> _decodeKeys((String, String) args) =>
    SSHKeyPair.fromPem(args.$1, args.$2.isEmpty ? null : args.$2);

class _SshConnection {
  _SshConnection(this.server);
  final ServerConfig server;
  late final Future<SSHClient> ready;
  SSHClient? client;
  bool cancelled = false;
  ({DateTime fetchedAt, List<NodeResources> nodes})? capacity;

  void close() {
    cancelled = true;
    client?.close();
  }
}

class SlurmSshService implements SnapshotSource {
  SlurmSshService({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _connections = <String, _SshConnection>{};
  static const _timeout = Duration(seconds: 15);

  /// Verify the handshake signature and inspect its fingerprint before sending credentials.
  static Future<({String type, String fingerprint})> probeHost(
    ServerConfig server,
  ) async {
    final socket = await SSHSocket.connect(
      server.host,
      server.port,
      timeout: const Duration(seconds: 10),
    );
    ({String type, String fingerprint})? observed;
    final client = SSHClient(
      socket,
      username: server.username,
      handshakeTimeout: const Duration(seconds: 10),
      authTimeout: const Duration(seconds: 10),
      onVerifyHostKey: (type, fingerprint) {
        observed = (type: type, fingerprint: utf8.decode(fingerprint));
        return false;
      },
    );
    try {
      await client.authenticated.timeout(_timeout);
    } catch (_) {
      if (observed == null) rethrow;
    } finally {
      client.close();
    }
    if (observed == null) throw const FormatException('服务器未提供 SSH 主机指纹');
    return observed!;
  }

  Future<SSHClient> _connection(ServerConfig server) {
    final cached = _connections[server.id];
    if (cached != null &&
        cached.server.hasSameConnection(server) &&
        !cached.cancelled &&
        cached.client?.isClosed != true) {
      return cached.ready;
    }
    cached?.close();
    final connection = _SshConnection(server);
    _connections[server.id] = connection;
    connection.ready = _openConnection(connection).catchError((Object e) {
      if (identical(_connections[server.id], connection)) {
        _connections.remove(server.id);
      }
      connection.close();
      throw e;
    });
    return connection.ready;
  }

  Future<SSHClient> _openConnection(_SshConnection connection) async {
    final server = connection.server;
    if (server.fingerprint.isEmpty) {
      throw const FormatException('请先在服务器设置中确认 SSH 主机指纹');
    }
    // Decrypt before opening a socket so malformed keys cannot leak sockets.
    final identities = server.authType == AuthType.privateKey
        ? await compute(_decodeKeys, (server.privateKey, server.passphrase))
        : null;
    if (connection.cancelled) throw const FormatException('SSH 连接已关闭');
    final socket = await SSHSocket.connect(
      server.host,
      server.port,
      timeout: const Duration(seconds: 10),
    );
    if (connection.cancelled) {
      socket.close();
      throw const FormatException('SSH 连接已关闭');
    }
    var mismatch = false;
    final client = SSHClient(
      socket,
      username: server.username,
      identities: identities,
      onPasswordRequest: server.authType == AuthType.password
          ? () => server.password
          : null,
      onVerifyHostKey: (_, fingerprint) {
        final ok = utf8.decode(fingerprint) == server.fingerprint;
        mismatch = !ok;
        return ok;
      },
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 10),
      authTimeout: _timeout,
    );
    connection.client = client;
    try {
      await client.authenticated.timeout(_timeout);
      if (connection.cancelled) throw const FormatException('SSH 连接已关闭');
      return client;
    } catch (e) {
      client.close();
      if (mismatch) {
        throw const FormatException('SSH 主机指纹已变化，连接已阻止；请与管理员核对后重新确认');
      }
      rethrow;
    }
  }

  @override
  Future<ServerSnapshot> fetch(ServerConfig server, {DateTime? since}) async {
    SSHSession? session;
    SSHClient? client;
    try {
      client = await _connection(server);
      final connection = _connections[server.id];
      if (connection == null ||
          connection.cancelled ||
          !identical(connection.client, client)) {
        throw const FormatException('SSH 连接已更新或关闭');
      }
      final capacity = connection.capacity;
      final collectCapacity =
          capacity == null ||
          _now().difference(capacity.fetchedAt) >= const Duration(minutes: 1);
      session = await client
          .execute(
            'bash -lc ${shellQuote(collectionScript(since: since, collectNodeCapacity: collectCapacity))}',
          )
          .timeout(_timeout);
      Future<List<int>> read(Stream<List<int>> stream) async {
        final data = <int>[];
        await for (final chunk in stream) {
          if (data.length + chunk.length > 16 * 1024 * 1024) {
            throw const FormatException('采集数据超过 16 MB，请缩小作业历史范围');
          }
          data.addAll(chunk);
        }
        return data;
      }

      final streams = await Future.wait([
        read(session.stdout),
        read(session.stderr),
      ]).timeout(const Duration(seconds: 25));
      await session.done.timeout(_timeout);
      if (session.exitCode != 0) {
        throw const FormatException('远程采集脚本退出异常，请确认服务器安装 bash 和 Slurm 客户端');
      }
      final snapshot = const SlurmParser().parse(
        server,
        utf8.decode(streams[0], allowMalformed: true),
        nodeCapacity: collectCapacity ? const [] : capacity.nodes,
      );
      if (collectCapacity &&
          snapshot.nodes.isNotEmpty &&
          snapshot.nodes.every((n) => (n.totalMemoryMb ?? 0) > 0)) {
        connection.capacity = (fetchedAt: _now(), nodes: snapshot.nodes);
      }
      return snapshot;
    } catch (e) {
      // Command/parse errors do not invalidate an authenticated transport.
      // Discard only this request's connection, never a newer replacement.
      if (client != null && (e is! FormatException || client.isClosed)) {
        final connection = _connections[server.id];
        if (identical(connection?.client, client)) close(server.id);
      }
      rethrow;
    } finally {
      session?.close();
    }
  }

  /// A separate browser owns this service; browsing never closes the monitor's
  /// background connection and opens read-only SFTP handles for browsing.
  Future<SftpClient> openFiles(ServerConfig server) async {
    final client = await _connection(server);
    var expired = false;
    try {
      return await client
          .sftp()
          .then((sftp) {
            if (expired || client.isClosed) {
              unawaited(sftp.close().catchError((Object _) {}));
              throw const FormatException('文件连接已关闭');
            }
            return sftp;
          })
          .timeout(_timeout);
    } catch (_) {
      expired = true;
      if (identical(_connections[server.id]?.client, client)) close(server.id);
      rethrow;
    }
  }

  Future<SSHClient> connect(ServerConfig server) => _connection(server);

  @override
  void close([String? serverId]) {
    if (serverId != null) {
      _connections.remove(serverId)?.close();
    } else {
      for (final connection in _connections.values) {
        connection.close();
      }
      _connections.clear();
    }
  }
}

String friendlyError(Object error) {
  // Never show raw remote output or exception payloads that may contain secrets.
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return '连接或采集超时，将自动重试';
  final type = error.runtimeType.toString().toLowerCase();
  if (type.contains('auth')) return 'SSH 认证失败，请检查用户名、密码或私钥口令';
  if (type.contains('keydecode') || type.contains('keydecrypt')) {
    return '私钥格式或 Passphrase 不正确';
  }
  if (type.contains('hostkey')) return 'SSH 主机指纹校验失败，请核对服务器身份';
  if (type.contains('socket')) return '无法连接服务器，请检查网络、VPN、地址和端口';
  return '连接中断或 Slurm 采集失败，将自动重试';
}
