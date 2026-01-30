import React, { useState, useEffect, useCallback } from 'react';
import { Knob } from './components/Knob';
import { Slider } from './components/Slider';
import { Button } from './components/Button';
import { Status } from './components/Status';
import { Toast } from './components/Toast';
import type { PCPanelAPI, DeviceState, ChannelActivityInfo, ToastData } from './types';

// Access the preload-exposed API
const pcpanel = (window as unknown as { pcpanel: PCPanelAPI }).pcpanel;

export function App() {
  const [connected, setConnected] = useState(false);
  const [statusMessage, setStatusMessage] = useState('Searching for device...');
  const [analogValues, setAnalogValues] = useState<number[]>(new Array(9).fill(0));
  const [buttonStates, setButtonStates] = useState<boolean[]>(new Array(5).fill(false));
  const [outputDevice, setOutputDevice] = useState('Loading...');
  const [channelActivity, setChannelActivity] = useState<Record<number, ChannelActivityInfo>>({});
  const [currentToast, setCurrentToast] = useState<ToastData | null>(null);

  const handleReconnect = useCallback(() => {
    setConnected(false);
    setStatusMessage('Reconnecting...');
    pcpanel.reconnect();
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

    pcpanel.onOutputDevice((device) => {
      setOutputDevice(device.name);
    });

    pcpanel.onChannelActivity((activityInfo) => {
      setChannelActivity({ ...activityInfo });
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

    pcpanel.getOutputDevice().then((device) => {
      setOutputDevice(device?.name ?? 'Not available');
    });

    pcpanel.getChannelActivity().then((activityInfo) => {
      setChannelActivity({ ...activityInfo });
    });
  }, []);

  const getActivityInfo = (index: number): { isActive: boolean; apps: string[] } => {
    return channelActivity[index] ?? { isActive: false, apps: [] };
  };

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
            Set your app's audio output to one of these devices in System Settings or the app's preferences.
          </p>

          <div className="channels-grid">
            <div className="channel-group">
              <h3>Knobs</h3>
              <div className="channel-row">
                {[0, 1, 2, 3, 4].map((i) => {
                  const activity = getActivityInfo(i);
                  return (
                    <Knob
                      key={i}
                      index={i}
                      value={analogValues[i]}
                      isPlaying={activity.isActive}
                      apps={activity.apps}
                    />
                  );
                })}
              </div>
            </div>

            <div className="channel-group">
              <h3>Sliders</h3>
              <div className="channel-row">
                {[5, 6, 7, 8].map((i) => {
                  const activity = getActivityInfo(i);
                  return (
                    <Slider
                      key={i}
                      index={i}
                      value={analogValues[i]}
                      isPlaying={activity.isActive}
                      apps={activity.apps}
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
            <span id="output-device-name">{outputDevice}</span>
            <span className="output-hint">All audio routes to your default output</span>
          </div>
        </section>
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
