/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "../lib/**/*.ex",
    "../lib/**/*.heex",
    "./js/**/*.js"
  ],
  theme: {
    extend: {}
  },
  plugins: [require("daisyui")],
  daisyui: {
    themes: ["light"],
    // dark theme deferred; see design.md
  }
}