import path from 'path';
import { FileUtil, hvigor } from '@ohos/hvigor';

const flutterPluginDependencies = path.join(__dirname, '..', '.flutter-plugins-dependencies');
const flutterPluginDependenciesContent = FileUtil.readFileSync(flutterPluginDependencies);
const flutterPluginDependenciesJson = JSON.parse(flutterPluginDependenciesContent);
const ohosPlugins = flutterPluginDependenciesJson['plugins']['ohos'] ?? [];
if (ohosPlugins) {
    const hvigorConfig = hvigor.getHvigorConfig();
    ohosPlugins.forEach((plugin) => {
        const srcPath = path.join(path.relative(__dirname, plugin['path']), 'ohos')
        hvigorConfig.includeNode(plugin['name'], srcPath);
    });
}