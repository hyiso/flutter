import { hvigor, HvigorNode, HvigorTaskContext } from '@ohos/hvigor';
import fs from 'fs';
import { platform } from 'node:process';
import path from 'path';
import { execSync } from 'child_process';

/** The platforms that can be passed to the `--Ptarget-platform` flag. */
const PLATFORM_ARM64  = "ohos-arm64";
const PLATFORM_X64    = "ohos-x64";

/** The ABI architectures supported by Flutter. */
const ARCH_ARM64      = "arm64-v8a";
const ARCH_X64        = "x86_64";

const INTERMEDIATES_DIR = "intermediates";

/** Maps platforms to ABI architectures. */
const PLATFORM_ARCH_MAP = {
  [PLATFORM_ARM64]    : ARCH_ARM64,
  [PLATFORM_X64]      : ARCH_X64,
}

/** When split is enabled, multiple APKs are generated per each ABI. */
const DEFAULT_PLATFORMS = [
  PLATFORM_ARM64,
  PLATFORM_X64,
]

const FLUTTER_ROOT = path.join(__dirname, '..', '..', '..');

function getTargetPlatforms(): string[] {
  if (hvigor.getParameter().getExtParams().targetPlatform) {
    return hvigor.getParameter().getExtParams().targetPlatform.split(',').filter(platform => PLATFORM_ARCH_MAP[platform]);
  }
  return DEFAULT_PLATFORMS;
}

function getBuildMode(): string {
  return hvigor.getParameter().getExtParams().debuggable === 'false' ? 'release' : 'debug';
}

function copyAppSoToLibs(buildDir: string, modulePath: string) {
  const buildMode = getBuildMode();
  const targetPlatforms = getTargetPlatforms();
  for (const platform of targetPlatforms) {
    const arch = PLATFORM_ARCH_MAP[platform];
    const sourceAppSo = path.join(buildDir, INTERMEDIATES_DIR, 'flutter', buildMode, arch, 'app.so');
    const targetAppSo = path.join(modulePath, 'libs', arch, 'libapp.so');
    if (!fs.existsSync(path.dirname(targetAppSo))) {
      fs.mkdirSync(path.dirname(targetAppSo), {recursive: true});
    }
    fs.copyFileSync(sourceAppSo, targetAppSo);
  }
}

function cleanAppSoInLibs(modulePath: string) {
  const targetPlatforms = getTargetPlatforms();
  for (const platform of targetPlatforms) {
    const arch = PLATFORM_ARCH_MAP[platform];
    const targetAppSo = path.join(modulePath, 'libs', arch, 'libapp.so');
    if (fs.existsSync(targetAppSo)) {
      fs.rmSync(targetAppSo, {force: true});
    }
  }
}

function getBuildDir(modulePath: string, product = 'default'): string {
  return path.join(modulePath, 'build', product);
}

function getOhosRoot(modulePath: string): string {
  return path.dirname(modulePath);
}

function getFlutterAssetsDir(modulePath: string): string {
  return path.join(modulePath, 'src', 'main', 'resources', 'rawfile', 'flutter_assets');
}

function flutterAssemble(buildDir: string, sourceRoot: string) {
  const buildParams = hvigor.getParameter().getExtParams();
  const buildMode = getBuildMode();
  const intermediateDir = path.join(buildDir, INTERMEDIATES_DIR, 'flutter', buildMode);
  const ruleNames = buildMode === 'debug' ? ['debug_ohos_application'] : getTargetPlatforms().map(platform => `ohos_aot_bundle_${buildMode}_${platform}`);

  const flutterExecutable = platform === 'win32' ? 'flutter.bat' : 'flutter';
  const commands = [
    path.join(FLUTTER_ROOT, 'bin', flutterExecutable),
    'assemble',
    buildParams.verbose === 'true' ? '--verbose' : '--quiet',
    '--no-version-check',
    `--depfile=${path.join(intermediateDir, 'flutter_build.d')}`,
    `--output=${intermediateDir}`,
    '-dTargetPlatform=ohos-arm64',
    `-dTargetFile=${buildParams.target ?? 'lib/main.dart'}`,
    `-dBuildMode=${buildMode}`,
    ...ruleNames,
  ];
  if (buildParams.localEngine) {
    commands.push(`--local-engine=${buildParams.localEngine}`);
  }
  if (buildParams.performanceMeasurementFile) {
    commands.push(`--performance-measurement-file=${buildParams.performanceMeasurementFile}`);
  }
  if (buildParams.trackWidgetCreation) {
    commands.push(`-dTrackWidgetCreation=${buildParams.trackWidgetCreation}`);
  }
  if (buildParams.splitDebugInfo) {
    commands.push(`-dSplitDebugInfo=${buildParams.splitDebugInfo}`);
  }
  if (buildParams.treeShakeIcons === 'true') {
    commands.push(`-dTreeShakeIcons=true`);
  }
  if (buildParams.dartObfuscation === 'true') {
    commands.push(`-dDartObfuscation=true`);
  }
  if (buildParams.dartDefines) {
    commands.push(`--DartDefines=${buildParams.dartDefines}`);
  }
  if (buildParams.bundleSkSLPath) {
    commands.push(`-dBundleSkSLPath=${buildParams.bundleSkSLPath}`);
  }
  if (buildParams.codeSizeDirectory) {
    commands.push(`-dCodeSizeDirectory=${buildParams.codeSizeDirectory}`);
  }
  if (buildParams.extraGenSnapshotOptions) {
    commands.push(`--ExtraGenSnapshotOptions=${buildParams.extraGenSnapshotOptions}`);
  }
  if (buildParams.extraFrontEndOptions) {
    commands.push(`--ExtraFrontEndOptions=${buildParams.extraFrontEndOptions}`);
  }
  console.log('flutter assemble commands:', commands.join(' '));
  execSync(
    commands.join(' '),
    {
      cwd: sourceRoot,
      stdio: 'inherit',
    },
  );

}

class FlutterPlugin {
  pluginId: string = 'FlutterPlugin';
  apply(node: HvigorNode) {
    node.registerTask({
      name: 'CompileFlutter',
      postDependencies: [
        'default@ProcessLibs',
      ],

      run(taskContext: HvigorTaskContext) {
        const buildDir = getBuildDir(taskContext.modulePath);
        const sourceRoot = path.dirname(getOhosRoot(taskContext.modulePath));
        flutterAssemble(buildDir, sourceRoot);
      },

      afterRun(taskContext: HvigorTaskContext) {
        console.log('CompileFlutter afterRun');
        const buildMode = getBuildMode();
        const buildDir = getBuildDir(taskContext.modulePath);
        const intermediateDir = path.join(buildDir, 'intermediates', 'flutter', buildMode);
        const compiledFlutterAssets = path.join(intermediateDir, 'flutter_assets');
        const targetFlutterAssets = getFlutterAssetsDir(taskContext.modulePath);
        if (!fs.existsSync(targetFlutterAssets)) {
          fs.mkdirSync(targetFlutterAssets, {recursive: true});
        }
        // copy compiled flutter_assets to target
        fs.cpSync(compiledFlutterAssets, targetFlutterAssets, {recursive: true});
        if (buildMode === 'release') {
          // copy app.so to target
          copyAppSoToLibs(buildDir, taskContext.modulePath);
        }
        hvigor.buildFinished(() => {
          if (fs.existsSync(targetFlutterAssets)) {
            fs.rmSync(targetFlutterAssets, {recursive: true, force: true});
          }
          if (buildMode === 'release') {
            cleanAppSoInLibs(taskContext.modulePath);
          }
        })
      }
    });
  }
}

export const plugins = [new FlutterPlugin()];