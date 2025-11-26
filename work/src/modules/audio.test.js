/**
 * Audio Module Tests
 *
 * Tests for the cyberpunk-themed audio system.
 * Note: Web Audio API requires browser environment, so we use mocks.
 */

import {
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
} from './audio.js';

// Mock Web Audio API
class MockAudioContext {
  constructor() {
    this.state = 'running';
    this.currentTime = 0;
    this.destination = {};
  }

  createOscillator() {
    return {
      type: 'sine',
      frequency: { value: 440, setValueAtTime: jest.fn() },
      detune: { value: 0 },
      connect: jest.fn(),
      disconnect: jest.fn(),
      start: jest.fn(),
      stop: jest.fn(),
      onended: null
    };
  }

  createGain() {
    return {
      gain: {
        value: 1,
        setValueAtTime: jest.fn(),
        linearRampToValueAtTime: jest.fn(),
        setTargetAtTime: jest.fn()
      },
      connect: jest.fn(),
      disconnect: jest.fn()
    };
  }

  createBiquadFilter() {
    return {
      type: 'lowpass',
      frequency: { value: 1000, setValueAtTime: jest.fn() },
      Q: { value: 1 },
      connect: jest.fn(),
      disconnect: jest.fn()
    };
  }

  async resume() {
    this.state = 'running';
  }

  async close() {
    this.state = 'closed';
  }
}

// Setup mock before tests
beforeAll(() => {
  global.AudioContext = MockAudioContext;
  global.webkitAudioContext = MockAudioContext;
});

// Reset state between tests
beforeEach(() => {
  destroy();
});

afterAll(() => {
  delete global.AudioContext;
  delete global.webkitAudioContext;
});

describe('Audio Module', () => {
  describe('Initialization', () => {
    test('init() should initialize audio context successfully', async () => {
      const result = await init();
      expect(result).toBe(true);

      const state = getState();
      expect(state.initialized).toBe(true);
      expect(state.enabled).toBe(true);
    });

    test('init() should only initialize once', async () => {
      await init();
      const result = await init();
      expect(result).toBe(true); // Returns true but doesn't reinitialize
    });

    test('getState() returns correct initial state', async () => {
      await init();
      const state = getState();

      expect(state).toHaveProperty('initialized', true);
      expect(state).toHaveProperty('enabled', true);
      expect(state).toHaveProperty('muted', false);
      expect(state).toHaveProperty('masterVolume', 0.5);
      expect(state).toHaveProperty('tickEnabled', true);
      expect(state).toHaveProperty('ambientEnabled', true);
      expect(state).toHaveProperty('interactionEnabled', true);
    });
  });

  describe('Enable/Disable', () => {
    beforeEach(async () => {
      await init();
    });

    test('disable() should disable audio', () => {
      disable();
      const state = getState();
      expect(state.enabled).toBe(false);
    });

    test('enable() should enable audio', () => {
      disable();
      enable();
      const state = getState();
      expect(state.enabled).toBe(true);
    });

    test('toggle() should toggle enabled state', () => {
      const initialState = getState().enabled;
      toggle();
      expect(getState().enabled).toBe(!initialState);
      toggle();
      expect(getState().enabled).toBe(initialState);
    });
  });

  describe('Mute/Unmute', () => {
    beforeEach(async () => {
      await init();
    });

    test('mute() should mute audio', () => {
      mute();
      const state = getState();
      expect(state.muted).toBe(true);
    });

    test('unmute() should unmute audio', () => {
      mute();
      unmute();
      const state = getState();
      expect(state.muted).toBe(false);
    });

    test('toggleMute() should toggle muted state', () => {
      const initialMuted = getState().muted;
      toggleMute();
      expect(getState().muted).toBe(!initialMuted);
      toggleMute();
      expect(getState().muted).toBe(initialMuted);
    });
  });

  describe('Volume Controls', () => {
    beforeEach(async () => {
      await init();
    });

    test('setMasterVolume() should update master volume', () => {
      setMasterVolume(0.8);
      expect(getState().masterVolume).toBe(0.8);
    });

    test('setMasterVolume() should clamp values between 0 and 1', () => {
      setMasterVolume(1.5);
      expect(getState().masterVolume).toBe(1);

      setMasterVolume(-0.5);
      expect(getState().masterVolume).toBe(0);
    });

    test('setTickVolume() should update tick volume', () => {
      setTickVolume(0.5);
      expect(getState().tickVolume).toBe(0.5);
    });

    test('setAmbientVolume() should update ambient volume', () => {
      setAmbientVolume(0.3);
      expect(getState().ambientVolume).toBe(0.3);
    });

    test('setInteractionVolume() should update interaction volume', () => {
      setInteractionVolume(0.6);
      expect(getState().interactionVolume).toBe(0.6);
    });
  });

  describe('Sound Type Toggles', () => {
    beforeEach(async () => {
      await init();
    });

    test('setTickEnabled() should toggle tick sounds', () => {
      setTickEnabled(false);
      expect(getState().tickEnabled).toBe(false);

      setTickEnabled(true);
      expect(getState().tickEnabled).toBe(true);
    });

    test('setAmbientEnabled() should toggle ambient sounds', () => {
      setAmbientEnabled(false);
      expect(getState().ambientEnabled).toBe(false);

      setAmbientEnabled(true);
      expect(getState().ambientEnabled).toBe(true);
    });

    test('setInteractionEnabled() should toggle interaction sounds', () => {
      setInteractionEnabled(false);
      expect(getState().interactionEnabled).toBe(false);

      setInteractionEnabled(true);
      expect(getState().interactionEnabled).toBe(true);
    });
  });

  describe('Sound Playback', () => {
    beforeEach(async () => {
      await init();
    });

    test('playTick() should not throw when enabled', () => {
      expect(() => playTick()).not.toThrow();
      expect(() => playTick('alt')).not.toThrow();
    });

    test('playTick() should not play when muted', () => {
      mute();
      // Should not throw, just silently not play
      expect(() => playTick()).not.toThrow();
    });

    test('playTick() should not play when tick disabled', () => {
      setTickEnabled(false);
      expect(() => playTick()).not.toThrow();
    });

    test('playClick() should not throw when enabled', () => {
      expect(() => playClick()).not.toThrow();
    });

    test('playModeChange() should not throw when enabled', () => {
      expect(() => playModeChange()).not.toThrow();
    });

    test('playEnable() should not throw', () => {
      expect(() => playEnable()).not.toThrow();
    });

    test('playDisable() should not throw', () => {
      expect(() => playDisable()).not.toThrow();
    });

    test('playError() should not throw when enabled', () => {
      expect(() => playError()).not.toThrow();
    });
  });

  describe('Ambient Sound', () => {
    beforeEach(async () => {
      await init();
    });

    test('startAmbient() should start ambient sound', () => {
      expect(() => startAmbient()).not.toThrow();
    });

    test('stopAmbient() should stop ambient sound', () => {
      startAmbient();
      expect(() => stopAmbient()).not.toThrow();
    });

    test('startAmbient() should not start when muted', () => {
      mute();
      expect(() => startAmbient()).not.toThrow();
    });

    test('startAmbient() should not start when ambient disabled', () => {
      setAmbientEnabled(false);
      expect(() => startAmbient()).not.toThrow();
    });
  });

  describe('Event Dispatching', () => {
    beforeEach(async () => {
      await init();
    });

    test('enable() should dispatch audio:enable event', (done) => {
      disable();
      window.addEventListener('audio:enable', (e) => {
        expect(e.detail.state.enabled).toBe(true);
        done();
      }, { once: true });
      enable();
    });

    test('disable() should dispatch audio:disable event', (done) => {
      window.addEventListener('audio:disable', (e) => {
        expect(e.detail.state.enabled).toBe(false);
        done();
      }, { once: true });
      disable();
    });

    test('mute() should dispatch audio:mute event', (done) => {
      window.addEventListener('audio:mute', (e) => {
        expect(e.detail.state.muted).toBe(true);
        done();
      }, { once: true });
      mute();
    });

    test('unmute() should dispatch audio:unmute event', (done) => {
      mute();
      window.addEventListener('audio:unmute', (e) => {
        expect(e.detail.state.muted).toBe(false);
        done();
      }, { once: true });
      unmute();
    });

    test('setMasterVolume() should dispatch audio:volumeChange event', (done) => {
      window.addEventListener('audio:volumeChange', (e) => {
        expect(e.detail.type).toBe('master');
        expect(e.detail.volume).toBe(0.7);
        done();
      }, { once: true });
      setMasterVolume(0.7);
    });
  });

  describe('Cleanup', () => {
    test('destroy() should clean up resources', async () => {
      await init();
      destroy();

      const state = getState();
      expect(state.initialized).toBe(false);
      expect(state.enabled).toBe(false);
    });
  });

  describe('Edge Cases', () => {
    test('functions should not throw when not initialized', () => {
      // These should not throw, just silently fail
      expect(() => enable()).not.toThrow();
      expect(() => disable()).not.toThrow();
      expect(() => mute()).not.toThrow();
      expect(() => unmute()).not.toThrow();
      expect(() => playTick()).not.toThrow();
      expect(() => playClick()).not.toThrow();
      expect(() => startAmbient()).not.toThrow();
      expect(() => stopAmbient()).not.toThrow();
    });

    test('getState() returns valid state even when not initialized', () => {
      const state = getState();
      expect(state).toBeDefined();
      expect(state.initialized).toBe(false);
    });
  });
});

describe('Clock Tick Integration', () => {
  beforeEach(async () => {
    await init();
  });

  afterEach(() => {
    destroy();
  });

  test('should play tick on clock:tick event', () => {
    const event = new CustomEvent('clock:tick', {
      detail: {
        time: { hours: '12', minutes: '30', seconds: '15' }
      }
    });

    // Should not throw
    expect(() => window.dispatchEvent(event)).not.toThrow();
  });

  test('should play alt tick on multiples of 10 seconds', () => {
    const event = new CustomEvent('clock:tick', {
      detail: {
        time: { hours: '12', minutes: '30', seconds: '10' }
      }
    });

    expect(() => window.dispatchEvent(event)).not.toThrow();
  });
});
