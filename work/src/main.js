/**
 * Cyberpunk Clock - Main Entry Point
 *
 * This module initializes and coordinates all clock modules.
 * Other workstreams will extend the functionality:
 *   - ws-2: Core clock logic enhancements
 *   - ws-3: Cyberpunk visual design
 *   - ws-4: Neon glow animations
 *   - ws-5: Sound effects
 *   - ws-6: Interactive controls
 *   - ws-7: Responsive design
 */

import clock from './modules/clock.js';
import settings from './modules/settings.js';
import effects from './modules/effects.js';

/**
 * Application state
 */
const app = {
  initialized: false,
  modules: {
    clock: null,
    settings: null,
    effects: null
  }
};

/**
 * Initialize the application
 */
async function init() {
  if (app.initialized) {
    console.warn('[App] Already initialized');
    return;
  }

  console.log('[App] Initializing Cyberpunk Clock...');

  try {
    // Initialize settings first to load user preferences
    const userSettings = settings.init();

    // Initialize effects with user preferences
    effects.init(userSettings.effectsEnabled);

    // Initialize clock with user preferences
    clock.init({
      format24Hour: userSettings.format24Hour
    });

    // Listen for settings changes to update clock
    window.addEventListener('settings:change', (event) => {
      const { key, value } = event.detail;

      if (key === 'format24Hour') {
        clock.updateConfig({ format24Hour: value });
      }
    });

    // Store module references
    app.modules = {
      clock,
      settings,
      effects
    };

    app.initialized = true;

    console.log('[App] Cyberpunk Clock initialized successfully!');

    // Dispatch app ready event
    window.dispatchEvent(new CustomEvent('app:ready', {
      detail: { app }
    }));

  } catch (error) {
    console.error('[App] Initialization failed:', error);
  }
}

/**
 * Get application state
 * @returns {Object} - Application state
 */
function getState() {
  return {
    initialized: app.initialized,
    clock: app.modules.clock?.getConfig(),
    settings: app.modules.settings?.getAllSettings(),
    effects: app.modules.effects?.getAllEffects()
  };
}

// Expose API globally for debugging and external access
window.cyberpunkClock = {
  init,
  getState,
  clock,
  settings,
  effects
};

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

export { init, getState };
export default app;
