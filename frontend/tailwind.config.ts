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
          400: "#34d399",
          500: "#10b981"
        }
      }
    }
  },
  plugins: []
} satisfies Config;
