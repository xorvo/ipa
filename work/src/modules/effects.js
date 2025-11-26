/**
 * Effects Module
 * Visual effects management for the cyberpunk theme
 *
 * This module provides the base structure for ws-3 and ws-4 (visual effects)
 */

/**
 * Effect states
 */
let effectsEnabled = {
  scanlines: true,
  gridOverlay: true,
  glitch: false,
  neonPulse: true
};

/**
 * DOM element references
 */
let elements = {
  scanlines: null,
  gridOverlay: null,
  clockDisplay: null
};

/**
 * Toggle an effect on/off
 * @param {string} effectName - Name of the effect
 * @param {boolean} enabled - Whether to enable the effect
 */
export function setEffect(effectName, enabled) {
  if (!(effectName in effectsEnabled)) {
    console.warn('[Effects] Unknown effect:', effectName);
    return;
  }

  effectsEnabled[effectName] = enabled;

  // Apply effect changes to DOM
  switch (effectName) {
    case 'scanlines':
      if (elements.scanlines) {
        elements.scanlines.style.display = enabled ? 'block' : 'none';
      }
      break;
    case 'gridOverlay':
      if (elements.gridOverlay) {
        elements.gridOverlay.style.display = enabled ? 'block' : 'none';
      }
      break;
    default:
      // Other effects will be implemented in ws-4
      break;
  }

  window.dispatchEvent(new CustomEvent('effects:change', {
    detail: { effectName, enabled }
  }));

  console.log('[Effects]', effectName, enabled ? 'enabled' : 'disabled');
}

/**
 * Get effect state
 * @param {string} effectName - Name of the effect
 * @returns {boolean} - Whether the effect is enabled
 */
export function getEffect(effectName) {
  return effectsEnabled[effectName] ?? false;
}

/**
 * Get all effect states
 * @returns {Object} - All effect states
 */
export function getAllEffects() {
  return { ...effectsEnabled };
}

/**
 * Initialize effects module
 * @param {Object} initialStates - Initial effect states
 */
export function init(initialStates = {}) {
  // Merge initial states
  effectsEnabled = { ...effectsEnabled, ...initialStates };

  // Cache DOM elements
  elements = {
    scanlines: document.querySelector('.scanlines'),
    gridOverlay: document.querySelector('.grid-overlay'),
    clockDisplay: document.querySelector('.clock-display')
  };

  // Apply initial states
  Object.keys(effectsEnabled).forEach(effectName => {
    setEffect(effectName, effectsEnabled[effectName]);
  });

  // Listen for settings changes
  window.addEventListener('settings:change', (event) => {
    const { key, value } = event.detail;
    if (key.startsWith('effectsEnabled.')) {
      const effectName = key.replace('effectsEnabled.', '');
      setEffect(effectName, value);
    }
  });

  console.log('[Effects] Initialized with:', effectsEnabled);
}

export default {
  init,
  setEffect,
  getEffect,
  getAllEffects
};
