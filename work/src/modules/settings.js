/**
 * Settings Module
 * Handles settings panel and user preferences
 *
 * This module provides the base structure for ws-6 (Interactive Controls & Settings Panel)
 */

const STORAGE_KEY = 'cyberpunk-clock-settings';

/**
 * Default settings
 */
const defaultSettings = {
  format24Hour: false,
  colorTheme: 'cyan',
  effectsEnabled: {
    scanlines: true,
    glitch: true,
    gridOverlay: true,
    sound: false
  }
};

/**
 * Current settings
 */
let settings = { ...defaultSettings };

/**
 * DOM element references
 */
let elements = {
  panel: null,
  toggle: null
};

/**
 * Load settings from localStorage
 * @returns {Object} - Loaded settings or defaults
 */
function loadFromStorage() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      return JSON.parse(stored);
    }
  } catch (error) {
    console.warn('[Settings] Failed to load from storage:', error);
  }
  return defaultSettings;
}

/**
 * Save settings to localStorage
 */
function saveToStorage() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch (error) {
    console.warn('[Settings] Failed to save to storage:', error);
  }
}

/**
 * Toggle settings panel visibility
 */
function togglePanel() {
  if (!elements.panel) return;

  const isHidden = elements.panel.getAttribute('aria-hidden') === 'true';
  elements.panel.setAttribute('aria-hidden', !isHidden);

  // Dispatch event for other modules
  window.dispatchEvent(new CustomEvent('settings:toggle', {
    detail: { isOpen: isHidden }
  }));
}

/**
 * Update a setting value
 * @param {string} key - Setting key (dot notation supported)
 * @param {*} value - New value
 */
export function updateSetting(key, value) {
  const keys = key.split('.');
  let target = settings;

  for (let i = 0; i < keys.length - 1; i++) {
    if (!(keys[i] in target)) {
      target[keys[i]] = {};
    }
    target = target[keys[i]];
  }

  target[keys[keys.length - 1]] = value;
  saveToStorage();

  // Dispatch event for other modules
  window.dispatchEvent(new CustomEvent('settings:change', {
    detail: { key, value, settings }
  }));

  console.log('[Settings] Updated:', key, '=', value);
}

/**
 * Get a setting value
 * @param {string} key - Setting key (dot notation supported)
 * @returns {*} - Setting value
 */
export function getSetting(key) {
  const keys = key.split('.');
  let value = settings;

  for (const k of keys) {
    if (value === undefined || value === null) {
      return undefined;
    }
    value = value[k];
  }

  return value;
}

/**
 * Get all settings
 * @returns {Object} - All settings
 */
export function getAllSettings() {
  return { ...settings };
}

/**
 * Reset settings to defaults
 */
export function resetSettings() {
  settings = { ...defaultSettings };
  saveToStorage();

  window.dispatchEvent(new CustomEvent('settings:reset', {
    detail: { settings }
  }));

  console.log('[Settings] Reset to defaults');
}

/**
 * Initialize settings module
 */
export function init() {
  // Load stored settings
  settings = { ...defaultSettings, ...loadFromStorage() };

  // Cache DOM elements
  elements = {
    panel: document.getElementById('settings-panel'),
    toggle: document.getElementById('settings-toggle')
  };

  // Set up toggle button
  if (elements.toggle) {
    elements.toggle.addEventListener('click', togglePanel);
  }

  // Close panel on Escape key
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && elements.panel) {
      elements.panel.setAttribute('aria-hidden', 'true');
    }
  });

  console.log('[Settings] Initialized with:', settings);

  // Dispatch initial settings event
  window.dispatchEvent(new CustomEvent('settings:loaded', {
    detail: { settings }
  }));

  return settings;
}

export default {
  init,
  updateSetting,
  getSetting,
  getAllSettings,
  resetSettings
};
