/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./templates/**/*.html",
    "./src/js/**/*.js",
  ],
  theme: {
    extend: {},
  },
  plugins: [
    require("@tailwindcss/forms"),
    require("daisyui"),
  ],
  daisyui: {
    themes: ["dark", "light", "cupcake", "emerald", "corporate", "synthwave"],
  },
}