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

import 'dart:convert';

import 'package:json5/json5.dart';

import '../artifacts.dart';
import '../base/file_system.dart';
import '../build_info.dart';
import '../flutter_plugins.dart';
import '../globals.dart' as globals;
import '../platform_plugins.dart';
import '../plugins.dart';
import '../project.dart';

/// 检查 ohos plugin 依赖
Future<void> checkOhosPluginsDependencies(FlutterProject flutterProject) async {
  // 复制 flutter.har
  final String artifactHarPath = globals.artifacts!.getArtifactPath(
    Artifact.flutterHar,
    platform: getTargetPlatformForName(
        getPlatformNameForOhosArch(OhosArch.arm64_v8a)),
    mode: BuildMode.debug,
  );
  final String desHarPath = globals.fs.path.join(
      flutterProject.ohos.ohosRoot.path, 'har', 'flutter.har');
  ensureParentExists(desHarPath);
  final File originHarFile = globals.localFileSystem.file(artifactHarPath);
  originHarFile.copySync(desHarPath);

  final List<Plugin> plugins = (await findPlugins(flutterProject))
      .where((Plugin p) => p.platforms.containsKey(OhosPlugin.kConfigKey))
      .toList();
  final File packageFile = flutterProject.ohos.flutterModulePackageFile;
  if (!packageFile.existsSync()) {
    globals.logger.printTrace('check if oh-package.json5 file:($packageFile) exist ?');
    return;
  }

  final String packageConfig = packageFile.readAsStringSync();
  final Map<String, dynamic> config = JSON5.parse(packageConfig) as Map<String, dynamic>;
  final Map<String, dynamic> dependencies =
      config['dependencies'] as Map<String, dynamic>;
  final List<String> removeList = <String>[];
  for (final Plugin plugin in plugins) {
    for (final String key in dependencies.keys) {
      if (key.startsWith('@ohos') && key.contains(plugin.name)) {
        removeList.add(key);
      }
    }
    final String pluginOhosPath = globals.fs.path.join(plugin.path, OhosPlugin.kConfigKey);
    dependencies[plugin.name] = 'file:$pluginOhosPath';
  }
  for (final String key in removeList) {
    globals.printStatus(
        'OhosDependenciesManager: deprecated plugin dependencies "$key" has been removed.');
    dependencies.remove(key);
  }
  final String configNew = const JsonEncoder.withIndent('  ').convert(config);
  packageFile.writeAsStringSync(configNew, flush: true);
}

void ensureParentExists(String path) {
  final Directory directory = globals.localFileSystem.file(path).parent;
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
}
