import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:io/ansi.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart' as y;

import 'travis_config.dart';
import 'utils.dart';

class TravisCommand extends Command {
  @override
  String get name => 'travis';

  @override
  String get description => 'Configure Travis-CI for child packages.';

  @override
  Future run() => _travis();
}

Future _travis() async {
  var packages = getPackageConfig();

  var configs = <String, TravisConfig>{};

  for (var pkg in packages.keys) {
    var travisPath = _travisPath(pkg);
    var travisFile = new File(travisPath);

    if (travisFile.existsSync()) {
      var travisYaml =
          y.loadYaml(travisFile.readAsStringSync(), sourceUrl: travisPath);

      stderr.writeln(styleBold.wrap('package:$pkg'));
      var config = new TravisConfig.parse(travisYaml as Map<String, dynamic>);

      if (config.tasks.any((dt) => dt.config != null)) {
        throw new UnsupportedError(
            'Tasks with fancy configuration are not supported.');
      }

      configs[pkg] = config;
    }
  }

  var sdks = (configs.values.expand((tc) => tc.sdks).toList()..sort()).toSet();

  var taskToKeyMap = <DartTask, String>{};

  for (var task in configs.values
      .expand((tc) => tc.travisJobs)
      .map((tj) => tj.task)
      .toSet()) {
    assert(!taskToKeyMap.containsKey(task));
    var taskKey = task.name;

    var count = 1;
    while (taskToKeyMap.containsKey(taskKey)) {
      taskKey = '${task.name}_${count++}';
    }

    taskToKeyMap[task] = taskKey;
  }

  var environmentVars = new Map<String, Set<String>>();

  configs.forEach((pkg, config) {
    for (var job in config.travisJobs) {
      var newVar = 'PKG=${pkg} TASK=${taskToKeyMap[job.task]}';
      environmentVars.putIfAbsent(newVar, () => new Set<String>()).add(job.sdk);
    }
  });

  var taskEntries = <String>[];

  void addEntry(String label, List<String> contentLines) {
    assert(contentLines.isNotEmpty);
    contentLines.add(';;');

    var buffer = new StringBuffer('$label) ${contentLines.first}\n');
    buffer.writeAll(contentLines.skip(1).map((l) => '  $l'), '\n');
    taskEntries.add(buffer.toString());
  }

  taskToKeyMap.forEach((dartTask, taskKey) {
    addEntry(taskKey, [
      'echo',
      'echo -e "${styleBold.wrap("TASK: $taskKey")}"',
      dartTask.command
    ]);
  });

  taskEntries.sort();

  addEntry('*', [
    'echo -e "${red.wrap("Not expecting TASK '\${TASK}'. Error!")}"',
    'exit 1'
  ]);

  var envEntries = environmentVars.keys.toList()..sort();

  var matrix = [];
  environmentVars.forEach((envVarEntry, entrySdks) {
    var excludeSdks = sdks.toSet()..removeAll(entrySdks);

    if (excludeSdks.isNotEmpty) {
      if (matrix.isEmpty) {
        matrix.addAll(['', 'matrix:', '  exclude:']);
      }

      for (var sdk in excludeSdks) {
        matrix.add('    - dart: $sdk');
        matrix.add('      env: $envVarEntry');
      }
    }
  });

  if (matrix.isNotEmpty) {
    // Ensure there is a trailing newline after the matrix
    matrix.add('');
  }
  //
  // Write `.travis.yml`
  //
  var travisFile = new File(travisFileName);
  travisFile.writeAsStringSync(_travisYml(sdks, envEntries, matrix.join('\n')));
  stderr.writeln(styleDim.wrap('Wrote `$travisFileName`.'));

  //
  // Write `tool/travis.sh`
  //
  var travisScript = new File(_travisShPath);

  if (!travisScript.existsSync()) {
    travisScript.createSync(recursive: true);
    stderr.writeln(
        yellow.wrap('Make sure to mark `$_travisShPath` as executable.'));
    stderr.writeln(yellow.wrap('  chmod +x $_travisShPath'));
  }

  travisScript.writeAsStringSync(_travisSh(taskEntries));
  // TODO: be clever w/ `travisScript.statSync().mode` to see if it's executable
  stderr.writeln(styleDim.wrap('Wrote `$_travisShPath`.'));
}

final _travisShPath = './tool/travis.sh';

String _travisPath(String pkgName) =>
    p.join(p.current, pkgName, travisFileName);

String _indentAndJoin(Iterable<String> items) =>
    items.map((i) => '  - $i').join('\n');

String _travisSh(Iterable<String> tasks) => '''
#!/bin/bash
# Created with https://github.com/dart-lang/mono_repo

# Fast fail the script on failures.
set -e

if [ -z "\$PKG" ]; then
  echo -e "${red.wrap("PKG environment variable must be set!")}"
  exit 1
elif [ -z "\$TASK" ]; then
  echo -e "${red.wrap("TASK environment variable must be set!")}"
  exit 1
fi

pushd \$PKG
pub upgrade

case \$TASK in
${tasks.join('\n')}
esac
''';

String _travisYml(
        Iterable<String> sdks, Iterable<String> envs, String matrix) =>
    '''
# Created with https://github.com/dart-lang/mono_repo
language: dart

dart:
${_indentAndJoin(sdks)}

env:
${_indentAndJoin(envs)}
$matrix
script: $_travisShPath

# Only building master means that we don't run two builds for each pull request.
branches:
  only: [master]

cache:
 directories:
   - \$HOME/.pub-cache
''';