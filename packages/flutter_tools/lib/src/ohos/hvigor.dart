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

import 'dart:io';

import 'package:json5/json5.dart';
import 'package:process/process.dart';

import '../artifacts.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/os.dart';
import '../base/platform.dart' as base_platform;
import '../base/process.dart';
import '../base/terminal.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../build_system/build_system.dart';
import '../build_system/targets/ohos.dart';
import '../cache.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../reporting/reporting.dart';
import 'application_package.dart';
import 'hvigor_utils.dart';
import 'ohos_builder.dart';
import 'ohos_plugins_manager.dart';

const String OHOS_DTA_FILE_NAME = 'icudtl.dat';

const String FLUTTER_ASSETS_PATH = 'flutter_assets';

const String APP_SO_ORIGIN = 'app.so';

const String APP_SO = 'libapp.so';

const String HAR_FILE_NAME = 'flutter.har';

final bool isWindows = globals.platform.isWindows;

String getHvigorwFile() => isWindows ? 'hvigorw.bat' : 'hvigorw';

void checkPlatformEnvironment(String environment, Logger? logger) {
  final String? environmentConfig = Platform.environment[environment];
  if (environmentConfig == null) {
    throwToolExit(
        'error:current platform environment $environment have not set');
  } else {
    logger?.printStatus(
        'current platform environment $environment = $environmentConfig');
  }
}

void copyFlutterAssets(String orgPath, String desPath, Logger? logger) {
  logger?.printTrace('copy from "$orgPath" to "$desPath"');
  final LocalFileSystem localFileSystem = globals.localFileSystem;
  copyDirectory(
      localFileSystem.directory(orgPath), localFileSystem.directory(desPath));
}

/// eg:entry/src/main/resources/rawfile
String getProjectAssetsPath(String ohosRootPath, OhosProject ohosProject) {
  return globals.fs.path.join(ohosProject.flutterModuleDirectory.path,
      'src/main/resources/rawfile', FLUTTER_ASSETS_PATH);
}

/// eg:entry/src/main/resources/rawfile/flutter_assets/
String getDatPath(String ohosRootPath, OhosProject ohosProject) {
  return globals.fs.path.join(
      getProjectAssetsPath(ohosRootPath, ohosProject), OHOS_DTA_FILE_NAME);
}

/// eg:entry/libs/arm64-v8a/libapp.so
String getAppSoPath(
    String ohosRootPath, OhosArch ohosArch, OhosProject ohosProject) {
  return globals.fs.path.join(ohosProject.flutterModuleDirectory.path, 'libs',
      getNameForOhosArch(ohosArch), APP_SO);
}

String getHvigorwPath(String ohosRootPath, {bool checkMod = false}) {
  final String hvigorwPath =
      globals.fs.path.join(ohosRootPath, getHvigorwFile());
  if (globals.fs.file(hvigorwPath).existsSync()) {
    if (checkMod) {
      final OperatingSystemUtils operatingSystemUtils = globals.os;
      final File file = globals.localFileSystem.file(hvigorwPath);
      operatingSystemUtils.chmod(file, '755');
    }
    return hvigorwPath;
  } else {
    return 'hvigorw';
  }
}

String getAbsolutePath(FlutterProject flutterProject, String path) {
  if (globals.fs.path.isRelative(path)) {
    return globals.fs.path.join(flutterProject.directory.path, path);
  }
  return path;
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

/// 根据来源，替换关键字，输出target文件
void replaceKey(File file, File target, String key, String value) {
  String content = file.readAsStringSync();
  content = content.replaceAll(key, value);
  target.writeAsStringSync(content);
}

///hvigorw任务
Future<int> hvigorwTask(List<String> taskCommand,
    {required ProcessUtils processUtils,
    required String workPath,
    required String hvigorwPath,
    Logger? logger}) async {
  final RunResult result = processUtils.runSync(taskCommand,
      workingDirectory: workPath, throwOnError: true);
  return result.exitCode;
}

Future<int> assembleHap(
    {required ProcessUtils processUtils,
    required String ohosRootPath,
    required String hvigorwPath,
    required String flavor,
    required String buildMode,
    Logger? logger}) async {
  final List<String> command = <String>[
    hvigorwPath,
    // 'clean',
    'assembleHap',
    '-p',
    'product=$flavor',
    '-p',
    'buildMode=$buildMode',
    '--no-daemon',
  ];
  return hvigorwTask(command,
      processUtils: processUtils,
      workPath: ohosRootPath,
      hvigorwPath: hvigorwPath,
      logger: logger);
}

Future<int> assembleApp(
    {required ProcessUtils processUtils,
    required String ohosRootPath,
    required String hvigorwPath,
    required String flavor,
    required String buildMode,
    Logger? logger}) async {
  final List<String> command = <String>[
    hvigorwPath,
    // 'clean',
    'assembleApp',
    '-p',
    'product=$flavor',
    '-p',
    'buildMode=$buildMode',
    '--no-daemon',
  ];
  return hvigorwTask(command,
      processUtils: processUtils,
      workPath: ohosRootPath,
      hvigorwPath: hvigorwPath,
      logger: logger);
}

Future<int> assembleHar(
    {required ProcessUtils processUtils,
    required String workPath,
    required String hvigorwPath,
    required String moduleName,
    required String buildMode,
    String product = 'default',
    Logger? logger}) async {
  final List<String> command = <String>[
    hvigorwPath,
    // 'clean',
    '--mode',
    'module',
    '-p',
    'module=$moduleName',
    '-p',
    'product=$product',
    'assembleHar',
    '--no-daemon',
  ];
  return hvigorwTask(command,
      processUtils: processUtils,
      workPath: workPath,
      hvigorwPath: hvigorwPath,
      logger: logger);
}

Future<int> assembleHsp(
    {required ProcessUtils processUtils,
    required String workPath,
    required String hvigorwPath,
    required String moduleName,
    required String flavor,
    required String buildMode,
    Logger? logger}) async {
  final List<String> command = <String>[
    hvigorwPath,
    // 'clean',
    '--mode',
    'module',
    '-p',
    'module=$moduleName',
    '-p',
    'product=$flavor',
    '-p',
    'buildMode=$buildMode',
    'assembleHsp',
    '--no-daemon',
  ];
  return hvigorwTask(command,
      processUtils: processUtils,
      workPath: workPath,
      hvigorwPath: hvigorwPath,
      logger: logger);
}

/// flutter构建
Future<String> flutterAssemble(FlutterProject flutterProject,
    OhosBuildInfo ohosBuildInfo, String targetFile) async {
  late String targetName;
  if (ohosBuildInfo.buildInfo.isDebug) {
    targetName = 'debug_ohos_application';
  } else if (ohosBuildInfo.buildInfo.isProfile) {
    // eg:ohos_aot_bundle_profile_ohos-arm64
    targetName =
        'ohos_aot_bundle_profile_${getPlatformNameForOhosArch(ohosBuildInfo.targetArchs.first)}';
  } else {
    // eg:ohos_aot_bundle_release_ohos-arm64
    targetName =
        'ohos_aot_bundle_release_${getPlatformNameForOhosArch(ohosBuildInfo.targetArchs.first)}';
  }
  final List<Target> selectTarget =
      ohosTargets.where((Target e) => targetName == e.name).toList();
  if (selectTarget.isEmpty) {
    throwToolExit('do not found compare target.');
  } else if (selectTarget.length > 1) {
    throwToolExit('more than one target match.');
  }
  final Target target = selectTarget[0];

  final Status status =
      globals.logger.startProgress('Compiling $targetName for the Ohos...');
  String output = globals.fs.directory(getOhosBuildDirectory()).path;
  // If path is relative, make it absolute from flutter project.
  output = getAbsolutePath(flutterProject, output);
  try {
    final BuildResult result = await globals.buildSystem.build(
        target,
        Environment(
          projectDir: globals.fs.currentDirectory,
          outputDir: globals.fs.directory(output),
          buildDir: flutterProject.directory
              .childDirectory('.dart_tool')
              .childDirectory('flutter_build'),
          defines: <String, String>{
            ...ohosBuildInfo.buildInfo.toBuildSystemEnvironment(),
            kTargetFile: targetFile,
            kTargetPlatform: getNameForTargetPlatform(TargetPlatform.ohos_arm64),
          },
          analytics: globals.analytics,
          artifacts: globals.artifacts!,
          fileSystem: globals.fs,
          logger: globals.logger,
          processManager: globals.processManager,
          platform: globals.platform,
          usage: globals.flutterUsage,
          cacheDir: globals.cache.getRoot(),
          engineVersion: globals.artifacts!.isLocalEngine
              ? null
              : globals.flutterVersion.engineRevision,
          flutterRootDir: globals.fs.directory(Cache.flutterRoot),
          generateDartPluginRegistry: true,
        ));
    if (!result.success) {
      for (final ExceptionMeasurement measurement in result.exceptions.values) {
        globals.printError(
          'Target ${measurement.target} failed: ${measurement.exception}',
          stackTrace: measurement.fatal ? measurement.stackTrace : null,
        );
      }
      throwToolExit('Failed to compile application for the Ohos.');
    } else {
      return output;
    }
  } on Exception catch (err) {
    throwToolExit(err.toString());
  } finally {
    status.stop();
  }
}

/// 清理和拷贝flutter产物和资源
void cleanAndCopyFlutterAsset(
    OhosProject ohosProject,
    OhosBuildInfo ohosBuildInfo,
    Logger? logger,
    String ohosRootPath,
    String output) {
  logger?.printTrace('copy flutter assets to project start');
  // clean flutter assets
  final String desFlutterAssetsPath =
      getProjectAssetsPath(ohosRootPath, ohosProject);
  final Directory desAssets = globals.fs.directory(desFlutterAssetsPath);
  if (desAssets.existsSync()) {
    desAssets.deleteSync(recursive: true);
  }

  /// copy flutter assets
  copyFlutterAssets(globals.fs.path.join(output, FLUTTER_ASSETS_PATH),
      desFlutterAssetsPath, logger);

  final String desAppSoPath =
      getAppSoPath(ohosRootPath, ohosBuildInfo.targetArchs.first, ohosProject);
  if (ohosBuildInfo.buildInfo.isRelease || ohosBuildInfo.buildInfo.isProfile) {
    // copy app.so
    final String appSoPath = globals.fs.path.join(output,
        getNameForOhosArch(ohosBuildInfo.targetArchs.first), APP_SO_ORIGIN);
    final File appSoFile = globals.localFileSystem.file(appSoPath);
    ensureParentExists(desAppSoPath);
    appSoFile.copySync(desAppSoPath);
  } else {
    final File appSo = globals.fs.file(desAppSoPath);
    if (appSo.existsSync()) {
      appSo.deleteSync();
    }
  }
  logger?.printTrace('copy flutter assets to project end');
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
  final String localEngineHarPath = globals.artifacts!.getArtifactPath(
    Artifact.flutterHar,
    platform: getTargetPlatformForName(
        getPlatformNameForOhosArch(ohosBuildInfo.targetArchs.first)),
    mode: ohosBuildInfo.buildInfo.mode,
  );
  final String desHarPath =
      globals.fs.path.join(ohosRootPath, 'har', HAR_FILE_NAME);
  ensureParentExists(desHarPath);
  final File originHarFile = globals.localFileSystem.file(localEngineHarPath);
  originHarFile.copySync(desHarPath);
  logger?.printTrace('copy from "$localEngineHarPath" to "$desHarPath"');
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
    required base_platform.Platform platform,
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
    final Status status = _logger.startProgress(
      'Running Hvigor task assembleHap...',
    );

    updateProjectVersion(project, ohosBuildInfo.buildInfo);
    await addPluginsModules(project);
    await addFlutterModuleAndPluginsSrcOverrides(project);

    await buildApplicationPipeLine(project, ohosBuildInfo, target: target);

    final String hvigorwPath = getHvigorwPath(_ohosRootPath, checkMod: true);

    /// 生成所有 plugin 的 har
    await assembleHars(_processUtils, project, ohosBuildInfo, _logger);
    await assembleHsps(_processUtils, project, ohosBuildInfo, _logger);

    await removePluginsModules(project);
    await addFlutterModuleAndPluginsOverrides(project);
    // ohosProject.deleteOhModulesCache();
    await ohpmInstall(
      processUtils: _processUtils,
      workingDirectory: _ohosRootPath,
      logger: _logger,
    );

    /// invoke hvigow task generate hap file.
    final int errorCode = await assembleHap(
        processUtils: _processUtils,
        ohosRootPath: _ohosRootPath,
        hvigorwPath: hvigorwPath,
        flavor: getFlavor(
            _ohosProject.getBuildProfileFile(), ohosBuildInfo.buildInfo.flavor),
        buildMode: ohosBuildInfo.buildInfo.modeName,
        logger: _logger);
    status.stop();
    if (errorCode != 0) {
      throwToolExit('assembleHap error! please check log.');
    }

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
      // final String appSize = (buildInfo.mode == BuildMode.debug)
      //     ? '' // Don't display the size when building a debug variant.
      //     : ' (${getSizeAsMB(bundleFile.lengthSync())})';
      // _logger.printStatus(
      //   '${_logger.terminal.successMark} Built ${_fileSystem.path.relative(bundleFile.path)}$appSize.',
      //   color: TerminalColor.green,
      // );
    }
  }

  Future<void> flutterBuildPre(FlutterProject flutterProject,
      OhosBuildInfo ohosBuildInfo, String target) async {
    /**
     * 1. execute flutter assemble
     * 2. copy flutter asset to flutter module
     * 3. copy flutter runtime
     * 4. ohpm install
     */

    final String output =
        await flutterAssemble(flutterProject, ohosBuildInfo, target);

    cleanAndCopyFlutterAsset(
        _ohosProject, ohosBuildInfo, _logger, _ohosRootPath, output);

    cleanAndCopyFlutterRuntime(
        _ohosProject, ohosBuildInfo, _logger, _ohosRootPath, _ohosBuildData);

    // ohpm install for all modules
    // ohosProject.deleteOhModulesCache();
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

    await addPluginsModules(project);
    await addFlutterModuleAndPluginsSrcOverrides(project);

    parseData(project, _logger);

    await flutterBuildPre(project, ohosBuildInfo, target);

    /// 生成 module 和所有 plugin 的 har
    await assembleHars(_processUtils, project, ohosBuildInfo, _logger);
    await assembleHsps(_processUtils, project, ohosBuildInfo, _logger);

    await removePluginsModules(project);
    await addFlutterModuleAndPluginsOverrides(project);
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
    final Status status = _logger.startProgress(
      'Running Hvigor task assembleApp...',
    );
    updateProjectVersion(project, ohosBuildInfo.buildInfo);
    await buildApplicationPipeLine(project, ohosBuildInfo, target: target);

    final String hvigorwPath = getHvigorwPath(_ohosRootPath, checkMod: true);

    /// invoke hvigow task generate hap file.
    final int errorCode1 = await assembleApp(
        processUtils: _processUtils,
        ohosRootPath: _ohosRootPath,
        flavor: getFlavor(
            _ohosProject.getBuildProfileFile(), ohosBuildInfo.buildInfo.flavor),
        hvigorwPath: hvigorwPath,
        buildMode: ohosBuildInfo.buildInfo.modeName,
        logger: _logger);
    status.stop();
    if (errorCode1 != 0) {
      throwToolExit('assembleApp error! please check log.');
    }
    final BuildInfo buildInfo = ohosBuildInfo.buildInfo;
    final File bundleFile = OhosProject.getSignedFile(
      modulePath: _ohosProject.mainModuleDirectory.path,
      moduleName: _ohosProject.mainModuleName,
      flavor: getFlavor(_ohosProject.getBuildProfileFile(), buildInfo.flavor),
      type: OhosFileType.app,
      throwOnMissing: true,
    );
    // final String appSize = (buildInfo.mode == BuildMode.debug)
    //     ? '' // Don't display the size when building a debug variant.
    //     : ' (${getSizeAsMB(bundleFile.lengthSync())})';
    // _logger.printStatus(
    //   '${_logger.terminal.successMark} Built ${_fileSystem.path.relative(bundleFile.path)}$appSize.',
    //   color: TerminalColor.green,
    // );
  }

  Future<void> buildApplicationPipeLine(
      FlutterProject flutterProject, OhosBuildInfo ohosBuildInfo,
      {required String target}) async {
    if (!flutterProject.ohos.ohosBuildData.moduleInfo.hasEntryModule) {
      throwToolExit(
          "this ohos project don't have a entry module , can't build to a application.");
    }

    parseData(flutterProject, _logger);

    /// 检查plugin的har构建
    await checkOhosPluginsDependencies(flutterProject);

    await flutterBuildPre(flutterProject, ohosBuildInfo, target);

    if (_ohosProject.isRunWithModuleHar) {
      await assembleHars(_processUtils, flutterProject, ohosBuildInfo, _logger);
      await assembleHsps(_processUtils, flutterProject, ohosBuildInfo, _logger);

      /// har文件拷贝后，需要重新install
      // ohosProject.deleteOhModulesCache();
      await ohpmInstall(
          processUtils: _processUtils,
          workingDirectory: _ohosProject.mainModuleDirectory.path,
          logger: _logger);
    }
  }

  String _moduleNameWithFlavor(List<OhosModule> modules, String? flavor) {
    return modules
        .map((OhosModule module) => OhosModule.fromModulePath(
              modulePath: module.srcPath,
              flavor: getFlavor(
                globals.fs.file(globals.fs.path
                    .join(module.srcPath, 'build-profile.json5')),
                flavor,
              ),
            ))
        .map((OhosModule module) => '${module.name}@${module.flavor}')
        .join(',');
  }

  /// 生成所有 plugin 的 har
  Future<void> assembleHars(
    ProcessUtils processUtils,
    FlutterProject project,
    OhosBuildInfo ohosBuildInfo,
    Logger? logger,
  ) async {
    final String ohosProjectPath = project.ohos.ohosRoot.path;
    final List<OhosModule> modules = _ohosBuildData.harModules;
    if (modules.isEmpty) {
      return;
    }

    // compile hars. parallel compilation.
    final String hvigorwPath = getHvigorwPath(ohosProjectPath, checkMod: true);
    final String moduleName =
        _moduleNameWithFlavor(modules, ohosBuildInfo.buildInfo.flavor);
    final int errorCode = await assembleHar(
        processUtils: processUtils,
        workPath: ohosProjectPath,
        moduleName: moduleName,
        hvigorwPath: hvigorwPath,
        buildMode: ohosBuildInfo.buildInfo.modeName,
        logger: logger);
    if (errorCode != 0) {
      throwToolExit('Oops! assembleHars failed! please check log.');
    }

    // copy hars
    for (final OhosModule module in modules) {
      final File originHar = globals.fs.file(globals.fs.path.join(
          module.srcPath,
          'build',
          'default',
          'outputs',
          module.flavor,
          '${module.name}.har'));
      if (!originHar.existsSync()) {
        throwToolExit('Oops! Failed to find: ${originHar.path}');
      }
      final String desPath =
          globals.fs.path.join(ohosProjectPath, 'har', '${module.name}.har');
      ensureParentExists(desPath);
      originHar.copySync(desPath);
    }
  }

  Future<void> assembleHsps(
    ProcessUtils processUtils,
    FlutterProject project,
    OhosBuildInfo ohosBuildInfo,
    Logger? logger,
  ) async {
    final String ohosProjectPath = project.ohos.ohosRoot.path;
    final List<OhosModule> modules = _ohosBuildData.moduleInfo.moduleList
        .where((OhosModule element) => element.type == OhosModuleType.shared)
        .toList();
    if (modules.isEmpty) {
      return;
    }
    final String hvigorwPath = getHvigorwPath(ohosProjectPath, checkMod: true);
    final String moduleName =
        _moduleNameWithFlavor(modules, ohosBuildInfo.buildInfo.flavor);
    final int errorCode = await assembleHsp(
        processUtils: processUtils,
        workPath: ohosProjectPath,
        moduleName: moduleName,
        hvigorwPath: hvigorwPath,
        flavor: getFlavor(
            project.ohos.getBuildProfileFile(), ohosBuildInfo.buildInfo.flavor),
        buildMode: ohosBuildInfo.buildInfo.modeName,
        logger: logger);
    if (errorCode != 0) {
      throwToolExit('Oops! assembleHsps failed! please check log.');
    }
  }
}
