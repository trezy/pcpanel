import { app, dialog } from 'electron';
import * as path from 'path';
import * as fs from 'fs';
import * as sudo from 'sudo-prompt';

const DRIVER_NAME = 'PCPanelAudio.driver';
const INSTALL_PATH = '/Library/Audio/Plug-Ins/HAL';

// Track if this is the first launch (for determining whether to show full dialogs or toasts)
function getFirstLaunchFlag(): string {
  return path.join(app.getPath('userData'), '.first-launch-complete');
}

export function isFirstLaunch(): boolean {
  return !fs.existsSync(getFirstLaunchFlag());
}

export function markFirstLaunchComplete(): void {
  const flagPath = getFirstLaunchFlag();
  const dir = path.dirname(flagPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(flagPath, new Date().toISOString());
}

export function isDriverInstalled(): boolean {
  const driverPath = path.join(INSTALL_PATH, DRIVER_NAME);
  return fs.existsSync(driverPath);
}

export function getDriverVersion(): string | null {
  const plistPath = path.join(INSTALL_PATH, DRIVER_NAME, 'Contents', 'Info.plist');
  if (!fs.existsSync(plistPath)) return null;
  // Could parse plist for version, for now just check existence
  return '1.0.0';
}

export function getBundledDriverPath(): string {
  // In packaged app, resources are in process.resourcesPath
  // In development, use the build output
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'driver', DRIVER_NAME);
  } else {
    return path.join(__dirname, '../../../driver/build', DRIVER_NAME);
  }
}

export async function installDriver(): Promise<{ success: boolean; error?: string }> {
  const bundledDriver = getBundledDriverPath();

  if (!fs.existsSync(bundledDriver)) {
    return { success: false, error: `Driver not found at: ${bundledDriver}` };
  }

  const commands = [
    `cp -R "${bundledDriver}" "${INSTALL_PATH}/"`,
    'launchctl kickstart -k system/com.apple.audio.coreaudiod'
  ].join(' && ');

  return new Promise((resolve) => {
    sudo.exec(commands, { name: 'PC Panel Pro' }, (error) => {
      if (error) {
        resolve({ success: false, error: error.message });
      } else {
        resolve({ success: true });
      }
    });
  });
}

export async function promptAndInstallDriver(): Promise<boolean> {
  const result = await dialog.showMessageBox({
    type: 'info',
    title: 'Audio Driver Installation',
    message: 'PC Panel Pro needs to install an audio driver',
    detail: 'This driver creates virtual audio devices that allow per-app volume control. You\'ll be prompted for your password to complete the installation.',
    buttons: ['Install Driver', 'Cancel'],
    defaultId: 0,
    cancelId: 1
  });

  if (result.response === 1) {
    return false;
  }

  const installResult = await installDriver();

  if (!installResult.success) {
    await dialog.showMessageBox({
      type: 'error',
      title: 'Installation Failed',
      message: 'Failed to install the audio driver',
      detail: installResult.error || 'Unknown error occurred'
    });
    return false;
  }

  await dialog.showMessageBox({
    type: 'info',
    title: 'Installation Complete',
    message: 'Audio driver installed successfully',
    detail: 'The virtual audio devices are now available in System Settings > Sound.'
  });

  return true;
}

export async function showDriverNotInstalledWarning(): Promise<void> {
  await dialog.showMessageBox({
    type: 'warning',
    title: 'Limited Functionality',
    message: 'Audio driver not installed',
    detail: 'Per-app volume control will not work without the audio driver. You can install it later from the app menu.'
  });
}
