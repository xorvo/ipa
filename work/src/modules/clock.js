/**
 * Clock Module
 * Core clock logic for time display and updates
 *
 * This module will be extended by ws-2 (Core Clock Logic & Time Display)
 */

/**
 * Clock configuration
 */
const defaultConfig = {
  format24Hour: false,
  showSeconds: true,
  showDate: true,
  updateInterval: 1000
};

/**
 * DOM element references
 */
let elements = {
  hours: null,
  minutes: null,
  seconds: null,
  ampm: null,
  date: null
};

/**
 * Current configuration
 */
let config = { ...defaultConfig };

/**
 * Interval timer reference
 */
let updateTimer = null;

/**
 * Pad a number with leading zero if needed
 * @param {number} num - Number to pad
 * @returns {string} - Padded number string
 */
function padZero(num) {
  return num.toString().padStart(2, '0');
}

/**
 * Format the current time
 * @param {Date} date - Date object to format
 * @returns {Object} - Formatted time object
 */
function formatTime(date) {
  let hours = date.getHours();
  const minutes = date.getMinutes();
  const seconds = date.getSeconds();
  let ampm = '';

  if (!config.format24Hour) {
    ampm = hours >= 12 ? 'PM' : 'AM';
    hours = hours % 12 || 12;
  }

  return {
    hours: padZero(hours),
    minutes: padZero(minutes),
    seconds: padZero(seconds),
    ampm
  };
}

/**
 * Format the current date
 * @param {Date} date - Date object to format
 * @returns {string} - Formatted date string
 */
function formatDate(date) {
  const options = {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  };
  return date.toLocaleDateString('en-US', options);
}

/**
 * Update the clock display
 */
function updateDisplay() {
  const now = new Date();
  const time = formatTime(now);

  if (elements.hours) {
    elements.hours.textContent = time.hours;
  }
  if (elements.minutes) {
    elements.minutes.textContent = time.minutes;
  }
  if (elements.seconds && config.showSeconds) {
    elements.seconds.textContent = time.seconds;
  }
  if (elements.ampm) {
    elements.ampm.textContent = time.ampm;
  }
  if (elements.date && config.showDate) {
    elements.date.textContent = formatDate(now);
  }

  // Dispatch custom event for other modules to listen to
  window.dispatchEvent(new CustomEvent('clock:tick', {
    detail: { time, date: now }
  }));
}

/**
 * Initialize the clock
 * @param {Object} userConfig - User configuration options
 */
export function init(userConfig = {}) {
  // Merge user config with defaults
  config = { ...defaultConfig, ...userConfig };

  // Cache DOM elements
  elements = {
    hours: document.getElementById('hours'),
    minutes: document.getElementById('minutes'),
    seconds: document.getElementById('seconds'),
    ampm: document.getElementById('ampm'),
    date: document.getElementById('date')
  };

  // Initial update
  updateDisplay();

  // Start the clock
  start();

  console.log('[Clock] Initialized with config:', config);
}

/**
 * Start the clock updates
 */
export function start() {
  if (updateTimer) {
    return; // Already running
  }
  updateTimer = setInterval(updateDisplay, config.updateInterval);
  console.log('[Clock] Started');
}

/**
 * Stop the clock updates
 */
export function stop() {
  if (updateTimer) {
    clearInterval(updateTimer);
    updateTimer = null;
    console.log('[Clock] Stopped');
  }
}

/**
 * Update clock configuration
 * @param {Object} newConfig - New configuration options
 */
export function updateConfig(newConfig) {
  config = { ...config, ...newConfig };
  updateDisplay(); // Immediately reflect changes
  console.log('[Clock] Config updated:', config);
}

/**
 * Get current configuration
 * @returns {Object} - Current configuration
 */
export function getConfig() {
  return { ...config };
}

/**
 * Toggle 12/24 hour format
 */
export function toggleFormat() {
  config.format24Hour = !config.format24Hour;
  updateDisplay();
  return config.format24Hour;
}

export default {
  init,
  start,
  stop,
  updateConfig,
  getConfig,
  toggleFormat
};
