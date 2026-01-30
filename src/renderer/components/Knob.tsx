import React from 'react';

interface KnobProps {
  index: number;
  value: number;
  isPlaying: boolean;
  apps: string[];
}

export function Knob({ index, value, isPlaying, apps }: KnobProps) {
  const percent = Math.round((value / 255) * 100);
  const angle = -135 + (value / 255) * 270;

  return (
    <div className={`channel ${isPlaying ? 'playing' : ''}`} data-index={index}>
      <div className="channel-control knob">
        <div className="knob-visual">
          <div
            className="knob-indicator"
            style={{ transform: `rotate(${angle}deg)` }}
          />
        </div>
        <span className="control-value">{percent}%</span>
      </div>
      <div className="channel-info">
        <span className="channel-name">PCPanel K{index + 1}</span>
        <span className="channel-label">Knob {index + 1}</span>
      </div>
      {apps.length > 0 && (
        <div className="channel-apps">{apps.join(', ')}</div>
      )}
    </div>
  );
}
