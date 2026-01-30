import React, { useState, useEffect, useCallback } from 'react';
import { Knob } from './components/Knob';
import { Slider } from './components/Slider';
import { Button } from './components/Button';
import { Status } from './components/Status';
import { Toast } from './components/Toast';
import { VoiceChatMix } from './components/VoiceChatMix';
import type { PCPanelAPI, DeviceState, AudioRoutingState, ToastData, AudioLevelInfo } from './types';

// Access the preload-exposed API
const pcpanel = (window as unknown as { pcpanel: PCPanelAPI }).pcpanel;

export function App() {
  const [connected, setConnected] = useState(false);
  const [statusMessage, setStatusMessage] = useState('Searching for device...');
  const [analogValues, setAnalogValues] = useState<number[]>(new Array(9).fill(0));
  const [buttonStates, setButtonStates] = useState<boolean[]>(new Array(5).fill(false));
  const [routingState, setRoutingState] = useState<AudioRoutingState | null>(null);
  const [audioLevels, setAudioLevels] = useState<Record<string, AudioLevelInfo>>({});
  const [currentToast, setCurrentToast] = useState<ToastData | null>(null);

  const handleReconnect = useCallback(() => {
    setConnected(false);
    setStatusMessage('Reconnecting...');
    pcpanel.reconnect();
  }, []);

  const handleLabelChange = useCallback(async (channelId: string, label: string) => {
    try {
      const newState = await pcpanel.setChannelLabel(channelId, label);
      setRoutingState(newState);
    } catch (err) {
      console.error('Failed to update label:', err);
    }
  }, []);

  const handleVoiceChatToggle = useCallback(async (channelId: string, enabled: boolean) => {
    try {
      await pcpanel.setChannelEnabled('voicechat', channelId, enabled);
      // Refresh routing state
      const newState = await pcpanel.getAudioRouting();
      setRoutingState(newState);
    } catch (err) {
      console.error('Failed to toggle Voice Chat channel:', err);
    }
  }, []);

  const handleOutputDeviceChange = useCallback(async (deviceId: number | null) => {
    try {
      await pcpanel.setMixOutput('personal', deviceId);
      // Refresh routing state
      const newState = await pcpanel.getAudioRouting();
      setRoutingState(newState);
    } catch (err) {
      console.error('Failed to change output device:', err);
    }
  }, []);

  useEffect(() => {
    // Set up event listeners
    pcpanel.onDeviceStatus((status) => {
      setConnected(status.connected);
      setStatusMessage(status.message);
    });

    pcpanel.onDeviceState((state: DeviceState) => {
      setConnected(state.connected);
      setAnalogValues([...state.analogValues]);
      setButtonStates([...state.buttonStates]);
    });

    pcpanel.onChannelActivity((activityInfo) => {
      // Update routing state with new activity info
      setRoutingState(prev => {
        if (!prev) return prev;
        return {
          ...prev,
          channels: prev.channels.map(ch => ({
            ...ch,
            isActive: activityInfo[ch.hardwareIndex]?.isActive ?? false,
            apps: activityInfo[ch.hardwareIndex]?.apps ?? [],
          })),
        };
      });
    });

    pcpanel.onAudioLevels((levels) => {
      setAudioLevels(levels);
    });

    pcpanel.onToast((toast) => {
      setCurrentToast(toast);
    });

    // Get initial state
    pcpanel.getDeviceState().then((state) => {
      if (state.connected) {
        setConnected(true);
        setStatusMessage('Connected');
        setAnalogValues([...state.analogValues]);
        setButtonStates([...state.buttonStates]);
      }
    });

    // Get audio routing state
    pcpanel.getAudioRouting().then((state) => {
      console.log('Audio routing state:', state);
      console.log('Channels:', state?.channels);
      setRoutingState(state);
    });
  }, []);

  // Helper to get channel data by hardware index
  const getChannelByIndex = (index: number) => {
    return routingState?.channels.find(ch => ch.hardwareIndex === index);
  };

  // Get selected output device ID
  const selectedOutputId = (() => {
    if (!routingState) return null;
    const personalMix = routingState.mixBuses.find(m => m.id === 'personal');
    return personalMix?.outputDeviceId ?? null;
  })();

  const dismissToast = useCallback(() => {
    setCurrentToast(null);
  }, []);

  return (
    <>
      <Toast toast={currentToast} onDismiss={dismissToast} />
    <div className="container">
      <header>
        <h1>PC Panel Pro</h1>
        <Status connected={connected} message={statusMessage} />
      </header>

      <main>
        <section className="channels-section">
          <h2>Audio Channels</h2>
          <p className="section-hint">
            Set your app's audio output to one of these devices. Click a channel name to rename it.
          </p>

          <div className="channels-grid">
            <div className="channel-group">
              <h3>Knobs</h3>
              <div className="channel-row">
                {[0, 1, 2, 3, 4].map((i) => {
                  const channel = getChannelByIndex(i);
                  const level = channel?.id ? audioLevels[channel.id] : undefined;
                  return (
                    <Knob
                      key={i}
                      index={i}
                      value={analogValues[i]}
                      isPlaying={channel?.isActive ?? false}
                      apps={channel?.apps ?? []}
                      channelId={channel?.id}
                      channelName={channel?.channelName}
                      onLabelChange={handleLabelChange}
                      level={level}
                    />
                  );
                })}
              </div>
            </div>

            <div className="channel-group">
              <h3>Sliders</h3>
              <div className="channel-row">
                {[5, 6, 7, 8].map((i) => {
                  const channel = getChannelByIndex(i);
                  const level = channel?.id ? audioLevels[channel.id] : undefined;
                  return (
                    <Slider
                      key={i}
                      index={i}
                      value={analogValues[i]}
                      isPlaying={channel?.isActive ?? false}
                      apps={channel?.apps ?? []}
                      channelId={channel?.id}
                      channelName={channel?.channelName}
                      onLabelChange={handleLabelChange}
                      level={level}
                    />
                  );
                })}
              </div>
            </div>
          </div>
        </section>

        <section className="buttons-section">
          <h2>Buttons</h2>
          <div className="button-group">
            {[0, 1, 2, 3, 4].map((i) => (
              <Button key={i} index={i} pressed={buttonStates[i]} />
            ))}
          </div>
        </section>

        <section className="output-section">
          <h2>Output Device</h2>
          <div className="output-info">
            <select
              className="output-device-select"
              value={selectedOutputId ?? ''}
              onChange={(e) => {
                const value = e.target.value;
                handleOutputDeviceChange(value === '' ? null : Number(value));
              }}
              disabled={!routingState}
            >
              <option value="">System Default</option>
              {routingState?.availableOutputs.map(device => (
                <option key={device.id} value={device.id}>
                  {device.name}{device.isDefault ? ' (Default)' : ''}
                </option>
              ))}
            </select>
            <span className="output-hint">Select where mixed audio should be sent</span>
          </div>
        </section>

        {routingState && (
          <VoiceChatMix
            channels={routingState.channels}
            mixBus={routingState.mixBuses.find(m => m.id === 'voicechat')}
            onToggleChannel={handleVoiceChatToggle}
          />
        )}
      </main>

      <footer>
        <button id="reconnect-btn" onClick={handleReconnect}>
          Reconnect Device
        </button>
      </footer>
    </div>
    </>
  );
}
