import React from 'react';
import type { ChannelState, MixBusState } from '../types';

interface VoiceChatMixProps {
  channels: ChannelState[];
  mixBus?: MixBusState;
  onToggleChannel: (channelId: string, enabled: boolean) => void;
}

export function VoiceChatMix({ channels, mixBus, onToggleChannel }: VoiceChatMixProps) {
  // Check if channel is enabled in the voice chat mix
  const isChannelEnabled = (channelId: string): boolean => {
    if (!mixBus) return false;
    const mixChannel = mixBus.channels.find(c => c.channelId === channelId);
    return mixChannel?.enabled ?? false;
  };

  return (
    <section className="voice-chat-section">
      <h2>Voice Chat Mix</h2>
      <p className="section-hint">
        Select which channels to include in the virtual microphone. Apps like Discord can use "PCPanel Voice Chat" as their mic input.
      </p>

      <div className="voice-chat-status">
        <span className={`status-indicator ${mixBus?.isRunning ? 'active' : ''}`} />
        <span className="status-text">
          {mixBus?.isRunning ? 'Active' : 'Not running'}
        </span>
      </div>

      <div className="voice-chat-channels">
        {channels.map((channel) => (
          <label key={channel.id} className="voice-chat-channel">
            <input
              type="checkbox"
              checked={isChannelEnabled(channel.id)}
              onChange={(e) => onToggleChannel(channel.id, e.target.checked)}
            />
            <span className="channel-toggle" />
            <div className="channel-details">
              <span className="channel-name">{channel.channelName}</span>
              <span className="hardware-name">
                {channel.hardwareIndex < 5 ? `K${channel.hardwareIndex + 1}` : `S${channel.hardwareIndex - 4}`}
              </span>
            </div>
            {channel.isActive && (
              <span className="active-indicator" title={channel.apps.join(', ')}>
                Active
              </span>
            )}
          </label>
        ))}
      </div>
    </section>
  );
}
