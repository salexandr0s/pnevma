import type { Config } from "tailwindcss";

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: {
          950: "#080e1a",
          900: "#0f172a"
        },
        mint: {
          300: "#6ee7b7",
          400: "#34d399",
          500: "#10b981"
        }
      },
      keyframes: {
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" }
        },
        "pulse-dot": {
          "0%, 100%": { transform: "scale(1)", opacity: "1" },
          "50%": { transform: "scale(1.3)", opacity: "0.6" }
        }
      },
      animation: {
        shimmer: "shimmer 1.5s ease-in-out infinite",
        "pulse-dot": "pulse-dot 2s ease-in-out infinite"
      }
    }
  },
  plugins: []
} satisfies Config;
