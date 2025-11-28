// Cyberpunk Clock JavaScript

class CyberpunkClock {
    constructor() {
        this.startTime = Date.now();
        this.hexChars = '0123456789ABCDEF';
        this.init();
    }

    init() {
        this.updateClock();
        this.updateDate();
        this.updateUptime();
        this.generateHexBackground();

        // Update clock every 10ms for smooth milliseconds
        setInterval(() => this.updateClock(), 10);

        // Update date every second
        setInterval(() => this.updateDate(), 1000);

        // Update uptime every second
        setInterval(() => this.updateUptime(), 1000);

        // Regenerate hex background every 5 seconds
        setInterval(() => this.generateHexBackground(), 5000);

        // Add random glitch effects
        this.startGlitchEffects();
    }

    updateClock() {
        const now = new Date();

        const hours = this.padZero(now.getHours());
        const minutes = this.padZero(now.getMinutes());
        const seconds = this.padZero(now.getSeconds());
        const milliseconds = this.padZero(Math.floor(now.getMilliseconds() / 10), 2);

        document.getElementById('hours').textContent = hours;
        document.getElementById('minutes').textContent = minutes;
        document.getElementById('seconds').textContent = seconds;
        document.getElementById('milliseconds').textContent = `.${milliseconds}`;
    }

    updateDate() {
        const now = new Date();
        const days = ['SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY'];
        const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

        const day = days[now.getDay()];
        const date = this.padZero(now.getDate());
        const month = months[now.getMonth()];
        const year = now.getFullYear();

        document.getElementById('date').textContent = `${date}.${month}.${year}`;
        document.getElementById('day').textContent = day;
    }

    updateUptime() {
        const elapsed = Date.now() - this.startTime;
        const hours = Math.floor(elapsed / (1000 * 60 * 60));
        const minutes = Math.floor((elapsed % (1000 * 60 * 60)) / (1000 * 60));
        const seconds = Math.floor((elapsed % (1000 * 60)) / 1000);

        const uptimeString = `${this.padZero(hours)}:${this.padZero(minutes)}:${this.padZero(seconds)}`;
        document.getElementById('uptime').textContent = uptimeString;
    }

    padZero(num, length = 2) {
        return String(num).padStart(length, '0');
    }

    generateHexBackground() {
        for (let i = 1; i <= 3; i++) {
            const hexRow = document.getElementById(`hex-row-${i}`);
            let hexString = '';

            // Generate random hex strings
            for (let j = 0; j < 50; j++) {
                hexString += this.generateRandomHex() + ' ';
            }

            hexRow.textContent = hexString;
        }
    }

    generateRandomHex() {
        let hex = '0x';
        for (let i = 0; i < 4; i++) {
            hex += this.hexChars.charAt(Math.floor(Math.random() * this.hexChars.length));
        }
        return hex;
    }

    startGlitchEffects() {
        // Randomly apply glitch effect to time digits
        setInterval(() => {
            if (Math.random() > 0.95) {
                const digits = document.querySelectorAll('.time-digit');
                const randomDigit = digits[Math.floor(Math.random() * digits.length)];

                randomDigit.style.transform = `translate(${Math.random() * 4 - 2}px, ${Math.random() * 4 - 2}px)`;

                setTimeout(() => {
                    randomDigit.style.transform = 'translate(0, 0)';
                }, 50);
            }
        }, 100);

        // Random color shift effect
        setInterval(() => {
            if (Math.random() > 0.98) {
                const container = document.querySelector('.clock-container');
                const colors = ['--neon-cyan', '--neon-pink', '--neon-purple'];
                const randomColor = colors[Math.floor(Math.random() * colors.length)];

                container.style.borderColor = `var(${randomColor})`;

                setTimeout(() => {
                    container.style.borderColor = 'var(--neon-cyan)';
                }, 200);
            }
        }, 500);
    }
}

// Initialize the clock when the page loads
document.addEventListener('DOMContentLoaded', () => {
    new CyberpunkClock();

    // Add random location names for cyberpunk feel
    const locations = [
        'NIGHT CITY',
        'NEO TOKYO',
        'CYBER DISTRICT',
        'SECTOR 7',
        'THE SPRAWL',
        'BLADE RUNNER 2049'
    ];

    // Change location every 10 seconds
    setInterval(() => {
        const locationElement = document.getElementById('location');
        const randomLocation = locations[Math.floor(Math.random() * locations.length)];
        locationElement.textContent = randomLocation;
    }, 10000);
});

// Add keyboard shortcuts for fun
document.addEventListener('keydown', (e) => {
    // Press 'G' for manual glitch effect
    if (e.key.toLowerCase() === 'g') {
        const title = document.querySelector('.title');
        title.style.animation = 'none';
        setTimeout(() => {
            title.style.animation = '';
        }, 100);
    }

    // Press 'C' to cycle through color themes
    if (e.key.toLowerCase() === 'c') {
        const root = document.documentElement;
        const colors = [
            { cyan: '#00ffff', pink: '#ff00ff', text: '#00ff9f' },
            { cyan: '#ff0000', pink: '#ffff00', text: '#ff6600' },
            { cyan: '#00ff00', pink: '#0000ff', text: '#00ffff' },
            { cyan: '#ff00ff', pink: '#00ffff', text: '#ff00ff' }
        ];

        const randomTheme = colors[Math.floor(Math.random() * colors.length)];
        root.style.setProperty('--neon-cyan', randomTheme.cyan);
        root.style.setProperty('--neon-pink', randomTheme.pink);
        root.style.setProperty('--text-color', randomTheme.text);
    }
});
