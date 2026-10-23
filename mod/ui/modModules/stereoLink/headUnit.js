// The head unit: a compact screen shown over the HUD while you sit in a car (and inside the
// optional "StereoLink" UI app). Drag it anywhere; the mouse wheel over it sets the phone volume.

import { text } from './strings.js'

const svg = path => `<svg viewBox="0 0 24 24" aria-hidden="true">${path}</svg>`

const ICONS = {
  power: svg('<path d="M12 3v8" stroke-linecap="round"/><path d="M7.1 6.6a7 7 0 1 0 9.8 0" fill="none" stroke-linecap="round"/>'),
  minimize: svg('<path d="M6 12h12" stroke-linecap="round"/>'),
  gear: svg('<circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2.2"/><path d="M12 2.5V6M12 18v3.5M2.5 12H6M18 12h3.5M5.3 5.3l2.5 2.5M16.2 16.2l2.5 2.5M18.7 5.3l-2.5 2.5M7.8 16.2l-2.5 2.5" stroke-width="3"/>'),
  back: svg('<path d="M14.5 6l-6 6 6 6" stroke-linecap="round" stroke-linejoin="round"/>'),
  check: svg('<path d="M6 12.5l4 4 8-9" stroke-linecap="round" stroke-linejoin="round" stroke-width="3"/>'),
  minus: svg('<path d="M6 12h12" stroke-linecap="round"/>'),
  plus: svg('<path d="M12 6v12M6 12h12" stroke-linecap="round"/>'),
  prev: svg('<path d="M7 6v12" stroke-linecap="round"/><path d="M18 6.5v11L9.5 12z" fill="currentColor" stroke="none"/>'),
  next: svg('<path d="M17 6v12" stroke-linecap="round"/><path d="M6 6.5v11l8.5-5.5z" fill="currentColor" stroke="none"/>'),
  play: svg('<path d="M8 5.5v13l10.5-6.5z" fill="currentColor" stroke="none"/>'),
  pause: svg('<path d="M8.5 6v12M15.5 6v12" stroke-linecap="round" stroke-width="3"/>'),
  volume: svg('<path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4 4 0 0 1 0 6" fill="none" stroke-linecap="round"/>'),
  airplay: svg('<path d="M6 17H4.5A1.5 1.5 0 0 1 3 15.5v-9A1.5 1.5 0 0 1 4.5 5h15A1.5 1.5 0 0 1 21 6.5v9a1.5 1.5 0 0 1-1.5 1.5H18" fill="none" stroke-linejoin="round"/><path d="M12 14l5 6H7z" fill="currentColor" stroke="none"/>'),
  note: svg('<path d="M9 17.5V6l10-2v11.5" fill="none" stroke-linejoin="round"/><circle cx="6.5" cy="17.5" r="2.5" fill="currentColor" stroke="none"/><circle cx="16.5" cy="15.5" r="2.5" fill="currentColor" stroke="none"/>'),
}

const STYLE = `
<style>
  .sl { position: relative; width: 100%; height: 100%; box-sizing: border-box; overflow: hidden; pointer-events: auto;
    border-radius: 12px; color: #f2f4f8; font-family: 'Overpass', 'Segoe UI', sans-serif; user-select: none;
    background: linear-gradient(135deg, rgba(36,39,48,.94), rgba(12,13,17,.94));
    box-shadow: inset 0 0 0 1px rgba(255,255,255,.07), 0 4px 16px rgba(0,0,0,.45); }
  .sl svg { width: 100%; height: 100%; stroke: currentColor; stroke-width: 2; fill: none; }
  .sl-backdrop { position: absolute; inset: -20px; background-size: cover; background-position: center; filter: blur(22px) saturate(1.4); opacity: .32; }
  .sl-row { position: relative; height: 100%; display: flex; align-items: center; gap: 10px; padding: 0 10px 0 12px; box-sizing: border-box; }
  .sl-cover { width: 64px; height: 64px; border-radius: 8px; flex: none; background: #1d2029 center/cover no-repeat;
    box-shadow: 0 2px 10px rgba(0,0,0,.5); display: flex; align-items: center; justify-content: center; color: #4a5060; }
  .sl-cover .sl-glyph { width: 28px; height: 28px; }
  .sl-badge { width: 46px; height: 46px; flex: none; display: flex; align-items: center; justify-content: center; color: #6d7486; }
  .sl-badge .sl-glyph { width: 30px; height: 30px; }
  .sl-badge.pulse { animation: slPulse 2.4s ease-in-out infinite; }
  .sl-meta { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; padding-right: 56px; }
  .sl-source { font-size: 9.5px; letter-spacing: .08em; text-transform: uppercase; color: #4cd964; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sl-source.dim { color: #8b92a3; }
  .sl-title { font-size: 13.5px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sl-artist { font-size: 11.5px; color: #c0c6d3; min-height: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sl-hint { font-size: 11px; color: #a8aebd; line-height: 1.3; }
  .sl-warn { color: #ffcc66; }
  .sl-controls { display: flex; align-items: center; gap: 2px; margin-top: 3px; }
  .sl-button { border: 0; background: transparent; color: #f2f4f8; cursor: pointer; border-radius: 7px; height: 24px; width: 28px;
    padding: 4px; box-sizing: border-box; display: inline-flex; align-items: center; justify-content: center; }
  .sl-button:hover { background: rgba(255,255,255,.12); }
  .sl-button:disabled { opacity: .35; cursor: default; background: transparent; }
  .sl-volume { margin-left: auto; display: flex; align-items: center; gap: 3px; font-size: 10.5px; color: #8b92a3; white-space: nowrap; }
  .sl-volume .sl-glyph { width: 13px; height: 13px; }
  .sl-volume .sl-button { width: 18px; height: 18px; padding: 2px; border-radius: 5px; color: #8b92a3; }
  .sl-volume-value { min-width: 19px; text-align: center; }
  .sl-corner { position: absolute; top: 4px; right: 4px; display: flex; gap: 1px; }
  .sl-corner .sl-button { height: 20px; width: 20px; padding: 3px; color: #8b92a3; }
  .sl-corner .sl-button.on { color: #4cd964; }
  .sl-settings { position: relative; height: 100%; display: flex; flex-direction: column; padding: 4px 10px 6px 6px; box-sizing: border-box; }
  .sl-settings-head { flex: none; height: 22px; display: flex; align-items: center; gap: 4px; padding-right: 64px; }
  .sl-settings-title { font-size: 12.5px; font-weight: 700; }
  .sl-settings-list { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 3px; padding-left: 4px; }
  .sl-settings-list > :first-child { margin-top: auto; }
  .sl-settings-list > :last-child { margin-bottom: auto; }
  .sl-option { flex: none; border: 0; background: transparent; color: #f2f4f8; font: inherit; font-size: 11.5px; cursor: pointer;
    display: flex; align-items: center; gap: 8px; height: 22px; padding: 0 6px; border-radius: 7px; text-align: left; }
  .sl-option:hover { background: rgba(255,255,255,.08); }
  .sl-check { width: 14px; height: 14px; flex: none; box-sizing: border-box; padding: 1px; border-radius: 4px;
    box-shadow: inset 0 0 0 1.5px #8b92a3; color: transparent; }
  .sl-check.on { background: #4cd964; box-shadow: none; color: #0c0d11; }
  .sl-check .sl-glyph { display: block; width: 100%; height: 100%; }
  .sl-level { flex: none; display: flex; align-items: center; gap: 2px; height: 24px; padding: 0 0 0 6px; font-size: 11.5px; }
  .sl-level-label { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sl-level-value { min-width: 36px; text-align: center; font-size: 11px; color: #c0c6d3; }
  .sl-progress { position: absolute; left: 0; right: 0; bottom: 0; height: 2px; background: rgba(255,255,255,.08); }
  .sl-progress > div { height: 100%; background: rgba(242,244,248,.85); }
  .sl-unlock { position: absolute; inset: 0; background: rgba(8,9,12,.78); display: flex; align-items: center; justify-content: center;
    gap: 8px; cursor: pointer; font-size: 12.5px; font-weight: 700; }
  .sl-unlock .sl-glyph { width: 16px; height: 16px; }
  .sl.off .sl-row { opacity: .7; } /* settings stay usable while the receiver is off */
  @keyframes slPulse { 0%,100% { opacity: .45; transform: scale(.94) } 50% { opacity: 1; transform: scale(1.05) } }
</style>`

const icon = (name, attributes = '') => `<span class="sl-glyph" ${attributes}>${ICONS[name]}</span>`

// Sources with their own badge icon; any other source shows the note.
const SOURCE_ICONS = new Set(['airplay'])
const COVER_DATA_URI = /^data:image\/(jpeg|png|gif|webp);base64,[A-Za-z0-9+/]+=*$/

// The cover ends up in CSS url(), so only an inline image passes: anything else could make
// the browser fetch an address from the network.
function coverBackground(cover) {
  if (typeof cover !== 'string' || !COVER_DATA_URI.test(cover)) return null
  return { 'background-image': `url("${cover}")` }
}

const HEAD_UNIT = `
<div class="sl" ng-class="{off: !s.power}">
  ${STYLE}
  <div class="sl-backdrop" ng-if="coverStyle && s.connected" ng-style="coverStyle"></div>

  <div class="sl-row" ng-if="view === 'player'">
    <div class="sl-badge" ng-if="!s.power">${icon('power')}</div>
    <div class="sl-meta" ng-if="!s.power">
      <div class="sl-title">{{ t('headUnit') }}</div>
      <div class="sl-hint">{{ t('off') }} · {{ t('offHint') }}</div>
    </div>

    <div class="sl-badge pulse" ng-if="s.power && !s.connected">
      ${icon('airplay', `ng-if="badgeIcon() === 'airplay'"`)}${icon('note', `ng-if="badgeIcon() !== 'airplay'"`)}
    </div>
    <div class="sl-meta" ng-if="s.power && !s.connected">
      <div class="sl-source dim">{{ s.name }}</div>
      <div class="sl-title">{{ t('connectPhone') }}</div>
      <div class="sl-hint sl-warn" ng-if="!s.running">{{ s.error || t('receiverFailed') }}</div>
      <div class="sl-hint sl-warn" ng-if="s.running && noNetwork()" title="{{ t('noNetworkTip') }}">{{ t('noNetwork') }}</div>
      <div ng-if="s.running && !noNetwork()">
        <div class="sl-hint" ng-repeat="source in sources() track by source.id">{{ hint(source) }}</div>
      </div>
    </div>

    <div class="sl-cover" ng-if="s.power && s.connected" ng-style="coverStyle">
      <span ng-if="!coverStyle">${icon('note')}</span>
    </div>
    <div class="sl-meta" ng-if="s.power && s.connected">
      <div class="sl-source">{{ s.source }}<span ng-if="s.device"> · {{ s.device }}</span></div>
      <div class="sl-title">{{ s.title || t('fromPhone') }}</div>
      <div class="sl-artist">{{ s.artist }}</div>
      <div class="sl-controls">
        <button class="sl-button" ng-disabled="!s.canControl" ng-click="control('prev')" title="{{ t('prev') }}">${icon('prev')}</button>
        <button class="sl-button" ng-disabled="!s.canControl" ng-click="control('playpause')" title="{{ t('playPause') }}">
          <span ng-if="s.playing">${icon('pause')}</span><span ng-if="!s.playing">${icon('play')}</span>
        </button>
        <button class="sl-button" ng-disabled="!s.canControl" ng-click="control('next')" title="{{ t('next') }}">${icon('next')}</button>
        <div class="sl-volume" title="{{ t('volume') }}">
          ${icon('volume')}
          <button class="sl-button" ng-click="stepVolume(-1)" title="{{ t('volumeDown') }}">${icon('minus')}</button>
          <span class="sl-volume-value">{{ volumePercent() }}</span>
          <button class="sl-button" ng-click="stepVolume(1)" title="{{ t('volumeUp') }}">${icon('plus')}</button>
        </div>
      </div>
    </div>
  </div>

  <div class="sl-settings" ng-if="view === 'settings'">
    <div class="sl-settings-head">
      <button class="sl-button" ng-click="showPlayer()" title="{{ t('back') }}">${icon('back')}</button>
      <div class="sl-settings-title">{{ t('settings') }}</div>
    </div>
    <div class="sl-settings-list">
      <button class="sl-option" ng-repeat="setting in settings track by setting.key" role="checkbox"
        aria-checked="{{ isOn(setting.key) }}" ng-click="toggleOption(setting.key)">
        <span class="sl-check" ng-class="{on: isOn(setting.key)}">${icon('check')}</span>{{ t(setting.label) }}
      </button>
      <div class="sl-level">
        <span class="sl-level-label">{{ t('modVolume') }}</span>
        <button class="sl-button" ng-click="stepModVolume(-1)" title="{{ t('volumeDown') }}">${icon('minus')}</button>
        <span class="sl-level-value">{{ modVolumePercent() }}%</span>
        <button class="sl-button" ng-click="stepModVolume(1)" title="{{ t('volumeUp') }}">${icon('plus')}</button>
      </div>
    </div>
  </div>

  <div class="sl-corner">
    <button class="sl-button" ng-class="{on: s.power}" ng-click="togglePower()" title="{{ t('power') }}">${icon('power')}</button>
    <button class="sl-button" ng-class="{on: view === 'settings'}" ng-click="toggleSettings()" title="{{ t('settings') }}">${icon('gear')}</button>
    <button class="sl-button" ng-if="overlay" ng-click="minimize()" title="{{ t('minimize') }}">${icon('minimize')}</button>
  </div>

  <div class="sl-progress" ng-if="view === 'player' && s.connected && s.duration > 0"><div ng-style="{width: progressPercent() + '%'}"></div></div>

  <div class="sl-unlock" ng-if="view === 'player' && s.power && s.connected && !audible" ng-click="unlock()">${icon('play')} {{ t('unlock') }}</div>
</div>`

const PILL = `
<div class="sl-pill">
  <style>
    .sl-pill { pointer-events: auto; cursor: pointer; display: flex; align-items: center; gap: 7px; max-width: 260px;
      padding: 5px 11px; border-radius: 999px; color: #f2f4f8; font: 12px 'Overpass', 'Segoe UI', sans-serif;
      background: rgba(14,15,19,.86); box-shadow: inset 0 0 0 1px rgba(255,255,255,.08), 0 3px 10px rgba(0,0,0,.4); }
    .sl-pill .dot { width: 6px; height: 6px; border-radius: 50%; background: #3a3f4c; flex: none; }
    .sl-pill .dot.on { background: #4cd964; box-shadow: 0 0 5px #4cd964; }
    .sl-pill .text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .sl-pill svg { width: 13px; height: 13px; flex: none; stroke: currentColor; stroke-width: 2; fill: none; color: #a8aebd; }
  </style>
  <div class="dot" ng-class="{on: s.connected}"></div>
  ${ICONS.note}
  <div class="text">{{ pillText() }}</div>
</div>`

// The checkboxes of the settings panel: an option key from Lua's preferences.lua (OPTIONS) and
// the strings.js key of its label. A new option is one entry here.
const SETTINGS = [
  { key: 'fullSoundOutside', label: 'fullSoundOutside' },
]

const WIDTH = 320
const HEIGHT = 92
const VOLUME_STEP = 1 / 16 // one press of the phone's volume buttons, so the slider follows every notch
const TICK_MS = 500
const NETWORK_GRACE_MS = 8000 // a phone needs a few seconds to show up before we blame the network
const DRAG_THRESHOLD_PX = 4
const PRIMARY_BUTTON = 1

function readStorage(key) {
  try { return localStorage.getItem(key) } catch (e) { return null }
}

function writeStorage(key, value) {
  try { localStorage.setItem(key, value) } catch (e) { /* private mode or blocked storage */ }
}

function registerHeadUnit(module, multimedia) {
  module.directive('slHeadUnit', ['$interval', $interval => ({
    restrict: 'E',
    replace: true,
    scope: { overlay: '=?', onMinimize: '&?' },
    template: HEAD_UNIT,
    link(scope, element) {
      scope.s = {}
      scope.coverStyle = coverBackground(multimedia.cover)
      scope.audible = true
      scope.position = 0
      const shownAt = Date.now()

      const trackPosition = () => {
        const s = scope.s
        const elapsed = s.playing && s.receivedAt ? (Date.now() - s.receivedAt) / 1000 : 0
        return Math.max(0, Math.min(s.duration || 0, (s.position || 0) + elapsed))
      }
      const refresh = () => {
        scope.position = trackPosition()
        scope.audible = multimedia.player.audible
      }
      // Runs outside Angular: digests only this screen, and only when the progress bar or the
      // sound lock changed, instead of the whole UI twice a second.
      const tick = () => {
        if (trackPosition() === scope.position && multimedia.player.audible === scope.audible) return
        refresh()
        if (!scope.$root.$$phase) scope.$digest()
      }

      const unsubscribe = multimedia.subscribe(state => scope.$evalAsync(() => {
        scope.s = { ...state, receivedAt: Date.now() }
        refresh()
      }))
      const unsubscribeCover = multimedia.onCover(cover => scope.$evalAsync(() => {
        scope.coverStyle = coverBackground(cover)
      }))
      const timer = $interval(tick, TICK_MS, 0, false)

      // counts from the shared state, which setVolume updates at once, so fast wheel
      // steps do not start from a value this scope has not seen yet
      const stepVolume = direction => {
        multimedia.setVolume((multimedia.state.phoneVolume || 0) + direction * VOLUME_STEP)
      }
      // the number is on screen only while a phone is connected
      const onWheel = event => {
        if (!multimedia.state.power || !multimedia.state.connected || scope.view === 'settings') return
        event.preventDefault()
        event.stopPropagation()
        stepVolume(event.deltaY < 0 ? 1 : -1)
      }
      element[0].addEventListener('wheel', onWheel, { passive: false })

      scope.t = text
      scope.noNetwork = () => !scope.s.sawNetwork && Date.now() - shownAt > NETWORK_GRACE_MS
      // Lua ships in the same package and lists the running sources whenever it is on
      scope.sources = () => Array.isArray(scope.s.sources) ? scope.s.sources : [] // an empty Lua table arrives as {}
      scope.badgeIcon = () => {
        const sources = scope.sources()
        return sources.length === 1 && SOURCE_ICONS.has(sources[0].id) ? sources[0].id : 'note'
      }
      // a source without its own hint text shows its name
      scope.hint = source => {
        const key = 'hint_' + source.id
        const text = scope.t(key, { name: scope.s.name })
        return text === key ? source.label : text
      }
      scope.volumePercent = () => Math.round((scope.s.phoneVolume || 0) * 100)
      scope.stepVolume = stepVolume
      scope.progressPercent = () => scope.s.duration > 0 ? Math.min(100, 100 * scope.position / scope.s.duration) : 0
      scope.togglePower = () => scope.s.power ? multimedia.powerOff() : multimedia.powerOn()
      scope.control = command => multimedia.control(command)
      scope.minimize = () => scope.onMinimize && scope.onMinimize()

      // the settings panel takes the player's place on the same screen
      scope.view = 'player'
      scope.settings = SETTINGS
      scope.toggleSettings = () => { scope.view = scope.view === 'settings' ? 'player' : 'settings' }
      scope.showPlayer = () => { scope.view = 'player' }
      scope.isOn = key => !!scope.s.options && scope.s.options[key] === true
      scope.toggleOption = key => multimedia.setOption(key, !scope.isOn(key))
      scope.modVolumePercent = () => Math.round((scope.s.carVolume || 0) * 100)
      // from the shared state, like the wheel, so quick presses add up
      scope.stepModVolume = direction => multimedia.setCarVolume((multimedia.state.carVolume || 0) + direction * VOLUME_STEP)
      scope.unlock = () => {
        multimedia.player.unlock()
        setTimeout(() => scope.$evalAsync(refresh), 200)
      }

      scope.$on('$destroy', () => {
        unsubscribe()
        unsubscribeCover()
        element[0].removeEventListener('wheel', onWheel)
        $interval.cancel(timer)
      })
    },
  })])

  // Shown while the player sits in a vehicle, hidden in menus. Remembers its spot and
  // whether it was minimized.
  module.directive('slOverlay', [() => ({
    restrict: 'E',
    replace: true,
    scope: {},
    template: `
<div ng-show="visible()" style="position: fixed; z-index: 50; pointer-events: none;" ng-style="{left: position.x + 'px', top: position.y + 'px'}">
  <div ng-if="!minimized" style="width: ${WIDTH}px; height: ${HEIGHT}px; cursor: grab;">
    <sl-head-unit overlay="true" on-minimize="setMinimized(true)"></sl-head-unit>
  </div>
  <div ng-if="minimized" ng-click="expand()">${PILL}</div>
</div>`,
    link(scope, element) {
      const clamp = point => ({
        x: Math.max(0, Math.min(window.innerWidth - 60, point.x)),
        y: Math.max(0, Math.min(window.innerHeight - 30, point.y)),
      })
      let saved = null
      try { saved = JSON.parse(readStorage('slOverlayPosition') || 'null') } catch (e) { saved = null }
      // bottom centre is the emptiest spot on most HUD layouts
      scope.position = clamp(saved || { x: (window.innerWidth - WIDTH) / 2, y: window.innerHeight - HEIGHT - 22 })
      scope.minimized = readStorage('slOverlayMinimized') === '1'
      scope.s = {}

      const unsubscribe = multimedia.subscribe(state => scope.$evalAsync(() => { scope.s = state }))

      scope.setMinimized = value => {
        scope.minimized = value
        writeStorage('slOverlayMinimized', value ? '1' : '0')
      }
      scope.visible = () => {
        const route = location.hash || ''
        const inMenu = route.startsWith('#/pause') || route.startsWith('#/menu') || route.includes('loading')
        return !!scope.s.inVehicle && !inMenu
      }
      scope.pillText = () => {
        const s = scope.s
        if (s.connected) return (s.title || text('fromPhone')) + (s.artist ? ' — ' + s.artist : '')
        return s.power ? s.name : text('pillOff')
      }

      // dragging; presses on buttons are left alone, and a drag never counts as a click
      let drag = null
      let dragged = false
      const onDown = event => {
        if (event.button !== 0 || event.target.closest('button, .sl-unlock, .sl-settings-list')) return
        drag = { startX: event.clientX, startY: event.clientY, x: scope.position.x, y: scope.position.y }
        dragged = false
      }
      const endDrag = () => {
        if (drag && dragged) writeStorage('slOverlayPosition', JSON.stringify(scope.position))
        drag = null
      }
      const onMove = event => {
        if (!drag) return
        // the button went up where we could not see it (another window, a game menu)
        if (!(event.buttons & PRIMARY_BUTTON)) return endDrag()
        const dx = event.clientX - drag.startX
        const dy = event.clientY - drag.startY
        if (!dragged && Math.abs(dx) + Math.abs(dy) < DRAG_THRESHOLD_PX) return
        dragged = true
        const target = clamp({ x: drag.x + dx, y: drag.y + dy })
        scope.$evalAsync(() => { scope.position = target })
      }
      const onResize = () => scope.$evalAsync(() => { scope.position = clamp(scope.position) })
      element[0].addEventListener('pointerdown', onDown)
      window.addEventListener('pointermove', onMove)
      window.addEventListener('pointerup', endDrag)
      window.addEventListener('pointercancel', endDrag)
      window.addEventListener('resize', onResize)
      scope.expand = () => { if (!dragged) scope.setMinimized(false) }

      scope.$on('$destroy', () => {
        unsubscribe()
        element[0].removeEventListener('pointerdown', onDown)
        window.removeEventListener('pointermove', onMove)
        window.removeEventListener('pointerup', endDrag)
        window.removeEventListener('pointercancel', endDrag)
        window.removeEventListener('resize', onResize)
      })
    },
  })])
}

export { registerHeadUnit, coverBackground, SETTINGS }
