// UI strings. The language follows the game's language setting, English otherwise.

const STRINGS = {
  en: {
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
  },
  ru: {
    headUnit: 'Мультимедиа',
    off: 'Выключена',
    offHint: 'Нажмите кнопку питания',
    connectPhone: 'Подключите телефон',
    hint_airplay: 'iPhone: Пункт управления → AirPlay → «{name}»',
    noNetwork: 'Телефонов не видно: ПК и телефон должны быть в одной Wi-Fi сети, а сеть в Windows — «Частная»',
    noNetworkTip: 'Параметры → Сеть и Интернет → Wi-Fi → ваша сеть → Частная',
    receiverFailed: 'Приёмник не запустился',
    fromPhone: 'Музыка с телефона',
    prev: 'Предыдущий',
    playPause: 'Пауза / играть',
    next: 'Следующий',
    volume: 'Громкость телефона (колёсико мыши)',
    volumeDown: 'Тише',
    volumeUp: 'Громче',
    power: 'Питание',
    minimize: 'Свернуть',
    settings: 'Настройки',
    back: 'Назад',
    fullSoundOutside: 'Музыка снаружи как в салоне',
    modVolume: 'Общая громкость',
    unlock: 'Нажмите, чтобы включить звук',
    pillOff: 'выкл.',
  },
}

function translate(language, key, params) {
  const table = STRINGS[language] || STRINGS.en
  const text = table[key] || STRINGS.en[key] || key
  return params ? text.replace(/\{(\w+)\}/g, (match, name) => params[name] ?? match) : text
}

export { translate }
