/**
 * Cyberpunk Clock - Main Entry Point
 *
 * This module initializes and coordinates all clock modules.
 * Other workstreams will extend the functionality:
 *   - ws-2: Core clock logic enhancements
 *   - ws-3: Cyberpunk visual design
 *   - ws-4: Neon glow animations
 *   - ws-5: Sound effects (IMPLEMENTED)
 *   - ws-6: Interactive controls
 *   - ws-7: Responsive design
 */

import clock from './modules/clock.js';
import settings from './modules/settings.js';
import effects from './modules/effects.js';
import audio from './modules/audio.js';

/**
 * Application state
 */
const app = {
  initialized: false,
  modules: {
    clock: null,
    settings: null,
    effects: null,
    audio: null
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

    // Initialize audio on first user interaction (browser policy requirement)
    setupAudioInitialization(userSettings);

    // Store module references
    app.modules = {
      clock,
      settings,
      effects,
      audio
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
 * Setup audio initialization on first user interaction
 * Browser policies require audio context to be created from user gesture
 * @param {Object} userSettings - User settings
 */
function setupAudioInitialization(userSettings) {
  let audioInitialized = false;

  const initAudio = async () => {
    if (audioInitialized) return;
    audioInitialized = true;

    // Remove listeners once initialized
    document.removeEventListener('click', initAudio);
    document.removeEventListener('keydown', initAudio);
    document.removeEventListener('touchstart', initAudio);

    // Initialize audio module
    const success = await audio.init();

    if (success) {
      // Apply user's sound preference
      if (userSettings.effectsEnabled?.sound) {
        audio.enable();
      }

      // Setup audio control button listeners
      setupAudioControls();
    }
  };

  // Listen for first user interaction
  document.addEventListener('click', initAudio);
  document.addEventListener('keydown', initAudio);
  document.addEventListener('touchstart', initAudio);
}

/**
 * Setup audio control button event listeners
 */
function setupAudioControls() {
  const audioToggle = document.getElementById('audio-toggle');
  const audioMute = document.getElementById('audio-mute');
  const ambientToggle = document.getElementById('ambient-toggle');
  const tickToggle = document.getElementById('tick-toggle');

  if (audioToggle) {
    audioToggle.addEventListener('click', () => {
      audio.toggle();
      updateAudioControlsUI();
    });
  }

  if (audioMute) {
    audioMute.addEventListener('click', () => {
      audio.toggleMute();
      updateAudioControlsUI();
    });
  }

  if (ambientToggle) {
    ambientToggle.addEventListener('click', () => {
      const state = audio.getState();
      audio.setAmbientEnabled(!state.ambientEnabled);
      updateAudioControlsUI();
    });
  }

  if (tickToggle) {
    tickToggle.addEventListener('click', () => {
      const state = audio.getState();
      audio.setTickEnabled(!state.tickEnabled);
      updateAudioControlsUI();
    });
  }

  // Initial UI update
  updateAudioControlsUI();
}

/**
 * Update audio controls UI to reflect current state
 */
function updateAudioControlsUI() {
  const state = audio.getState();
  const audioToggle = document.getElementById('audio-toggle');
  const audioMute = document.getElementById('audio-mute');
  const ambientToggle = document.getElementById('ambient-toggle');
  const tickToggle = document.getElementById('tick-toggle');
  const audioStatus = document.getElementById('audio-status');

  if (audioToggle) {
    audioToggle.classList.toggle('active', state.enabled);
    audioToggle.setAttribute('aria-pressed', state.enabled);
  }

  if (audioMute) {
    audioMute.classList.toggle('muted', state.muted);
    audioMute.setAttribute('aria-pressed', state.muted);
  }

  if (ambientToggle) {
    ambientToggle.classList.toggle('active', state.ambientEnabled);
    ambientToggle.setAttribute('aria-pressed', state.ambientEnabled);
  }

  if (tickToggle) {
    tickToggle.classList.toggle('active', state.tickEnabled);
    tickToggle.setAttribute('aria-pressed', state.tickEnabled);
  }

  if (audioStatus) {
    let statusText = 'Audio: ';
    if (state.muted) {
      statusText += 'Muted';
    } else if (state.enabled) {
      statusText += 'On';
    } else {
      statusText += 'Off';
    }
    audioStatus.textContent = statusText;
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
  effects,
  audio
};

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

export { init, getState };
export default app;
