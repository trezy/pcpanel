import React, { useState, useRef, useEffect } from 'react';
import type { AudioLevelInfo } from '../types';

interface SliderProps {
  index: number;
  value: number;
  isPlaying: boolean;
  apps: string[];
  channelId?: string;
  channelName?: string;
  onLabelChange?: (channelId: string, label: string) => void;
  level?: AudioLevelInfo;
}

export function Slider({
  index,
  value,
  isPlaying,
  apps,
  channelId,
  channelName,
  onLabelChange,
  level,
}: SliderProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [editValue, setEditValue] = useState(channelName || `Channel ${index + 1}`);
  const inputRef = useRef<HTMLInputElement>(null);

  const percent = Math.round((value / 255) * 100);
  const sliderIndex = index - 5; // Sliders are indices 5-8, display as S1-S4
  const hardwareName = `S${sliderIndex + 1}`;

  // Convert level to percentage for meter display (0-100)
  const levelPercent = level ? Math.min(100, Math.round(level.rms * 100 * 3)) : 0;
  const peakPercent = level ? Math.min(100, Math.round(level.peak * 100)) : 0;

  // Update edit value when channelName changes
  useEffect(() => {
    if (channelName) {
      setEditValue(channelName);
    }
  }, [channelName]);

  const handleClick = () => {
    if (onLabelChange) {
      setEditValue(channelName || `Channel ${index + 1}`);
      setIsEditing(true);
    }
  };

  const handleSave = () => {
    setIsEditing(false);
    const effectiveChannelId = channelId || `s${sliderIndex + 1}`;
    if (onLabelChange && editValue.trim() !== channelName) {
      onLabelChange(effectiveChannelId, editValue.trim() || `Channel ${index + 1}`);
    }
  };

  const handleCancel = () => {
    setEditValue(channelName || `Channel ${index + 1}`);
    setIsEditing(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      handleSave();
    } else if (e.key === 'Escape') {
      handleCancel();
    }
  };

  const handleOverlayClick = (e: React.MouseEvent) => {
    if (e.target === e.currentTarget) {
      handleCancel();
    }
  };

  useEffect(() => {
    if (isEditing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [isEditing]);

  return (
    <div className={`channel ${isPlaying ? 'playing' : ''}`} data-index={index}>
      <div className="channel-control slider">
        <div className="level-meter">
          <div
            className="level-fill"
            style={{ height: `${levelPercent}%` }}
          />
          {peakPercent > 0 && (
            <div
              className="level-peak"
              style={{ bottom: `${peakPercent}%` }}
            />
          )}
        </div>
        <div className="control-bar">
          <div className="control-fill" style={{ height: `${percent}%` }} />
        </div>
        <span className="control-value">{percent}%</span>
      </div>
      <div className="channel-info">
        <span
          className="channel-name editable"
          onClick={handleClick}
          title={onLabelChange ? 'Click to edit' : undefined}
        >
          {channelName || `Channel ${index + 1}`}
        </span>
        <span className="hardware-name">{hardwareName}</span>
      </div>
      {apps.length > 0 && (
        <div className="channel-apps">{apps.join(', ')}</div>
      )}

      {isEditing && (
        <div className="channel-name-editor-overlay" onClick={handleOverlayClick}>
          <div className="channel-name-editor">
            <label>Rename Channel</label>
            <input
              ref={inputRef}
              type="text"
              value={editValue}
              onChange={(e) => setEditValue(e.target.value)}
              onKeyDown={handleKeyDown}
              maxLength={20}
            />
            <div className="channel-name-editor-actions">
              <button type="button" onClick={handleCancel}>Cancel</button>
              <button type="button" className="primary" onClick={handleSave}>Save</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
