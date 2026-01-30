import React from 'react';

interface SliderProps {
  index: number;
  value: number;
  isPlaying: boolean;
  apps: string[];
}

export function Slider({ index, value, isPlaying, apps }: SliderProps) {
  const percent = Math.round((value / 255) * 100);
  const sliderIndex = index - 5; // Sliders are indices 5-8, display as S1-S4

  return (
    <div className={`channel ${isPlaying ? 'playing' : ''}`} data-index={index}>
      <div className="channel-control slider">
        <div className="control-bar">
          <div className="control-fill" style={{ height: `${percent}%` }} />
        </div>
        <span className="control-value">{percent}%</span>
      </div>
      <div className="channel-info">
        <span className="channel-name">PCPanel S{sliderIndex + 1}</span>
        <span className="channel-label">Slider {sliderIndex + 1}</span>
      </div>
      {apps.length > 0 && (
        <div className="channel-apps">{apps.join(', ')}</div>
      )}
    </div>
  );
}
