// The texts on the head unit screen.

const STRINGS = {
  headUnit: 'Multimedia',
  off: 'Turned off',
  offHint: 'Press power to turn on',
  connectPhone: 'Connect your phone',
  hint_airplay: 'iPhone: Control Center → AirPlay → “{name}”', // hint_<source id>, see state.sources
  noNetwork: 'No phones in sight: the PC and the phone must share a Wi-Fi network, set to Private in Windows',
  noNetworkTip: 'Settings → Network & Internet → Wi-Fi → your network → Private',
  receiverFailed: 'The receiver did not start',
  fromPhone: 'Music from your phone',
  prev: 'Previous',
  playPause: 'Play / pause',
  next: 'Next',
  volume: 'Phone volume (mouse wheel)',
  volumeDown: 'Quieter',
  volumeUp: 'Louder',
  power: 'Power',
  minimize: 'Minimize',
  settings: 'Settings',
  back: 'Back',
  fullSoundOutside: 'Full sound outside the car', // SETTINGS in headUnit.js
  modVolume: 'Overall volume',
  unlock: 'Click to turn the sound on',
  pillOff: 'off',
}

function text(key, params) {
  const value = STRINGS[key] || key
  return params ? value.replace(/\{(\w+)\}/g, (match, name) => params[name] ?? match) : value
}

export { text }
