/**
 * Clock Module Tests
 * @workstream ws-2
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  padZero,
  getCurrentTime,
  getTimeComponents,
  convertTo12Hour,
  formatHours,
  formatMinutes,
  formatSeconds,
  formatTime,
  getDayName,
  getMonthName,
  getDateComponents,
  formatDate
} from '../src/modules/clock.js';

describe('Clock Module', () => {
  describe('padZero', () => {
    it('should pad single digit numbers with leading zero', () => {
      expect(padZero(0)).toBe('00');
      expect(padZero(1)).toBe('01');
      expect(padZero(9)).toBe('09');
    });

    it('should not pad double digit numbers', () => {
      expect(padZero(10)).toBe('10');
      expect(padZero(23)).toBe('23');
      expect(padZero(59)).toBe('59');
    });

    it('should support custom padding length', () => {
      expect(padZero(5, 3)).toBe('005');
      expect(padZero(42, 4)).toBe('0042');
      expect(padZero(123, 3)).toBe('123');
    });
  });

  describe('getCurrentTime', () => {
    it('should return a Date object', () => {
      const result = getCurrentTime();
      expect(result).toBeInstanceOf(Date);
    });

    it('should return current time', () => {
      const before = Date.now();
      const result = getCurrentTime();
      const after = Date.now();

      expect(result.getTime()).toBeGreaterThanOrEqual(before);
      expect(result.getTime()).toBeLessThanOrEqual(after);
    });
  });

  describe('getTimeComponents', () => {
    it('should extract all time components from a Date', () => {
      const date = new Date('2024-06-15T14:30:45.123');
      const components = getTimeComponents(date);

      expect(components).toEqual({
        hours: 14,
        minutes: 30,
        seconds: 45,
        milliseconds: 123
      });
    });

    it('should handle midnight correctly', () => {
      const date = new Date('2024-01-01T00:00:00.000');
      const components = getTimeComponents(date);

      expect(components.hours).toBe(0);
      expect(components.minutes).toBe(0);
      expect(components.seconds).toBe(0);
    });

    it('should handle end of day correctly', () => {
      const date = new Date('2024-01-01T23:59:59.999');
      const components = getTimeComponents(date);

      expect(components.hours).toBe(23);
      expect(components.minutes).toBe(59);
      expect(components.seconds).toBe(59);
      expect(components.milliseconds).toBe(999);
    });
  });

  describe('convertTo12Hour', () => {
    it('should convert midnight (0) to 12 AM', () => {
      const result = convertTo12Hour(0);
      expect(result).toEqual({ hours: 12, period: 'AM' });
    });

    it('should convert morning hours correctly', () => {
      expect(convertTo12Hour(1)).toEqual({ hours: 1, period: 'AM' });
      expect(convertTo12Hour(6)).toEqual({ hours: 6, period: 'AM' });
      expect(convertTo12Hour(11)).toEqual({ hours: 11, period: 'AM' });
    });

    it('should convert noon (12) to 12 PM', () => {
      const result = convertTo12Hour(12);
      expect(result).toEqual({ hours: 12, period: 'PM' });
    });

    it('should convert afternoon hours correctly', () => {
      expect(convertTo12Hour(13)).toEqual({ hours: 1, period: 'PM' });
      expect(convertTo12Hour(18)).toEqual({ hours: 6, period: 'PM' });
      expect(convertTo12Hour(23)).toEqual({ hours: 11, period: 'PM' });
    });
  });

  describe('formatHours', () => {
    it('should format hours in 12-hour mode by default', () => {
      expect(formatHours(0)).toBe('12');  // midnight
      expect(formatHours(1)).toBe('01');
      expect(formatHours(12)).toBe('12'); // noon
      expect(formatHours(13)).toBe('01');
      expect(formatHours(23)).toBe('11');
    });

    it('should format hours in 24-hour mode when specified', () => {
      expect(formatHours(0, true)).toBe('00');
      expect(formatHours(1, true)).toBe('01');
      expect(formatHours(12, true)).toBe('12');
      expect(formatHours(13, true)).toBe('13');
      expect(formatHours(23, true)).toBe('23');
    });
  });

  describe('formatMinutes', () => {
    it('should format minutes with leading zero', () => {
      expect(formatMinutes(0)).toBe('00');
      expect(formatMinutes(5)).toBe('05');
      expect(formatMinutes(30)).toBe('30');
      expect(formatMinutes(59)).toBe('59');
    });
  });

  describe('formatSeconds', () => {
    it('should format seconds with leading zero', () => {
      expect(formatSeconds(0)).toBe('00');
      expect(formatSeconds(7)).toBe('07');
      expect(formatSeconds(45)).toBe('45');
      expect(formatSeconds(59)).toBe('59');
    });
  });

  describe('formatTime', () => {
    it('should return all time components in 12-hour format', () => {
      const date = new Date('2024-06-15T14:30:45.123');
      const result = formatTime(date, { format24Hour: false });

      expect(result.hours).toBe('02');
      expect(result.minutes).toBe('30');
      expect(result.seconds).toBe('45');
      expect(result.milliseconds).toBe('123');
      expect(result.ampm).toBe('PM');
      expect(result.raw).toEqual({
        hours: 14,
        minutes: 30,
        seconds: 45,
        milliseconds: 123
      });
    });

    it('should return all time components in 24-hour format', () => {
      const date = new Date('2024-06-15T14:30:45.123');
      const result = formatTime(date, { format24Hour: true });

      expect(result.hours).toBe('14');
      expect(result.minutes).toBe('30');
      expect(result.seconds).toBe('45');
      expect(result.ampm).toBe('');
    });

    it('should handle AM times correctly', () => {
      const date = new Date('2024-06-15T09:15:30.000');
      const result = formatTime(date, { format24Hour: false });

      expect(result.hours).toBe('09');
      expect(result.ampm).toBe('AM');
    });

    it('should handle midnight correctly in 12-hour format', () => {
      const date = new Date('2024-06-15T00:00:00.000');
      const result = formatTime(date, { format24Hour: false });

      expect(result.hours).toBe('12');
      expect(result.ampm).toBe('AM');
    });

    it('should handle noon correctly in 12-hour format', () => {
      const date = new Date('2024-06-15T12:00:00.000');
      const result = formatTime(date, { format24Hour: false });

      expect(result.hours).toBe('12');
      expect(result.ampm).toBe('PM');
    });
  });

  describe('getDateComponents', () => {
    it('should extract all date components', () => {
      const date = new Date('2024-06-15T12:00:00');
      const components = getDateComponents(date);

      expect(components.dayOfWeek).toBe(6); // Saturday
      expect(components.dayOfMonth).toBe(15);
      expect(components.month).toBe(5); // June (0-indexed)
      expect(components.year).toBe(2024);
    });

    it('should handle first day of month', () => {
      const date = new Date('2024-01-01T00:00:00');
      const components = getDateComponents(date);

      expect(components.dayOfMonth).toBe(1);
      expect(components.month).toBe(0); // January
    });

    it('should handle last day of month', () => {
      const date = new Date('2024-12-31T23:59:59');
      const components = getDateComponents(date);

      expect(components.dayOfMonth).toBe(31);
      expect(components.month).toBe(11); // December
    });
  });

  describe('getDayName', () => {
    it('should return full day name by default', () => {
      const sunday = new Date('2024-06-16T12:00:00');
      expect(getDayName(sunday)).toBe('Sunday');

      const monday = new Date('2024-06-17T12:00:00');
      expect(getDayName(monday)).toBe('Monday');
    });

    it('should return short day name when specified', () => {
      const sunday = new Date('2024-06-16T12:00:00');
      expect(getDayName(sunday, 'en-US', 'short')).toBe('Sun');
    });
  });

  describe('getMonthName', () => {
    it('should return full month name by default', () => {
      const june = new Date('2024-06-15T12:00:00');
      expect(getMonthName(june)).toBe('June');

      const december = new Date('2024-12-15T12:00:00');
      expect(getMonthName(december)).toBe('December');
    });

    it('should return short month name when specified', () => {
      const june = new Date('2024-06-15T12:00:00');
      expect(getMonthName(june, 'en-US', 'short')).toBe('Jun');
    });
  });

  describe('formatDate', () => {
    const testDate = new Date('2024-06-15T12:00:00');

    it('should format date in full format', () => {
      const result = formatDate(testDate, 'full');
      expect(result).toContain('Saturday');
      expect(result).toContain('June');
      expect(result).toContain('15');
      expect(result).toContain('2024');
    });

    it('should format date in short format', () => {
      const result = formatDate(testDate, 'short');
      expect(result).toContain('Sat');
      expect(result).toContain('Jun');
      expect(result).toContain('15');
      expect(result).toContain('2024');
    });

    it('should format date in numeric format', () => {
      const result = formatDate(testDate, 'numeric');
      // Result format depends on locale, but should contain the date components
      expect(result).toMatch(/\d/);
    });

    it('should format date in ISO format', () => {
      const result = formatDate(testDate, 'iso');
      expect(result).toBe('2024-06-15');
    });

    it('should format date in cyberpunk format', () => {
      const result = formatDate(testDate, 'cyberpunk');
      expect(result).toBe('2024.06.15 // SAT');
    });

    it('should handle single-digit days and months in ISO format', () => {
      const date = new Date('2024-01-05T12:00:00');
      const result = formatDate(date, 'iso');
      expect(result).toBe('2024-01-05');
    });

    it('should default to full format for unknown format', () => {
      const result = formatDate(testDate, 'unknown');
      expect(result).toContain('Saturday');
      expect(result).toContain('June');
    });
  });
});
