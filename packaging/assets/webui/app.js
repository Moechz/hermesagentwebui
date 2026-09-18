// Entry page shipped as webui.bz2 (official WebUI-app layout, F22).
// External Open mode: the App Center desktop icon opens the TOS nginx
// route /hermesagent/ in a new browser tab; this page only needs to
// forward there (and provide a manual link if JS is disabled).
window.location.replace("/hermesagent/");
