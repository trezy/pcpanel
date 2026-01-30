import { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage, dialog } from 'electron';
import * as path from 'path';
import { scanForDevices, PCPanelConnection, DeviceState, DeviceEvent } from './hid';
import { audioPassthrough } from './audio/passthrough';
import { isDriverInstalled, promptAndInstallDriver, showDriverNotInstalledWarning, isFirstLaunch, markFirstLaunchComplete } from './driver/installer';

let mainWindow: BrowserWindow | null = null;
let connection: PCPanelConnection | null = null;
let scanInterval: NodeJS.Timeout | null = null;
let activityInterval: NodeJS.Timeout | null = null;
let tray: Tray | null = null;
let isQuitting = false;

// Safe logging that won't crash on EPIPE
function log(...args: unknown[]): void {
  try {
    console.log(...args);
  } catch {
    // Ignore write errors
  }
}

function logError(...args: unknown[]): void {
  try {
    console.error(...args);
  } catch {
    // Ignore write errors
  }
}

function createTray(): void {
  // Load the tray icon
  const iconPath = path.join(__dirname, 'assets', 'tray-icon.png');
  const icon = nativeImage.createFromPath(iconPath);

  // For macOS, resize to 16x16 for menu bar (will be displayed at 16x16 or 32x32 on retina)
  const trayIcon = icon.resize({ width: 16, height: 16 });
  trayIcon.setTemplateImage(true); // Makes icon adapt to dark/light mode on macOS

  tray = new Tray(trayIcon);
  tray.setToolTip('PC Panel Pro');

  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'Show Window',
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          mainWindow.focus();
        } else {
          createWindow();
        }
      },
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        isQuitting = true;
        app.quit();
      },
    },
  ]);

  tray.setContextMenu(contextMenu);

  // Click on tray icon shows the window
  tray.on('click', () => {
    if (mainWindow) {
      if (mainWindow.isVisible()) {
        mainWindow.focus();
      } else {
        mainWindow.show();
      }
    } else {
      createWindow();
    }
  });
}

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    useContentSize: true,
    resizable: true,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));

  // Auto-resize window to fit content when ready
  mainWindow.webContents.once('did-finish-load', () => {
    mainWindow?.webContents.executeJavaScript(`
      (function() {
        const body = document.body;
        const html = document.documentElement;
        const width = Math.max(body.scrollWidth, body.offsetWidth, html.clientWidth, html.scrollWidth, html.offsetWidth);
        const height = Math.max(body.scrollHeight, body.offsetHeight, html.clientHeight, html.scrollHeight, html.offsetHeight);
        return { width, height };
      })();
    `).then((size: { width: number; height: number }) => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        // Add some padding and ensure minimum size
        const padding = 40;
        const minWidth = 640;
        const minHeight = 400;
        const newWidth = Math.max(size.width + padding, minWidth);
        const newHeight = Math.max(size.height + padding, minHeight);
        mainWindow.setContentSize(newWidth, newHeight);
        mainWindow.center();
      }
    }).catch(() => {
      // Ignore errors - fallback to default size
    });
  });

  // Hide window instead of closing (keep app running in tray)
  mainWindow.on('close', (event) => {
    if (!isQuitting) {
      event.preventDefault();
      mainWindow?.hide();
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function sendToRenderer(channel: string, data: unknown): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, data);
  }
}

async function connectToDevice(): Promise<void> {
  const devices = await scanForDevices();

  if (devices.length === 0) {
    sendToRenderer('device-status', { connected: false, message: 'No PC Panel found' });
    return;
  }

  const device = devices[0];

  // Log device info
  if (device.isKnown) {
    log(`Found ${device.profile.name}:`, device.path);
  } else if (device.isPotentialPCPanel) {
    log(`Found potential PCPanel device (unknown model):`, device);
    // Notify user about unknown device
    sendToRenderer('toast', {
      type: 'info',
      message: `Unknown PCPanel detected (VID:${device.vendorId.toString(16)} PID:${device.productId.toString(16)}). Please report this!`,
      duration: 5000
    });
  }

  if (connection) {
    connection.disconnect();
  }

  connection = new PCPanelConnection();

  connection.on('connected', () => {
    log(`Connected to ${device.profile.name}`);
    sendToRenderer('device-status', { connected: true, message: `Connected to ${device.profile.name}` });

    // Request current device state to initialize volumes
    setTimeout(() => {
      if (connection) {
        log('Requesting device state...');
        connection.requestState();
      }
    }, 100);
  });

  connection.on('disconnected', () => {
    log(`Disconnected from ${device.profile.name}`);
    sendToRenderer('device-status', { connected: false, message: 'Disconnected' });
  });

  connection.on('event', (event: DeviceEvent) => {
    sendToRenderer('device-event', event);

    // Update volume when knob or slider changes
    if (event.type === 'knob-change') {
      audioPassthrough.setVolumeFromHardware(event.index, event.value);
    } else if (event.type === 'state-response') {
      // Apply all initial volume values from device state
      log('Received device state, applying initial volumes');
      for (let i = 0; i < event.analogValues.length; i++) {
        audioPassthrough.setVolumeFromHardware(i, event.analogValues[i]);
      }
    }
  });

  connection.on('state', (state: DeviceState) => {
    sendToRenderer('device-state', state);
  });

  connection.on('error', (error: Error) => {
    logError('Device error:', error);
    sendToRenderer('device-status', { connected: false, message: `Error: ${error.message}` });
  });

  const success = connection.connect(device.path);
  if (!success) {
    sendToRenderer('device-status', { connected: false, message: 'Failed to connect' });
  }
}

function startDeviceScanning(): void {
  // Initial scan
  connectToDevice();

  // Periodic scan for device connection/disconnection
  scanInterval = setInterval(async () => {
    if (!connection || !connection.isConnected()) {
      await connectToDevice();
    }
  }, 3000);
}

app.whenReady().then(async () => {
  const firstLaunch = isFirstLaunch();

  createTray();
  createWindow();

  // Check driver status after window is created so we can send toasts
  // Wait a moment for the renderer to be ready
  setTimeout(async () => {
    const driverInstalled = isDriverInstalled();

    if (firstLaunch) {
      // First launch: show full dialog prompts
      log('First launch - checking driver status...');
      if (!driverInstalled) {
        log('Audio driver not installed, prompting user...');
        const installed = await promptAndInstallDriver();
        if (!installed) {
          await showDriverNotInstalledWarning();
        }
      }
      markFirstLaunchComplete();
    } else {
      // Subsequent launches: use toast notifications
      if (driverInstalled) {
        sendToRenderer('toast', {
          type: 'success',
          message: 'Audio driver ready',
          duration: 2000
        });
        log('Driver check passed');
      } else {
        // Driver is missing - show toast first, then prompt to reinstall
        sendToRenderer('toast', {
          type: 'warning',
          message: 'Audio driver not found - prompting for reinstall...',
          duration: 3000
        });
        log('Audio driver missing, prompting for reinstall...');

        // Wait for toast to show, then prompt
        setTimeout(async () => {
          const installed = await promptAndInstallDriver();
          if (installed) {
            sendToRenderer('toast', {
              type: 'success',
              message: 'Audio driver installed successfully',
              duration: 3000
            });
          } else {
            sendToRenderer('toast', {
              type: 'error',
              message: 'Per-app volume control unavailable without driver',
              duration: 5000
            });
          }
        }, 500);
      }
    }
  }, 500);

  startDeviceScanning();

  // Start audio passthrough for available PCPanel devices
  setTimeout(() => {
    log('Starting audio passthrough...');
    const devices = audioPassthrough.findPCPanelDevices();
    log('Found PCPanel audio devices:', devices.map(d => d.name));

    if (devices.length > 0) {
      audioPassthrough.startAll();
      log('Audio passthrough started');

      // Start polling for channel activity
      activityInterval = setInterval(() => {
        const activityInfo = audioPassthrough.getChannelActivityInfo();
        sendToRenderer('channel-activity', activityInfo);
      }, 500); // Poll every 500ms
    } else {
      log('No PCPanel audio devices found - driver may not be loaded');
    }
  }, 2000); // Wait for driver to be ready

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

// Handle app quit
app.on('before-quit', () => {
  isQuitting = true;
});

app.on('window-all-closed', () => {
  // On macOS with tray, don't quit when windows are closed
  // The app continues running in the background
  if (process.platform !== 'darwin') {
    cleanup();
    app.quit();
  }
});

function cleanup(): void {
  if (scanInterval) {
    clearInterval(scanInterval);
    scanInterval = null;
  }
  if (activityInterval) {
    clearInterval(activityInterval);
    activityInterval = null;
  }
  if (connection) {
    connection.disconnect();
    connection = null;
  }
  // Stop all audio passthrough
  audioPassthrough.stopAll();

  if (tray) {
    tray.destroy();
    tray = null;
  }
}

app.on('will-quit', () => {
  cleanup();
});

// IPC handlers
ipcMain.handle('get-device-state', () => {
  return connection?.getState() ?? {
    connected: false,
    analogValues: new Array(9).fill(0),
    buttonStates: new Array(5).fill(false),
  };
});

ipcMain.handle('reconnect-device', async () => {
  await connectToDevice();
});

ipcMain.handle('get-output-device', () => {
  return audioPassthrough.getDefaultOutput();
});

ipcMain.handle('get-channel-activity', () => {
  return audioPassthrough.getChannelActivityInfo();
});
