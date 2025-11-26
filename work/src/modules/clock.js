/**
 * Clock Module - Enhanced Clock Engine
 *
 * Core clock logic for time display and updates with smooth rendering,
 * multiple format support, and comprehensive date display.
 *
 * @workstream ws-2
 */

/**
 * Clock configuration defaults
 */
const defaultConfig = {
  format24Hour: false,
  showSeconds: true,
  showDate: true,
  showMilliseconds: false,
  updateInterval: 1000,
  dateFormat: 'full', // 'full', 'short', 'numeric', 'iso'
  locale: 'en-US',
  smoothUpdates: true
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
 * Animation frame / interval references
 */
let updateTimer = null;
let rafId = null;
let lastSecond = -1;

/**
 * Pad a number with leading zeros
 * @param {number} num - Number to pad
 * @param {number} [length=2] - Desired string length
 * @returns {string} - Padded number string
 */
export function padZero(num, length = 2) {
  return num.toString().padStart(length, '0');
}

/**
 * Get the current time as a Date object
 * @returns {Date} - Current date/time
 */
export function getCurrentTime() {
  return new Date();
}

/**
 * Extract time components from a Date object
 * @param {Date} date - Date object to extract from
 * @returns {Object} - Raw time components
 */
export function getTimeComponents(date) {
  return {
    hours: date.getHours(),
    minutes: date.getMinutes(),
    seconds: date.getSeconds(),
    milliseconds: date.getMilliseconds()
  };
}

/**
 * Convert 24-hour format to 12-hour format
 * @param {number} hours - Hours in 24-hour format (0-23)
 * @returns {Object} - Object with hours12 and period
 */
export function convertTo12Hour(hours) {
  const period = hours >= 12 ? 'PM' : 'AM';
  const hours12 = hours % 12 || 12;
  return { hours: hours12, period };
}

/**
 * Format hours based on configuration
 * @param {number} hours - Hours in 24-hour format
 * @param {boolean} use24Hour - Whether to use 24-hour format
 * @returns {string} - Formatted hours string
 */
export function formatHours(hours, use24Hour = false) {
  if (use24Hour) {
    return padZero(hours);
  }
  const { hours: h12 } = convertTo12Hour(hours);
  return padZero(h12);
}

/**
 * Format minutes
 * @param {number} minutes - Minutes (0-59)
 * @returns {string} - Formatted minutes string
 */
export function formatMinutes(minutes) {
  return padZero(minutes);
}

/**
 * Format seconds
 * @param {number} seconds - Seconds (0-59)
 * @returns {string} - Formatted seconds string
 */
export function formatSeconds(seconds) {
  return padZero(seconds);
}

/**
 * Format the current time
 * @param {Date} date - Date object to format
 * @param {Object} [options] - Formatting options
 * @returns {Object} - Formatted time object with all components
 */
export function formatTime(date, options = {}) {
  const opts = { ...config, ...options };
  const { hours, minutes, seconds, milliseconds } = getTimeComponents(date);

  let formattedHours = formatHours(hours, opts.format24Hour);
  let ampm = '';

  if (!opts.format24Hour) {
    const { period } = convertTo12Hour(hours);
    ampm = period;
  }

  return {
    hours: formattedHours,
    minutes: formatMinutes(minutes),
    seconds: formatSeconds(seconds),
    milliseconds: padZero(milliseconds, 3),
    ampm,
    raw: { hours, minutes, seconds, milliseconds }
  };
}

/**
 * Get day of week name
 * @param {Date} date - Date object
 * @param {string} [locale='en-US'] - Locale for formatting
 * @param {string} [format='long'] - 'long' or 'short'
 * @returns {string} - Day name
 */
export function getDayName(date, locale = 'en-US', format = 'long') {
  return date.toLocaleDateString(locale, { weekday: format });
}

/**
 * Get month name
 * @param {Date} date - Date object
 * @param {string} [locale='en-US'] - Locale for formatting
 * @param {string} [format='long'] - 'long', 'short', or 'numeric'
 * @returns {string} - Month name or number
 */
export function getMonthName(date, locale = 'en-US', format = 'long') {
  return date.toLocaleDateString(locale, { month: format });
}

/**
 * Get date components
 * @param {Date} date - Date object
 * @returns {Object} - Date components
 */
export function getDateComponents(date) {
  return {
    dayOfWeek: date.getDay(),
    dayOfMonth: date.getDate(),
    month: date.getMonth(),
    year: date.getFullYear()
  };
}

/**
 * Format date in various styles
 * @param {Date} date - Date object to format
 * @param {string} [format='full'] - Format style: 'full', 'short', 'numeric', 'iso', 'cyberpunk'
 * @param {string} [locale='en-US'] - Locale for formatting
 * @returns {string} - Formatted date string
 */
export function formatDate(date, format = 'full', locale = 'en-US') {
  const { dayOfMonth, month, year } = getDateComponents(date);

  switch (format) {
    case 'full':
      return date.toLocaleDateString(locale, {
        weekday: 'long',
        year: 'numeric',
        month: 'long',
        day: 'numeric'
      });

    case 'short':
      return date.toLocaleDateString(locale, {
        weekday: 'short',
        year: 'numeric',
        month: 'short',
        day: 'numeric'
      });

    case 'numeric':
      return date.toLocaleDateString(locale, {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit'
      });

    case 'iso':
      return `${year}-${padZero(month + 1)}-${padZero(dayOfMonth)}`;

    case 'cyberpunk':
      // Futuristic date format: YEAR.MONTH.DAY // WEEKDAY
      const dayName = getDayName(date, locale, 'short').toUpperCase();
      return `${year}.${padZero(month + 1)}.${padZero(dayOfMonth)} // ${dayName}`;

    default:
      return formatDate(date, 'full', locale);
  }
}

/**
 * Update DOM element text only if changed (prevents flickering)
 * @param {HTMLElement} element - DOM element to update
 * @param {string} newValue - New text value
 * @returns {boolean} - Whether the value was updated
 */
function updateElementIfChanged(element, newValue) {
  if (!element) return false;

  if (element.textContent !== newValue) {
    element.textContent = newValue;
    return true;
  }
  return false;
}

/**
 * Update the clock display with smooth rendering
 * Only updates DOM elements when values actually change
 */
function updateDisplay() {
  const now = getCurrentTime();
  const time = formatTime(now);
  const currentSecond = time.raw.seconds;

  // Track if any digit changed (for animation triggers)
  let changed = {
    hours: false,
    minutes: false,
    seconds: false
  };

  // Update hours
  if (elements.hours) {
    changed.hours = updateElementIfChanged(elements.hours, time.hours);
    if (changed.hours) {
      triggerDigitAnimation(elements.hours);
    }
  }

  // Update minutes
  if (elements.minutes) {
    changed.minutes = updateElementIfChanged(elements.minutes, time.minutes);
    if (changed.minutes) {
      triggerDigitAnimation(elements.minutes);
    }
  }

  // Update seconds
  if (elements.seconds && config.showSeconds) {
    changed.seconds = updateElementIfChanged(elements.seconds, time.seconds);
    if (changed.seconds) {
      triggerDigitAnimation(elements.seconds);
    }
  }

  // Update AM/PM indicator
  if (elements.ampm) {
    updateElementIfChanged(elements.ampm, time.ampm);
  }

  // Update date (only once per second to avoid unnecessary updates)
  if (elements.date && config.showDate && currentSecond !== lastSecond) {
    const dateStr = formatDate(now, config.dateFormat, config.locale);
    updateElementIfChanged(elements.date, dateStr);
  }

  lastSecond = currentSecond;

  // Dispatch custom event for other modules
  window.dispatchEvent(new CustomEvent('clock:tick', {
    detail: {
      time,
      date: now,
      changed,
      formatted: {
        date: formatDate(now, config.dateFormat, config.locale)
      }
    }
  }));
}

/**
 * Trigger a subtle animation on a digit element
 * @param {HTMLElement} element - Element to animate
 */
function triggerDigitAnimation(element) {
  if (!element) return;

  // Add animation class
  element.classList.add('digit-updated');

  // Remove after animation completes
  setTimeout(() => {
    element.classList.remove('digit-updated');
  }, 200);
}

/**
 * Update loop using requestAnimationFrame for smoother updates
 * Uses RAF to sync with display refresh rate, but only updates at configured interval
 */
function rafUpdateLoop() {
  if (!config.smoothUpdates) return;

  updateDisplay();

  // Schedule next update at the start of the next second
  const now = new Date();
  const msUntilNextSecond = 1000 - now.getMilliseconds();

  // Use setTimeout to wait until next second boundary, then RAF for smooth render
  setTimeout(() => {
    rafId = requestAnimationFrame(rafUpdateLoop);
  }, msUntilNextSecond);
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

  // Validate elements exist
  const missing = Object.entries(elements)
    .filter(([key, el]) => !el && key !== 'ampm')
    .map(([key]) => key);

  if (missing.length > 0) {
    console.warn('[Clock] Missing DOM elements:', missing);
  }

  // Initial update
  updateDisplay();

  // Start the clock
  start();

  console.log('[Clock] Initialized with config:', config);

  return config;
}

/**
 * Start the clock updates
 * Uses RAF-based timing for smooth updates when smoothUpdates is true,
 * otherwise falls back to setInterval
 */
export function start() {
  if (updateTimer || rafId) {
    return; // Already running
  }

  if (config.smoothUpdates) {
    // Use RAF-based loop for smoother updates
    rafUpdateLoop();
    console.log('[Clock] Started (smooth mode)');
  } else {
    // Fall back to setInterval
    updateTimer = setInterval(updateDisplay, config.updateInterval);
    console.log('[Clock] Started (interval mode)');
  }
}

/**
 * Stop the clock updates
 */
export function stop() {
  if (updateTimer) {
    clearInterval(updateTimer);
    updateTimer = null;
  }

  if (rafId) {
    cancelAnimationFrame(rafId);
    rafId = null;
  }

  console.log('[Clock] Stopped');
}

/**
 * Update clock configuration
 * @param {Object} newConfig - New configuration options
 */
export function updateConfig(newConfig) {
  const wasRunning = updateTimer !== null || rafId !== null;
  const smoothModeChanged = newConfig.smoothUpdates !== undefined &&
                            newConfig.smoothUpdates !== config.smoothUpdates;

  config = { ...config, ...newConfig };

  // Restart if smooth mode changed
  if (wasRunning && smoothModeChanged) {
    stop();
    start();
  }

  // Immediately reflect changes
  updateDisplay();

  console.log('[Clock] Config updated:', config);

  // Dispatch config change event
  window.dispatchEvent(new CustomEvent('clock:configChange', {
    detail: { config }
  }));
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
 * @returns {boolean} - New format24Hour value
 */
export function toggleFormat() {
  config.format24Hour = !config.format24Hour;
  updateDisplay();

  window.dispatchEvent(new CustomEvent('clock:formatChange', {
    detail: { format24Hour: config.format24Hour }
  }));

  return config.format24Hour;
}

/**
 * Set date format
 * @param {string} format - Date format ('full', 'short', 'numeric', 'iso', 'cyberpunk')
 */
export function setDateFormat(format) {
  const validFormats = ['full', 'short', 'numeric', 'iso', 'cyberpunk'];
  if (!validFormats.includes(format)) {
    console.warn('[Clock] Invalid date format:', format);
    return;
  }

  config.dateFormat = format;
  updateDisplay();
}

/**
 * Get a snapshot of current time
 * @returns {Object} - Current time snapshot
 */
export function getTimeSnapshot() {
  const now = getCurrentTime();
  return {
    time: formatTime(now),
    date: formatDate(now, config.dateFormat, config.locale),
    timestamp: now.getTime(),
    iso: now.toISOString()
  };
}

// Export for testing
export const _internal = {
  updateDisplay,
  updateElementIfChanged,
  triggerDigitAnimation,
  elements,
  get config() { return config; }
};

export default {
  init,
  start,
  stop,
  updateConfig,
  getConfig,
  toggleFormat,
  setDateFormat,
  getTimeSnapshot,
  // Time utilities
  getCurrentTime,
  getTimeComponents,
  formatTime,
  formatHours,
  formatMinutes,
  formatSeconds,
  convertTo12Hour,
  padZero,
  // Date utilities
  formatDate,
  getDateComponents,
  getDayName,
  getMonthName
};
