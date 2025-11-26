# Cyberpunk Clock

A cyberpunk-themed digital clock with neon glow effects.

## Features

- Real-time digital clock display
- Cyberpunk aesthetic with neon glow effects
- 12/24 hour format toggle
- Customizable color themes
- Visual effects (scanlines, grid overlay, glitch)
- Responsive design
- Settings persistence via localStorage

## Getting Started

### Prerequisites

- Node.js 18+ recommended

### Installation

```bash
npm install
```

### Development

Start the development server with hot-reload:

```bash
npm run dev
```

The app will open automatically at `http://localhost:3000`

### Build

Build for production:

```bash
npm run build
```

Preview the production build:

```bash
npm run preview
```

## Project Structure

```
work/
├── index.html              # Main HTML entry point
├── package.json            # Node.js dependencies and scripts
├── vite.config.js          # Vite build configuration
├── src/
│   ├── main.js            # Application entry point
│   ├── modules/           # JavaScript modules
│   │   ├── clock.js       # Clock logic
│   │   ├── settings.js    # Settings management
│   │   └── effects.js     # Visual effects
│   └── styles/            # CSS stylesheets
│       ├── main.css       # Main CSS entry
│       ├── reset.css      # CSS reset
│       ├── variables.css  # CSS custom properties
│       └── base.css       # Base styles
└── public/                # Static assets
```

## Workstreams

This project is developed in parallel workstreams:

1. **ws-1**: Project Setup & Base Structure (this workstream)
2. **ws-2**: Core Clock Logic & Time Display
3. **ws-3**: Cyberpunk Visual Design System
4. **ws-4**: Neon Glow Animations & Effects
5. **ws-5**: Sound Effects & Audio Feedback
6. **ws-6**: Interactive Controls & Settings Panel
7. **ws-7**: Responsive Design & Mobile Optimization
8. **ws-8**: Final Polish & Deployment

## License

MIT
