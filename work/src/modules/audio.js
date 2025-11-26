/**
 * Audio Module
 * Cyberpunk-themed audio effects using Web Audio API
 *
 * Features:
 * - Synthesized tick sounds for each second
 * - Ambient background hum/electronic drone
 * - Interaction sound effects (clicks, mode changes)
 * - Master mute and per-effect volume controls
 *
 * All sounds are synthesized using Web Audio API - no external files needed.
 */

/**
 * Audio context (created on user interaction to comply with browser policies)
 */
let audioContext = null;

/**
 * Master gain node for global volume control
 */
let masterGain = null;

/**
 * Ambient sound nodes
 */
let ambientNodes = {
  oscillators: [],
  gains: [],
  filters: []
};

/**
 * Audio state
 */
const audioState = {
  initialized: false,
  enabled: false,
  muted: false,
  masterVolume: 0.5,
  tickEnabled: true,
  tickVolume: 0.3,
  ambientEnabled: true,
  ambientVolume: 0.2,
  interactionEnabled: true,
  interactionVolume: 0.4
};

/**
 * Sound presets for cyberpunk aesthetic
 */
const soundPresets = {
  tick: {
    // High-pitched digital beep
    frequency: 880,
    type: 'square',
    attack: 0.001,
    decay: 0.05,
    sustain: 0.1,
    release: 0.1
  },
  tickAlt: {
    // Softer tick for variation
    frequency: 660,
    type: 'sine',
    attack: 0.001,
    decay: 0.03,
    sustain: 0.08,
    release: 0.08
  },
  click: {
    // UI click sound
    frequency: 1200,
    type: 'square',
    attack: 0.001,
    decay: 0.02,
    sustain: 0.01,
    release: 0.05
  },
  modeChange: {
    // Mode switch sound (ascending tone)
    frequencies: [440, 554, 659],
    type: 'sawtooth',
    attack: 0.01,
    decay: 0.1,
    sustain: 0.1,
    release: 0.15,
    interval: 80
  },
  enable: {
    // Enable/power-on sound
    frequencies: [330, 440, 550],
    type: 'sine',
    attack: 0.01,
    decay: 0.08,
    sustain: 0.1,
    release: 0.2,
    interval: 50
  },
  disable: {
    // Disable/power-off sound
    frequencies: [550, 440, 330],
    type: 'sine',
    attack: 0.01,
    decay: 0.08,
    sustain: 0.05,
    release: 0.2,
    interval: 50
  },
  error: {
    // Error/warning buzz
    frequency: 220,
    type: 'sawtooth',
    attack: 0.01,
    decay: 0.1,
    sustain: 0.2,
    release: 0.1
  }
};

/**
 * Initialize the audio context (must be called from user interaction)
 * @returns {Promise<boolean>} - Whether initialization was successful
 */
export async function init() {
  if (audioState.initialized) {
    return true;
  }

  try {
    // Create audio context
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) {
      console.warn('[Audio] Web Audio API not supported');
      return false;
    }

    audioContext = new AudioContextClass();

    // Create master gain node
    masterGain = audioContext.createGain();
    masterGain.gain.value = audioState.masterVolume;
    masterGain.connect(audioContext.destination);

    // Resume context if suspended (required by some browsers)
    if (audioContext.state === 'suspended') {
      await audioContext.resume();
    }

    audioState.initialized = true;
    audioState.enabled = true;

    console.log('[Audio] Initialized successfully');

    // Listen for clock ticks
    window.addEventListener('clock:tick', handleClockTick);

    // Listen for settings changes
    window.addEventListener('settings:change', handleSettingsChange);

    // Dispatch ready event
    window.dispatchEvent(new CustomEvent('audio:ready', {
      detail: { state: getState() }
    }));

    return true;
  } catch (error) {
    console.error('[Audio] Initialization failed:', error);
    return false;
  }
}

/**
 * Handle clock tick events
 * @param {CustomEvent} event - Clock tick event
 */
function handleClockTick(event) {
  if (!audioState.enabled || !audioState.tickEnabled || audioState.muted) {
    return;
  }

  const { time } = event.detail;
  const seconds = parseInt(time.seconds, 10);

  // Play tick sound
  // Every 10th second gets a different sound for rhythm
  if (seconds % 10 === 0) {
    playTick('alt');
  } else {
    playTick('normal');
  }
}

/**
 * Handle settings changes
 * @param {CustomEvent} event - Settings change event
 */
function handleSettingsChange(event) {
  const { key, value } = event.detail;

  if (key === 'effectsEnabled.sound') {
    if (value) {
      enable();
    } else {
      disable();
    }
  }
}

/**
 * Play a tick sound
 * @param {string} variant - 'normal' or 'alt'
 */
export function playTick(variant = 'normal') {
  if (!audioState.initialized || !audioState.enabled || audioState.muted) {
    return;
  }

  const preset = variant === 'alt' ? soundPresets.tickAlt : soundPresets.tick;
  playSynthSound(preset, audioState.tickVolume);
}

/**
 * Play a synthesized sound
 * @param {Object} preset - Sound preset configuration
 * @param {number} volume - Volume level (0-1)
 */
function playSynthSound(preset, volume) {
  if (!audioContext || !masterGain) return;

  const now = audioContext.currentTime;
  const { attack, decay, sustain, release } = preset;
  const duration = attack + decay + sustain + release;

  // Create oscillator
  const oscillator = audioContext.createOscillator();
  oscillator.type = preset.type;
  oscillator.frequency.value = preset.frequency;

  // Create gain for envelope
  const gainNode = audioContext.createGain();
  gainNode.gain.setValueAtTime(0, now);

  // ADSR envelope
  gainNode.gain.linearRampToValueAtTime(volume, now + attack);
  gainNode.gain.linearRampToValueAtTime(volume * 0.7, now + attack + decay);
  gainNode.gain.setValueAtTime(volume * 0.7, now + attack + decay + sustain);
  gainNode.gain.linearRampToValueAtTime(0, now + duration);

  // Add subtle filter for warmth
  const filter = audioContext.createBiquadFilter();
  filter.type = 'lowpass';
  filter.frequency.value = 4000;
  filter.Q.value = 1;

  // Connect nodes
  oscillator.connect(filter);
  filter.connect(gainNode);
  gainNode.connect(masterGain);

  // Start and stop
  oscillator.start(now);
  oscillator.stop(now + duration + 0.1);

  // Cleanup
  oscillator.onended = () => {
    oscillator.disconnect();
    gainNode.disconnect();
    filter.disconnect();
  };
}

/**
 * Play a multi-tone sound (for mode changes, enable/disable)
 * @param {Object} preset - Multi-tone preset configuration
 * @param {number} volume - Volume level (0-1)
 */
function playMultiToneSound(preset, volume) {
  if (!audioContext || !masterGain) return;

  const { frequencies, type, attack, decay, sustain, release, interval } = preset;

  frequencies.forEach((freq, index) => {
    setTimeout(() => {
      const singlePreset = {
        frequency: freq,
        type,
        attack,
        decay,
        sustain,
        release
      };
      playSynthSound(singlePreset, volume);
    }, index * interval);
  });
}

/**
 * Play UI click sound
 */
export function playClick() {
  if (!audioState.initialized || !audioState.enabled || audioState.muted) {
    return;
  }
  if (!audioState.interactionEnabled) return;

  playSynthSound(soundPresets.click, audioState.interactionVolume);
}

/**
 * Play mode change sound
 */
export function playModeChange() {
  if (!audioState.initialized || !audioState.enabled || audioState.muted) {
    return;
  }
  if (!audioState.interactionEnabled) return;

  playMultiToneSound(soundPresets.modeChange, audioState.interactionVolume);
}

/**
 * Play enable/power-on sound
 */
export function playEnable() {
  if (!audioState.initialized || audioState.muted) {
    return;
  }

  playMultiToneSound(soundPresets.enable, audioState.interactionVolume);
}

/**
 * Play disable/power-off sound
 */
export function playDisable() {
  if (!audioState.initialized || audioState.muted) {
    return;
  }

  playMultiToneSound(soundPresets.disable, audioState.interactionVolume);
}

/**
 * Play error sound
 */
export function playError() {
  if (!audioState.initialized || !audioState.enabled || audioState.muted) {
    return;
  }

  playSynthSound(soundPresets.error, audioState.interactionVolume);
}

/**
 * Start ambient background sound
 */
export function startAmbient() {
  if (!audioState.initialized || !audioState.enabled || audioState.muted) {
    return;
  }
  if (!audioState.ambientEnabled) return;
  if (ambientNodes.oscillators.length > 0) return; // Already playing

  const now = audioContext.currentTime;

  // Create ambient drone using multiple detuned oscillators
  // Base frequencies for electronic hum
  const frequencies = [55, 110, 165]; // A1, A2, E3 - creates rich harmonics
  const detuneValues = [-5, 0, 5]; // Slight detuning for width

  frequencies.forEach((freq, i) => {
    // Main oscillator
    const osc = audioContext.createOscillator();
    osc.type = 'sine';
    osc.frequency.value = freq;
    osc.detune.value = detuneValues[i];

    // Individual gain for this oscillator
    const gain = audioContext.createGain();
    gain.gain.value = 0;

    // Low-pass filter for warmth
    const filter = audioContext.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = 200 + i * 50;
    filter.Q.value = 2;

    // Connect
    osc.connect(filter);
    filter.connect(gain);
    gain.connect(masterGain);

    // Fade in
    gain.gain.linearRampToValueAtTime(
      audioState.ambientVolume / frequencies.length,
      now + 2
    );

    osc.start(now);

    // Store references
    ambientNodes.oscillators.push(osc);
    ambientNodes.gains.push(gain);
    ambientNodes.filters.push(filter);
  });

  // Add subtle LFO modulation for pulsing effect
  const lfo = audioContext.createOscillator();
  lfo.type = 'sine';
  lfo.frequency.value = 0.1; // Very slow modulation

  const lfoGain = audioContext.createGain();
  lfoGain.gain.value = 10; // Modulation depth

  lfo.connect(lfoGain);
  ambientNodes.filters.forEach(filter => {
    lfoGain.connect(filter.frequency);
  });

  lfo.start(now);
  ambientNodes.oscillators.push(lfo);
  ambientNodes.gains.push(lfoGain);

  console.log('[Audio] Ambient sound started');
}

/**
 * Stop ambient background sound
 */
export function stopAmbient() {
  if (ambientNodes.oscillators.length === 0) return;

  const now = audioContext.currentTime;

  // Fade out
  ambientNodes.gains.forEach(gain => {
    gain.gain.linearRampToValueAtTime(0, now + 0.5);
  });

  // Stop and cleanup after fade
  setTimeout(() => {
    ambientNodes.oscillators.forEach(osc => {
      try {
        osc.stop();
        osc.disconnect();
      } catch (e) {
        // Ignore if already stopped
      }
    });
    ambientNodes.gains.forEach(gain => gain.disconnect());
    ambientNodes.filters.forEach(filter => filter.disconnect());

    ambientNodes = { oscillators: [], gains: [], filters: [] };
  }, 600);

  console.log('[Audio] Ambient sound stopped');
}

/**
 * Enable audio
 */
export function enable() {
  if (!audioState.initialized) {
    console.warn('[Audio] Not initialized. Call init() first.');
    return;
  }

  audioState.enabled = true;
  playEnable();

  if (audioState.ambientEnabled) {
    startAmbient();
  }

  window.dispatchEvent(new CustomEvent('audio:enable', {
    detail: { state: getState() }
  }));

  console.log('[Audio] Enabled');
}

/**
 * Disable audio
 */
export function disable() {
  if (!audioState.initialized) return;

  playDisable();
  stopAmbient();
  audioState.enabled = false;

  window.dispatchEvent(new CustomEvent('audio:disable', {
    detail: { state: getState() }
  }));

  console.log('[Audio] Disabled');
}

/**
 * Toggle audio enabled state
 * @returns {boolean} - New enabled state
 */
export function toggle() {
  if (audioState.enabled) {
    disable();
  } else {
    enable();
  }
  return audioState.enabled;
}

/**
 * Mute all audio
 */
export function mute() {
  if (!audioState.initialized) return;

  audioState.muted = true;
  if (masterGain) {
    masterGain.gain.setTargetAtTime(0, audioContext.currentTime, 0.1);
  }
  stopAmbient();

  window.dispatchEvent(new CustomEvent('audio:mute', {
    detail: { state: getState() }
  }));

  console.log('[Audio] Muted');
}

/**
 * Unmute audio
 */
export function unmute() {
  if (!audioState.initialized) return;

  audioState.muted = false;
  if (masterGain) {
    masterGain.gain.setTargetAtTime(
      audioState.masterVolume,
      audioContext.currentTime,
      0.1
    );
  }

  if (audioState.enabled && audioState.ambientEnabled) {
    startAmbient();
  }

  window.dispatchEvent(new CustomEvent('audio:unmute', {
    detail: { state: getState() }
  }));

  console.log('[Audio] Unmuted');
}

/**
 * Toggle mute state
 * @returns {boolean} - New muted state
 */
export function toggleMute() {
  if (audioState.muted) {
    unmute();
  } else {
    mute();
  }
  return audioState.muted;
}

/**
 * Set master volume
 * @param {number} volume - Volume level (0-1)
 */
export function setMasterVolume(volume) {
  audioState.masterVolume = Math.max(0, Math.min(1, volume));

  if (masterGain && !audioState.muted) {
    masterGain.gain.setTargetAtTime(
      audioState.masterVolume,
      audioContext.currentTime,
      0.1
    );
  }

  window.dispatchEvent(new CustomEvent('audio:volumeChange', {
    detail: { volume: audioState.masterVolume, type: 'master' }
  }));
}

/**
 * Set tick sound volume
 * @param {number} volume - Volume level (0-1)
 */
export function setTickVolume(volume) {
  audioState.tickVolume = Math.max(0, Math.min(1, volume));

  window.dispatchEvent(new CustomEvent('audio:volumeChange', {
    detail: { volume: audioState.tickVolume, type: 'tick' }
  }));
}

/**
 * Set ambient sound volume
 * @param {number} volume - Volume level (0-1)
 */
export function setAmbientVolume(volume) {
  audioState.ambientVolume = Math.max(0, Math.min(1, volume));

  // Update existing ambient nodes
  if (ambientNodes.gains.length > 0) {
    const now = audioContext.currentTime;
    // Skip the last gain (LFO modulation)
    const ambientGains = ambientNodes.gains.slice(0, -1);
    ambientGains.forEach(gain => {
      gain.gain.setTargetAtTime(
        audioState.ambientVolume / ambientGains.length,
        now,
        0.1
      );
    });
  }

  window.dispatchEvent(new CustomEvent('audio:volumeChange', {
    detail: { volume: audioState.ambientVolume, type: 'ambient' }
  }));
}

/**
 * Set interaction sound volume
 * @param {number} volume - Volume level (0-1)
 */
export function setInteractionVolume(volume) {
  audioState.interactionVolume = Math.max(0, Math.min(1, volume));

  window.dispatchEvent(new CustomEvent('audio:volumeChange', {
    detail: { volume: audioState.interactionVolume, type: 'interaction' }
  }));
}

/**
 * Enable/disable tick sounds
 * @param {boolean} enabled - Whether tick sounds are enabled
 */
export function setTickEnabled(enabled) {
  audioState.tickEnabled = enabled;

  window.dispatchEvent(new CustomEvent('audio:tickToggle', {
    detail: { enabled }
  }));
}

/**
 * Enable/disable ambient sounds
 * @param {boolean} enabled - Whether ambient sounds are enabled
 */
export function setAmbientEnabled(enabled) {
  audioState.ambientEnabled = enabled;

  if (enabled && audioState.enabled && !audioState.muted) {
    startAmbient();
  } else {
    stopAmbient();
  }

  window.dispatchEvent(new CustomEvent('audio:ambientToggle', {
    detail: { enabled }
  }));
}

/**
 * Enable/disable interaction sounds
 * @param {boolean} enabled - Whether interaction sounds are enabled
 */
export function setInteractionEnabled(enabled) {
  audioState.interactionEnabled = enabled;

  window.dispatchEvent(new CustomEvent('audio:interactionToggle', {
    detail: { enabled }
  }));
}

/**
 * Get current audio state
 * @returns {Object} - Current audio state
 */
export function getState() {
  return { ...audioState };
}

/**
 * Cleanup and destroy audio context
 */
export function destroy() {
  stopAmbient();

  window.removeEventListener('clock:tick', handleClockTick);
  window.removeEventListener('settings:change', handleSettingsChange);

  if (audioContext) {
    audioContext.close();
    audioContext = null;
  }

  masterGain = null;
  audioState.initialized = false;
  audioState.enabled = false;

  console.log('[Audio] Destroyed');
}

export default {
  init,
  enable,
  disable,
  toggle,
  mute,
  unmute,
  toggleMute,
  playTick,
  playClick,
  playModeChange,
  playEnable,
  playDisable,
  playError,
  startAmbient,
  stopAmbient,
  setMasterVolume,
  setTickVolume,
  setAmbientVolume,
  setInteractionVolume,
  setTickEnabled,
  setAmbientEnabled,
  setInteractionEnabled,
  getState,
  destroy
};
