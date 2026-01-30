import { contextBridge, ipcRenderer } from 'electron';

// Types for audio routing state (matches main/audio/types.ts)
interface AudioOutputDevice {
  id: number;
  name: string;
  isDefault: boolean;
}

interface ChannelState {
  id: string;
  deviceName: string;
  channelName: string;
  hardwareIndex: number;
  volume: number;
  muted: boolean;
  isActive: boolean;
  apps: string[];
}

interface MixBusChannel {
  channelId: string;
  enabled: boolean;
  gainOverride: number | null;
}

interface MixBusState {
  id: string;
  name: string;
  outputDeviceId: number | null;
  channels: MixBusChannel[];
  isRunning: boolean;
  mixerHandle: number | null;
}

interface AudioRoutingState {
  channels: ChannelState[];
  mixBuses: MixBusState[];
  availableOutputs: AudioOutputDevice[];
}

contextBridge.exposeInMainWorld('pcpanel', {
  // Legacy event listeners
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
  onAudioLevels: (callback: (levels: Record<string, { peak: number; rms: number }>) => void) => {
    ipcRenderer.on('audio-levels', (_event, levels) => callback(levels));
  },
  onToast: (callback: (toast: { type: 'success' | 'warning' | 'error' | 'info'; message: string; duration?: number }) => void) => {
    ipcRenderer.on('toast', (_event, toast) => callback(toast));
  },

  // Legacy API (for backward compatibility)
  getDeviceState: () => ipcRenderer.invoke('get-device-state'),
  getOutputDevice: () => ipcRenderer.invoke('get-output-device'),
  getChannelActivity: () => ipcRenderer.invoke('get-channel-activity') as Promise<Record<number, { isActive: boolean; apps: string[] }>>,
  reconnect: () => ipcRenderer.invoke('reconnect-device'),

  // New audio routing API
  getAudioRouting: () => ipcRenderer.invoke('get-audio-routing') as Promise<AudioRoutingState>,
  setChannelLabel: (channelId: string, label: string) =>
    ipcRenderer.invoke('set-channel-label', channelId, label) as Promise<AudioRoutingState>,
  setChannelVolume: (channelId: string, volume: number) =>
    ipcRenderer.invoke('set-channel-volume', channelId, volume) as Promise<boolean>,
  setChannelMuted: (channelId: string, muted: boolean) =>
    ipcRenderer.invoke('set-channel-muted', channelId, muted) as Promise<boolean>,
  setChannelEnabled: (mixId: string, channelId: string, enabled: boolean) =>
    ipcRenderer.invoke('set-channel-enabled-in-mix', mixId, channelId, enabled) as Promise<boolean>,
  setMixOutput: (mixId: string, deviceId: number | null) =>
    ipcRenderer.invoke('set-mix-output', mixId, deviceId) as Promise<boolean>,
  getAvailableOutputs: () =>
    ipcRenderer.invoke('get-available-outputs') as Promise<AudioOutputDevice[]>,
});
