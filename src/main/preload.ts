import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('pcpanel', {
  onDeviceStatus: (callback: (status: { connected: boolean; message: string }) => void) => {
    ipcRenderer.on('device-status', (_event, status) => callback(status));
  },
  onDeviceEvent: (callback: (event: unknown) => void) => {
    ipcRenderer.on('device-event', (_event, data) => callback(data));
  },
  onDeviceState: (callback: (state: unknown) => void) => {
    ipcRenderer.on('device-state', (_event, state) => callback(state));
  },
  onOutputDevice: (callback: (device: { name: string }) => void) => {
    ipcRenderer.on('output-device', (_event, device) => callback(device));
  },
  onChannelActivity: (callback: (activityInfo: Record<number, { isActive: boolean; apps: string[] }>) => void) => {
    ipcRenderer.on('channel-activity', (_event, info) => callback(info));
  },
  getDeviceState: () => ipcRenderer.invoke('get-device-state'),
  getOutputDevice: () => ipcRenderer.invoke('get-output-device'),
  getChannelActivity: () => ipcRenderer.invoke('get-channel-activity') as Promise<Record<number, { isActive: boolean; apps: string[] }>>,
  reconnect: () => ipcRenderer.invoke('reconnect-device'),
});
