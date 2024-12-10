/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import 'package:json5/json5.dart';
import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/process.dart';
import '../base/terminal.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../platform_plugins.dart';
import '../plugins.dart';
import '../project.dart';
import '../reporting/reporting.dart';
import 'application_package.dart';
import 'hvigor_utils.dart';
import 'ohos_builder.dart';

const String FLUTTER_ASSETS_PATH = 'flutter_assets';

const String HAR_FILE_NAME = 'flutter.har';

/// eg:entry/src/main/resources/rawfile
String getProjectAssetsPath(String ohosRootPath, OhosProject ohosProject) {
  return globals.fs.path.join(ohosProject.flutterModuleDirectory.path,
      'src/main/resources/rawfile', FLUTTER_ASSETS_PATH);
}

/// ohpm should init first
Future<void> ohpmInstall(
    {required ProcessUtils processUtils,
    required String workingDirectory,
    Logger? logger}) async {
  final List<String> cleanCmd = <String>['ohpm', 'clean'];
  final List<String> installCmd = <String>['ohpm', 'install', '--all'];
  processUtils.runSync(cleanCmd,
      workingDirectory: workingDirectory, throwOnError: true);
  processUtils.runSync(installCmd,
      workingDirectory: workingDirectory, throwOnError: true);
}

/// 清理和拷贝flutter运行时
void cleanAndCopyFlutterRuntime(
    OhosProject ohosProject,
    OhosBuildInfo ohosBuildInfo,
    Logger? logger,
    String ohosRootPath,
    OhosBuildData ohosBuildData) {
  logger?.printTrace('copy flutter runtime to project start');

  // 复制 flutter.har
  final String artifactHarPath = globals.artifacts!.getArtifactPath(
    Artifact.flutterHar,
    platform: getTargetPlatformForName(
        getPlatformNameForOhosArch(ohosBuildInfo.targetArchs.first)),
    mode: ohosBuildInfo.buildInfo.mode,
  );
  final String desHarPath =
      globals.fs.path.join(ohosRootPath, 'har', HAR_FILE_NAME);
  ensureParentExists(desHarPath);
  final File originHarFile = globals.localFileSystem.file(artifactHarPath);
  originHarFile.copySync(desHarPath);
  logger?.printTrace('copy from "$artifactHarPath" to "$desHarPath"');
  logger?.printTrace('copy flutter runtime to project end');
}

void ensureParentExists(String path) {
  final Directory directory = globals.localFileSystem.file(path).parent;
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
}

class OhosHvigorBuilder implements OhosBuilder {
  OhosHvigorBuilder({
    required Logger logger,
    required ProcessManager processManager,
    required FileSystem fileSystem,
    required Artifacts artifacts,
    required Usage usage,
    required HvigorUtils hvigorUtils,
    required Platform platform,
  })  : _logger = logger,
        _fileSystem = fileSystem,
        _artifacts = artifacts,
        _usage = usage,
        _hvigorUtils = hvigorUtils,
        _fileSystemUtils =
            FileSystemUtils(fileSystem: fileSystem, platform: platform),
        _processUtils =
            ProcessUtils(logger: logger, processManager: processManager);

  final Logger _logger;
  final ProcessUtils _processUtils;
  final FileSystem _fileSystem;
  final Artifacts _artifacts;
  final Usage _usage;
  final HvigorUtils _hvigorUtils;
  final FileSystemUtils _fileSystemUtils;

  late OhosProject _ohosProject;
  late String _ohosRootPath;
  late OhosBuildData _ohosBuildData;

  void parseData(FlutterProject flutterProject, Logger? logger) {
    _ohosProject = flutterProject.ohos;
    _ohosRootPath = _ohosProject.ohosRoot.path;
    _ohosBuildData = OhosBuildData.parseOhosBuildData(_ohosProject, logger);
  }

  /// build hap
  @override
  Future<void> buildHap({
    required FlutterProject project,
    required OhosBuildInfo ohosBuildInfo,
    required String target,
  }) async {
    _logger.printStatus('start hap build...');

    if (!project.ohos.ohosBuildData.moduleInfo.hasEntryModule) {
      throwToolExit(
          "this ohos project don't have a entry module, can't build to a hap file.");
    }
    _logger.startProgress(
      'Running Hvigor task assembleHap...',
    );

    updateProjectVersion(project, ohosBuildInfo.buildInfo);

    await buildApplicationPipeLine(project, ohosBuildInfo, target: target);
    await hvigorAssemble(
      assembleTask: 'assembleHar',
      project: project,
      ohosBuildInfo: ohosBuildInfo,
      target: target,
    );
    await _copyFlutterPluginsHar(project, globals.fs.path.join(project.ohos.ohosRoot.path, 'har'));
    await ohpmInstall(
      processUtils: _processUtils,
      workingDirectory: _ohosRootPath,
      logger: _logger,
    );
    await hvigorAssemble(
      assembleTask: 'assembleHap',
      project: project,
      ohosBuildInfo: ohosBuildInfo,
      target: target,
    );

    final File buildProfile = project.ohos.getBuildProfileFile();
    final String buildProfileConfig = buildProfile.readAsStringSync();
    final dynamic obj = JSON5.parse(buildProfileConfig);
    // ignore: avoid_dynamic_calls
    final dynamic signingConfigs = obj['app']?['signingConfigs'];
    if (signingConfigs is List && signingConfigs.isEmpty) {
      _logger.printError(
          '请通过DevEco Studio打开ohos工程后配置调试签名(File -> Project Structure -> Signing Configs 勾选Automatically generate signature)');
    } else {
      final BuildInfo buildInfo = ohosBuildInfo.buildInfo;
      final File bundleFile = OhosProject.getSignedFile(
        modulePath: _ohosProject.mainModuleDirectory.path,
        moduleName: _ohosProject.mainModuleName,
        flavor: getFlavor(_ohosProject.getBuildProfileFile(), buildInfo.flavor),
        throwOnMissing: true,
      );
      final String appSize = (buildInfo.mode == BuildMode.debug)
          ? '' // Don't display the size when building a debug variant.
          : ' (${getSizeAsPlatformMB(bundleFile.lengthSync())})';
      _logger.printStatus(
        '${_logger.terminal.successMark} Built ${_fileSystem.path.relative(bundleFile.path)}$appSize.',
        color: TerminalColor.green,
      );
    }
  }

  Future<void> flutterBuildPre(FlutterProject flutterProject,
      OhosBuildInfo ohosBuildInfo, String target) async {
    /**
     * 3. copy flutter runtime
     * 4. ohpm install
     */

    cleanAndCopyFlutterRuntime(flutterProject.ohos, ohosBuildInfo, _logger, flutterProject.ohos.ohosRoot.path, flutterProject.ohos.ohosBuildData);

    // ohpm install for all modules
    await ohpmInstall(
      processUtils: _processUtils,
      workingDirectory: _ohosRootPath,
      logger: _logger,
    );
  }

  @override
  Future<void> buildHar({
    required FlutterProject project,
    required OhosBuildInfo ohosBuildInfo,
    required String target,
  }) async {
    if (!project.isModule ||
        !project.ohos.flutterModuleDirectory.existsSync()) {
      throwToolExit('current project is not module or has not pub get');
    }

    final Status status = _logger.startProgress(
      'Running Hvigor task assembleHar...',
    );

    parseData(project, _logger);

    await flutterBuildPre(project, ohosBuildInfo, target);

    await hvigorAssemble(
      assembleTask: 'assembleHar',
      project: project,
      ohosBuildInfo: ohosBuildInfo,
      target: target,
    );
    await _copyFlutterPluginsHar(project, globals.fs.path.join(project.ohos.ohosRoot.path, 'har'));
    status.stop();
    printHowToConsumeHar(logger: _logger);
  }

  /// Prints how to consume the har from a host app.
  void printHowToConsumeHar({
    Logger? logger,
  }) {
    logger?.printStatus('\nConsuming the Module', emphasis: true);
    logger?.printStatus('''
    1. Open ${globals.fs.path.join('<host project>', 'oh-package.json5')}
    2. Add flutter_module to the dependencies list:

      "dependencies": {
        "@ohos/flutter_module": "file:path/to/har/flutter_module.har"
      }

    3. Override flutter and plugins dependencies:

      "overrides" {
        "@ohos/flutter_ohos": "file:path/to/har/flutter.har",
      }
  ''');
  }

  @override
  Future<void> buildHsp({
    required FlutterProject project,
    required OhosBuildInfo ohosBuildInfo,
    required String target,
  }) {
    // TODO: implement buildHsp
    throw UnimplementedError();
  }

  @override
  Future<void> buildApp({
    required FlutterProject project,
    required OhosBuildInfo ohosBuildInfo,
    required String target,
  }) async {
    _logger.startProgress(
      'Running Hvigor task assembleApp...',
    );
    updateProjectVersion(project, ohosBuildInfo.buildInfo);
    await buildApplicationPipeLine(project, ohosBuildInfo, target: target);
    await hvigorAssemble(
      assembleTask: 'assembleApp',
      project: project,
      ohosBuildInfo: ohosBuildInfo,
      target: target,
    );
  }

  Future<void> buildApplicationPipeLine(
      FlutterProject flutterProject, OhosBuildInfo ohosBuildInfo,
      {required String target}) async {
    if (!flutterProject.ohos.ohosBuildData.moduleInfo.hasEntryModule) {
      throwToolExit(
          "this ohos project don't have a entry module , can't build to a application.");
    }

    parseData(flutterProject, _logger);

    await flutterBuildPre(flutterProject, ohosBuildInfo, target);

    if (flutterProject.ohos.isRunWithModuleHar) {
      await hvigorAssemble(
        assembleTask: 'assembleHar',
        project: flutterProject,
        ohosBuildInfo: ohosBuildInfo,
        target: target,
      );

      final File originHar = flutterProject.ohos.flutterModuleDirectory
          .childDirectory('build')
          .childDirectory('default')
          .childDirectory('outputs')
          .childDirectory('default')
          .childFile('${flutterProject.ohos.flutterModuleName}.har');
      if (!originHar.existsSync()) {
        throwToolExit('Oops! Failed to find: ${originHar.path}');
      }
      final String desPath = globals.fs.path
          .join(flutterProject.ohos.ohosRoot.path, 'har', '${flutterProject.ohos.flutterModuleName}.har');
      ensureParentExists(desPath);
      originHar.copySync(desPath);

      /// har文件拷贝后，需要重新install
      await ohpmInstall(
          processUtils: _processUtils,
          workingDirectory: _ohosProject.mainModuleDirectory.path,
          logger: _logger);
    }
  }

  Future<void> hvigorAssemble({
    required String assembleTask,
    required FlutterProject project,
    required OhosBuildInfo ohosBuildInfo,
    required String target,
  }) async {
    final BuildInfo buildInfo = ohosBuildInfo.buildInfo;
    final Status status = _logger.startProgress(
      "Running Hvigor task '$assembleTask'...",
    );

    final List<String> command = <String>[
      _hvigorUtils.getExecutable(project),
      '--no-daemon',
    ];
    if (_logger.isVerbose) {
      command.add('--stacktrace');
      command.add('--info');
      command.addAll(<String>['-p', 'verbose=true']);
    }
    if (buildInfo.isDebug) {
      command.addAll(<String>['-p', 'debuggable=true']);
    } else {
      command.addAll(<String>['-p', 'debuggable=false']);
    }
    if (target.isNotEmpty) {
      command.addAll(<String>['-p', 'target=$target']);
    }
    command.addAll(buildInfo.toHvigorConfig());
    if (buildInfo.dartObfuscation && buildInfo.mode != BuildMode.release) {
      _logger.printStatus(
        'Dart obfuscation is not supported in ${sentenceCase(buildInfo.friendlyModeName)}'
            ' mode, building as un-obfuscated.',
      );
    }

    if (_artifacts is CachedLocalEngineArtifacts) {
      _logger.printTrace(
        'Using local engine: ${_artifacts.localEngineInfo.targetOutPath}',
      );
      command.addAll(<String>['-p', 'localEngine=${_artifacts.localEngineInfo.targetOutPath}']);
      command.addAll(<String>['-p', 'targetPlatform=${_getTargetPlatformByLocalEnginePath(
          _artifacts.localEngineInfo.targetOutPath)}']);
    } else if (ohosBuildInfo.targetArchs.isNotEmpty) {
      final String targetPlatforms = ohosBuildInfo.targetArchs
          .map(getPlatformNameForOhosArch).join(',');
      command.addAll(<String>['-p', 'targetPlatform=$targetPlatforms']);
    }
    command.add(assembleTask);
    final Stopwatch sw = Stopwatch()
      ..start();
    RunResult result;
    try {
      final String workingDirectory = assembleTask == 'assembleHar'
          ? project.ohos.ephemeralDirectory.path
          : project.ohos.ohosRoot.path;
      result = await _processUtils.run(
        command,
        workingDirectory: workingDirectory,
        allowReentrantFlutter: true,
      );
    } finally {
      status.stop();
    }
    _usage.sendTiming('build', 'hvigor-har', sw.elapsed);
  if (result.exitCode != 0) {
      _logger.printStatus(result.stdout, wrap: false);
      _logger.printError(result.stderr, wrap: false);
      throwToolExit(
        'Hvigor task $assembleTask failed with exit code ${result.exitCode}.',
        exitCode: result.exitCode,
      );
    }
  }
}

Future<void> _copyFlutterPluginsHar(FlutterProject project, String outputDirectory) async {
  final List<Plugin> plugins = (await findPlugins(project))
      .where((Plugin p) => p.platforms.containsKey(OhosPlugin.kConfigKey))
      .toList();

  for (final Plugin plugin in plugins) {
    final String desHarPath = globals.fs.path.join(outputDirectory, '${plugin.name}.har');
    final File originHar = globals.fs
        .directory(globals.fs.path.join(plugin.path, OhosPlugin.kConfigKey))
        .childDirectory('build')
        .childDirectory('default')
        .childDirectory('outputs')
        .childDirectory('default')
        .childFile('${plugin.name}.har');
    if (!originHar.existsSync()) {
      throwToolExit('Oops! Failed to find: ${originHar.path}');
    }
    ensureParentExists(desHarPath);
    originHar.copySync(desHarPath);
  }

  final File originHar = project.ohos.flutterModuleDirectory
      .childDirectory('build')
      .childDirectory('default')
      .childDirectory('outputs')
      .childDirectory('default')
      .childFile('${project.ohos.flutterModuleName}.har');
  if (!originHar.existsSync()) {
    throwToolExit('Oops! Failed to find: ${originHar.path}');
  }
  final String desPath = globals.fs.path
      .join(project.ohos.ohosRoot.path, 'har', '${project.ohos.flutterModuleName}.har');
  ensureParentExists(desPath);
  originHar.copySync(desPath);
}

String _getTargetPlatformByLocalEnginePath(String engineOutPath) {
  String result = 'ohos-arm64';
  if (engineOutPath.contains('x64')) {
    result = 'ohos-x64';
  } else if (engineOutPath.contains('arm64')) {
    result = 'ohos-arm64';
  }
  return result;
}
