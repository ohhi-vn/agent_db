import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {}
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show())
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  applyStoredSidebar()
})

function storedSidebarState() {
  try {
    return window.localStorage.getItem("admin-sidebar") === "hidden" ? "hidden" : "shown"
  } catch (_e) {
    return "shown"
  }
}

function applySidebar(state) {
  const shell = document.getElementById("admin-shell")
  const sidebar = document.getElementById("admin-sidebar")
  const toggle = document.getElementById("sidebar-toggle")
  if (!shell || !sidebar || !toggle) return
  const hidden = state === "hidden"
  shell.setAttribute("data-sidebar", hidden ? "hidden" : "shown")
  if (hidden) {
    sidebar.setAttribute("hidden", "")
  } else {
    sidebar.removeAttribute("hidden")
  }
  toggle.setAttribute("aria-expanded", hidden ? "false" : "true")
}

function applyStoredSidebar() {
  applySidebar(storedSidebarState())
}

document.addEventListener("click", (event) => {
  const toggle = event.target.closest ? event.target.closest("#sidebar-toggle") : null
  if (!toggle) return
  const shell = document.getElementById("admin-shell")
  const next = shell && shell.getAttribute("data-sidebar") === "hidden" ? "shown" : "hidden"
  try {
    window.localStorage.setItem("admin-sidebar", next)
  } catch (_e) {
    // Private mode: keep per-click toggle without persistence.
  }
  applySidebar(next)
})

document.addEventListener("DOMContentLoaded", applyStoredSidebar)
applyStoredSidebar()

liveSocket.connect()

window.liveSocket = liveSocket