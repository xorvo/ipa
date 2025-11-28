# Cyberpunk Digital Clock

A stunning cyberpunk-themed digital clock with neon effects, glitch animations, and futuristic styling.

## Features

### Visual Effects
- **Neon Glow**: Vibrant cyan, pink, and purple neon colors with animated glow effects
- **Glitch Effects**: Random glitch animations on title and time digits
- **Scanlines**: Authentic CRT monitor scanline overlay
- **Animated Border**: Gradient border that cycles through neon colors
- **Hex Background**: Scrolling hexadecimal pattern in the background

### Functionality
- **Real-time Clock**: Hours, minutes, seconds with millisecond precision
- **Date Display**: Current date in cyberpunk format (DD.MMM.YYYY)
- **Day of Week**: Shows current day in capital letters
- **Uptime Counter**: Tracks how long the clock has been running
- **Location Display**: Rotates through cyberpunk city names
- **Status Indicator**: Pulsing "ACTIVE" status

### Typography
- **Primary Font**: Orbitron (futuristic, geometric)
- **Monospace Font**: Share Tech Mono (terminal-style)
- High contrast with glowing text shadows

### Interactive Features

#### Keyboard Shortcuts
- **Press 'G'**: Trigger manual glitch effect
- **Press 'C'**: Cycle through different color themes

### Responsive Design
- Adapts to mobile devices (768px and 480px breakpoints)
- Maintains visual impact across screen sizes

## File Structure

```
work/
├── index.html      # Main HTML structure
├── style.css       # All styling and animations
├── script.js       # Clock functionality and effects
└── README.md       # Documentation
```

## Usage

1. Open `index.html` in any modern web browser
2. The clock will start automatically
3. Use keyboard shortcuts for interactive effects:
   - Press 'G' for glitch
   - Press 'C' to change colors

## Technical Details

### CSS Features
- CSS custom properties (variables) for easy theming
- Keyframe animations for glitch, pulse, and glow effects
- Flexbox layout for responsive design
- Linear gradients for depth
- Text shadows for neon glow effect
- Backdrop blur for glass morphism

### JavaScript Features
- Object-oriented design with `CyberpunkClock` class
- Interval-based time updates (10ms for milliseconds)
- Random glitch effect generation
- Dynamic hex pattern generation
- Event listeners for keyboard interaction

### Performance
- Optimized animations using CSS transforms
- Efficient DOM updates
- Minimal JavaScript footprint

## Browser Compatibility

Works best in modern browsers that support:
- CSS Grid and Flexbox
- CSS Custom Properties
- ES6 JavaScript classes
- Backdrop filters
- Text shadows and box shadows

Recommended browsers:
- Chrome 90+
- Firefox 88+
- Safari 14+
- Edge 90+

## Customization

### Colors
Edit the CSS variables in `style.css`:
```css
:root {
    --neon-cyan: #00ffff;
    --neon-pink: #ff00ff;
    --neon-purple: #9d00ff;
    --text-color: #00ff9f;
}
```

### Location Names
Edit the locations array in `script.js`:
```javascript
const locations = [
    'NIGHT CITY',
    'NEO TOKYO',
    // Add your own...
];
```

## Credits

Designed with cyberpunk aesthetics in mind, inspired by:
- Blade Runner
- Cyberpunk 2077
- Neuromancer
- Ghost in the Shell

Fonts from Google Fonts:
- Orbitron by Matt McInerney
- Share Tech Mono by Ralph du Carrois
