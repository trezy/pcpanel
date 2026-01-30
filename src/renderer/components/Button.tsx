import React from 'react';

interface ButtonProps {
  index: number;
  pressed: boolean;
}

export function Button({ index, pressed }: ButtonProps) {
  return (
    <div className={`control button ${pressed ? 'pressed' : ''}`} data-index={index}>
      <div className="button-visual" />
      <span className="control-label">B{index + 1}</span>
    </div>
  );
}
