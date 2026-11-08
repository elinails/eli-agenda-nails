/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./index.html'],
  theme: {
    extend: {
      colors: {
        // A1b · Blush Atelier (siguen el tema claro/oscuro)
        'paper':    'var(--paper)',
        'surface':  'var(--surface)',
        'ink':      'var(--ink)',
        'ink-soft': 'var(--ink-soft)',
        'line':     'var(--line)',
        'blush':    'var(--blush)',
        'blush-2':  'var(--blush-2)',
        'gold':     'var(--gold)',
        'gold-ink': 'var(--gold-ink)',
        'st-pending':   'var(--pending)',
        'st-confirmed': 'var(--confirmed)',
        'st-done':      'var(--done)',
        'st-cancelled': 'var(--cancelled)',
        // compatibilidad con los nombres anteriores
        'eli-pink':  'var(--blush-2)',
        'eli-lilac': 'var(--blush)',
        'eli-gold':  'var(--gold)',
        'eli-green': 'var(--confirmed-tint)',
        'eli-gray':  'var(--cancelled-tint)',
        'eli-dark':  'var(--ink)',
      },
      fontFamily: {
        'display': ['"Cormorant Garamond"', 'Georgia', 'serif'],
        'sans': ['Inter', 'ui-sans-serif', 'sans-serif'],
      },
      animation: {
        'fade-in': 'fadeIn 0.3s ease-in-out',
        'slide-up': 'slideUp 0.3s ease-out',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        slideUp: {
          '0%': { transform: 'translateY(20px)', opacity: '0' },
          '100%': { transform: 'translateY(0)', opacity: '1' },
        }
      }
    }
  },
  plugins: [],
};