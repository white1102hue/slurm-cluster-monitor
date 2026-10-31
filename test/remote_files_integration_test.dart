import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slurm_cluster_monitor/models/slurm_models.dart';
import 'package:slurm_cluster_monitor/services/remote_files.dart';
import 'package:slurm_cluster_monitor/services/slurm_ssh_service.dart';
import 'package:slurm_cluster_monitor/services/vasp_progress_service.dart';
import 'package:slurm_cluster_monitor/services/gaussian_service.dart';
import 'package:slurm_cluster_monitor/services/optimization_check_service.dart';
import 'dart:async';

void main() {
  final dir = Platform.environment['SLURM_SSH_FIXTURE'];
  group(
    'read-only SFTP over real loopback SSH',
    skip: dir == null ? 'Local SSH fixture not configured' : false,
    () {
      late ServerConfig config;
      setUpAll(() {
        final c =
            jsonDecode(File('$dir/connection.json').readAsStringSync()) as Map;
        config = ServerConfig(
          id: 'files',
          name: 'Fixture',
          host: '127.0.0.1',
          port: c['port'] as int,
          username: 'tester',
          password: 'fixture-password',
          fingerprint: c['fingerprint'] as String,
        );
      });
      test(
        'concurrent first directory and file reads use one SSH handshake',
        () async {
          final before =
              (jsonDecode(File('$dir/counters.json').readAsStringSync())
                      as Map)['connections']
                  as int;
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          await Future.wait([
            files.list('/home/tester/project-42'),
            files.read('/home/tester/project-42/POSCAR'),
          ]);
          final after =
              (jsonDecode(File('$dir/counters.json').readAsStringSync())
                      as Map)['connections']
                  as int;
          expect(after, before + 1);
        },
      );
      test(
        'OUTCAR curves read beyond 2 MB, preserve restart records and ignore the unfinished final force block',
        () async {
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          int read = 0, total = 0;
          final progress = await VaspProgressService(files).load(
            '/home/tester/project-42/OUTCAR',
            onProgress: (r, t) {
              read = r;
              total = t;
            },
          );
          expect(total, greaterThan(SshRemoteFiles.previewBytes));
          expect(read, total);
          expect(progress.energies.length, 12);
          expect(progress.forces.length, 12);
          expect(progress.energies.last.step, 12);
          expect(progress.energies.last.value, closeTo(-108.5 + 1 / 12, 1e-12));
          expect(
            progress.forces.last.allowed,
            closeTo(0.0348010216963685, 1e-10),
          );
          expect(progress.warnings.join(), contains('未写完'));
          var cancel = false;
          await expectLater(
            files
                .readChunks(
                  '/home/tester/project-42/OUTCAR',
                  cancelled: () => cancel,
                  onProgress: (r, t) {
                    if (r > 0) cancel = true;
                  },
                )
                .drain<void>(),
            throwsA(isA<FileReadCancelled>()),
          );
          expect(
            (await files.read('/home/tester/project-42/POSCAR')).text,
            startsWith('Silicon'),
          );
          expect(
            (jsonDecode(File('$dir/counters.json').readAsStringSync())
                as Map)['sftp_writes'],
            0,
          );
        },
      );
      test(
        'Gaussian geometry and convergence tables stream past 2 MB over SFTP',
        () async {
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          var total = 0;
          final data = await GaussianService(files).load(
            '/home/tester/project-42/water.log',
            onProgress: (_, size) => total = size,
          );
          expect(total, greaterThan(SshRemoteFiles.previewBytes));
          expect(data.structure!.atoms.length, 3);
          expect(data.steps.single.energy, -76.123456789);
          expect(data.steps.single.criteria.length, 4);
          expect(data.finished, isFalse);
          final sample = await files.sample(
            '/home/tester/project-42/water.log',
            tail: true,
          );
          expect(utf8.encode(sample.text).length, lessThanOrEqualTo(64 * 1024));
          expect(sample.truncated, isTrue);
          expect(
            (jsonDecode(File('$dir/counters.json').readAsStringSync())
                as Map)['sftp_writes'],
            0,
          );
        },
      );
      test(
        'lists directories and reads literal filenames without remote shell execution',
        () async {
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          final listing = await files.list('/home/tester/project-42');
          expect(listing.entries.first.name, 'outputs');
          expect(listing.entries.first.directory, isTrue);
          expect(listing.entries.any((e) => e.name == 'POSCAR'), isTrue);
          expect(
            await files.isDirectory('/home/tester/project-42/results-link'),
            isTrue,
          );
          expect(
            (await files.list(
              '/home/tester/project-42/outputs',
            )).entries.single.name,
            'result.txt',
          );
          final text = await files.read(
            "/home/tester/project-42/a 'quoted' \$(file).txt",
          );
          expect(text.text, contains('Literal filename'));
          expect(text.truncated, isFalse);
        },
      );
      test(
        'one SSH search discovers the latest OUTCAR beyond shallow directory limits',
        () async {
          final before =
              jsonDecode(File('$dir/counters.json').readAsStringSync()) as Map;
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          final found = await files.findOutputs('/home/tester/project-42');
          expect(found.complete, isTrue);
          expect(
            found.outcar!.path,
            '/home/tester/project-42/serial/run-69/stage/relax/ionic/OUTCAR',
          );
          expect(found.matched, greaterThan(70));
          final after =
              jsonDecode(File('$dir/counters.json').readAsStringSync()) as Map;
          expect(after['output_searches'], before['output_searches'] + 1);
          expect(after['sftp_listings'], before['sftp_listings']);
          final result = await OptimizationCheckService(
            files,
          ).check('/home/tester/project-42');
          expect(result.path, found.outcar!.path);
          expect(result.assessment, isNotNull);
        },
      );
      test(
        'partial results and unsupported find retain a usable recursive result',
        () async {
          final state = File('$dir/state.json');
          final previous = state.existsSync() ? state.readAsStringSync() : '{}';
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          try {
            state.writeAsStringSync('{"searchPartial":true}');
            var found = await files.findOutputs('/home/tester/project-42');
            expect(found.complete, isFalse);
            expect(
              found.outcar!.path,
              contains('run-69/stage/relax/ionic/OUTCAR'),
            );
            state.writeAsStringSync('{"searchUnsupported":true}');
            found = await files.findOutputs(
              '/home/tester/project-42/serial/run-69',
            );
            expect(found.complete, isTrue);
            expect(
              found.outcar!.path,
              contains('run-69/stage/relax/ionic/OUTCAR'),
            );
          } finally {
            state.writeAsStringSync(previous);
          }
        },
      );
      test(
        'cancelling a remote search leaves the shared SSH transport usable',
        () async {
          final state = File('$dir/state.json');
          final previous = state.existsSync() ? state.readAsStringSync() : '{}';
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          var stop = false;
          Timer? timer;
          try {
            state.writeAsStringSync('{"searchDelay":2}');
            timer = Timer(const Duration(milliseconds: 200), () => stop = true);
            await expectLater(
              files.findOutputs(
                '/home/tester/project-42',
                cancelled: () => stop,
              ),
              throwsA(isA<FileReadCancelled>()),
            );
            expect(
              (await files.read('/home/tester/project-42/POSCAR')).text,
              startsWith('Silicon'),
            );
          } finally {
            timer?.cancel();
            state.writeAsStringSync(previous);
          }
        },
      );
      test(
        'bounded head and tail reads, permission errors and binary rejection',
        () async {
          final files = SshRemoteFiles(config);
          addTearDown(files.close);
          final head = await files.read('/home/tester/project-42/large.log');
          expect(head.truncated, isTrue);
          expect(head.text, startsWith('FIRST LINE'));
          expect(
            head.text.length,
            lessThanOrEqualTo(SshRemoteFiles.previewBytes),
          );
          final tail = await files.read(
            '/home/tester/project-42/large.log',
            tail: true,
          );
          expect(tail.truncated, isTrue);
          expect(tail.text, endsWith('LAST LINE\n'));
          await expectLater(
            files.read('/home/tester/project-42/binary.bin'),
            throwsFormatException,
          );
          await expectLater(
            files.read('/home/tester/project-42/private.txt'),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('权限'),
              ),
            ),
          );
          await expectLater(
            files.read('/home/tester/project-42/missing'),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('不存在'),
              ),
            ),
          );
          expect(
            (await files.read('/home/tester/project-42/POSCAR')).text,
            startsWith('Silicon'),
          );
          expect(
            (jsonDecode(File('$dir/counters.json').readAsStringSync())
                as Map)['sftp_writes'],
            0,
          );
        },
      );
      test(
        'wrong host key blocks file credentials and closing browser leaves monitoring connected',
        () async {
          final counts = File('$dir/counters.json');
          final before =
              (jsonDecode(counts.readAsStringSync()) as Map)['password_auth'];
          final untrusted = SshRemoteFiles(
            config.copyWith(fingerprint: 'SHA256:untrusted'),
          );
          addTearDown(untrusted.close);
          await expectLater(
            untrusted.list('/home/tester/project-42'),
            throwsFormatException,
          );
          expect(
            (jsonDecode(counts.readAsStringSync()) as Map)['password_auth'],
            before,
          );
          final monitor = SlurmSshService();
          addTearDown(monitor.close);
          await monitor.fetch(config);
          final files = SshRemoteFiles(config);
          await files.list('/home/tester/project-42');
          files.close();
          expect((await monitor.fetch(config)).isOnline, isTrue);
          await expectLater(
            files.read('/home/tester/project-42/POSCAR'),
            throwsFormatException,
          );
        },
      );
    },
  );
}
