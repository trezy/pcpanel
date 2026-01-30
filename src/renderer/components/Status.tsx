import React from 'react';

interface StatusProps {
  connected: boolean;
  message: string;
}

export function Status({ connected, message }: StatusProps) {
  return (
    <div className={`status ${connected ? 'connected' : 'disconnected'}`}>
      <span className="status-dot" />
      <span className="status-text">{message}</span>
    </div>
  );
}
