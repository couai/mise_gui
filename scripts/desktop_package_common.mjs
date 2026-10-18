import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT_DIR = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
);
export const APP_DISPLAY_NAME = 'DevWorkbench';
export const BINARY_NAME = 'mise_gui';

export function dateStamp() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

export function readPubspecVersion() {
  const pubspecPath = path.join(ROOT_DIR, 'pubspec.yaml');
  const content = fs.readFileSync(pubspecPath, 'utf8');
  const match = content.match(/^version:\s*([^\s#]+)/m);
  return match?.[1] ?? '0.0.0+0';
}

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

export function recreateDir(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
  ensureDir(dir);
}

export function copyDirectory(source, target) {
  fs.cpSync(source, target, {
    recursive: true,
    force: true,
    errorOnExist: false,
    preserveTimestamps: true,
  });
}

export function commandExists(command) {
  const probe = process.platform === 'win32' ? 'where' : 'command';
  const args = process.platform === 'win32' ? [command] : ['-v', command];
  const result = spawnSync(probe, args, {
    cwd: ROOT_DIR,
    stdio: 'ignore',
    shell: process.platform !== 'win32',
  });
  return result.status === 0;
}

export function run(command, args, options = {}) {
  console.log(`$ ${[command, ...args].join(' ')}`);
  const result = spawnSync(command, args, {
    cwd: ROOT_DIR,
    stdio: 'inherit',
    shell: process.platform === 'win32',
    ...options,
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`Command failed with exit code ${result.status}: ${command}`);
  }
}

export function runFlutterBuild(target) {
  if (process.env.SKIP_FLUTTER_BUILD === '1') {
    console.log(`SKIP_FLUTTER_BUILD=1, using existing ${target} build output.`);
    return;
  }

  if (process.env.USE_MISE !== '0' && commandExists('mise')) {
    run('mise', ['exec', '--', 'flutter', 'build', target, '--release']);
    return;
  }

  run('flutter', ['build', target, '--release']);
}

export function findExistingDir(candidates, description) {
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) {
    throw new Error(
      `Could not find ${description}. Checked:\n${candidates.join('\n')}`,
    );
  }
  return found;
}

export function inferArchFromBuildPath(buildDir, platformName) {
  const pattern = new RegExp(`${platformName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[/\\\\]([^/\\\\]+)[/\\\\]`);
  const match = buildDir.match(pattern);
  return match?.[1] ?? process.arch;
}

export function makeTempStage(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export function zipDirectory(sourceDir, zipPath) {
  const parent = path.dirname(sourceDir);
  const name = path.basename(sourceDir);
  fs.rmSync(zipPath, { force: true });

  if (process.platform === 'win32') {
    const powershell = commandExists('pwsh') ? 'pwsh' : 'powershell.exe';
    run(
      powershell,
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'Compress-Archive -LiteralPath $env:ZIP_SOURCE -DestinationPath $env:ZIP_DEST -Force',
      ],
      {
        env: {
          ...process.env,
          ZIP_SOURCE: sourceDir,
          ZIP_DEST: zipPath,
        },
      },
    );
    return;
  }

  if (!commandExists('zip')) {
    throw new Error('The zip command is required to create a .zip package.');
  }
  run('zip', ['-r', '-q', zipPath, name], { cwd: parent });
}

export function tarGzDirectory(sourceDir, tarPath) {
  const parent = path.dirname(sourceDir);
  const name = path.basename(sourceDir);
  fs.rmSync(tarPath, { force: true });
  run('tar', ['-czf', tarPath, name], { cwd: parent });
}

export function printArtifact(artifactPath) {
  console.log(artifactPath);
}
