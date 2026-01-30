import React, { useEffect, useState } from 'react';
import type { ToastData } from '../types';

interface ToastProps {
  toast: ToastData | null;
  onDismiss: () => void;
}

export function Toast({ toast, onDismiss }: ToastProps) {
  const [isVisible, setIsVisible] = useState(false);

  useEffect(() => {
    if (toast) {
      // Trigger entrance animation
      setIsVisible(true);

      // Auto-dismiss after duration
      const duration = toast.duration ?? 3000;
      const timer = setTimeout(() => {
        setIsVisible(false);
        setTimeout(onDismiss, 300); // Wait for exit animation
      }, duration);

      return () => clearTimeout(timer);
    }
  }, [toast, onDismiss]);

  if (!toast) return null;

  const getIcon = () => {
    switch (toast.type) {
      case 'success':
        return '\u2713'; // Checkmark
      case 'warning':
        return '\u26A0'; // Warning triangle
      case 'error':
        return '\u2717'; // X mark
      case 'info':
      default:
        return '\u2139'; // Info icon
    }
  };

  return (
    <div className={`toast toast-${toast.type} ${isVisible ? 'toast-visible' : ''}`}>
      <span className="toast-icon">{getIcon()}</span>
      <span className="toast-message">{toast.message}</span>
    </div>
  );
}
