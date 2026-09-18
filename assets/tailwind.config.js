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
  plugins: [],
  corePlugins: {
    preflight: false
  }
}