/*
 * scan2nas – Anpassungen für die Weboberfläche scanservjs
 *
 * Wird bei der Installation nach /etc/scanservjs/config.local.js kopiert.
 * Nach Änderungen:  systemctl restart scanservjs
 *
 * Was passiert hier?
 *  - Nach JEDEM Scan in der Weboberfläche wird die Datei mit
 *    "scan2nas uebernehmen" aufs NAS kopiert (oder in die Warteschlange,
 *    falls das NAS gerade nicht erreichbar ist).
 *  - Die lokale Kopie bleibt für Vorschau/Download im Browser erhalten und
 *    wird vom Hintergrunddienst nach WEB_AUFBEWAHRUNG_TAGE gelöscht.
 *  - Sinnvolle Standardwerte: 300 dpi, Farbe, deutsche Texterkennung.
 */
const { execFile } = require('child_process');

const SCAN2NAS = '/usr/local/bin/scan2nas';

/**
 * Übergibt eine Datei an scan2nas. execFile statt Shell: Dateinamen mit
 * Leerzeichen oder Sonderzeichen sind so kein Problem.
 * @param {string} datei
 * @returns {Promise<void>}
 */
function aufsNasKopieren(datei) {
  return new Promise((resolve) => {
    execFile(SCAN2NAS, ['uebernehmen', datei], { timeout: 10 * 60 * 1000 }, (fehler, stdout, stderr) => {
      if (fehler) {
        console.error(`[scan2nas] Übernahme fehlgeschlagen für ${datei}: ${(stderr || fehler.message).trim()}`);
      } else {
        console.log(`[scan2nas] ${(stderr || '').trim() || `übernommen: ${datei}`}`);
      }
      // Fehler brechen den Scan in der Weboberfläche bewusst nicht ab –
      // die Datei bleibt lokal erhalten und kann über die Aktion unten
      // erneut aufs NAS kopiert werden.
      resolve();
    });
  });
}

module.exports = {
  /**
   * @param {Configuration} config
   */
  afterConfig(config) {
    // Sprache der Texterkennung (Pipeline "PDF mit OCR")
    config.ocrLanguage = 'deu';
  },

  /**
   * Standardwerte für den Scanner setzen (nur wenn das Gerät sie anbietet).
   * @param {ScanDevice[]} devices
   */
  afterDevices(devices) {
    devices.forEach((device) => {
      const merkmale = device.features;
      const aufloesung = merkmale['--resolution'];
      if (aufloesung && Array.isArray(aufloesung.options) && aufloesung.options.includes(300)) {
        aufloesung.default = 300;
      }
      const modus = merkmale['--mode'];
      if (modus && Array.isArray(modus.options) && modus.options.includes('Color')) {
        modus.default = 'Color';
      }
    });
  },

  /**
   * Wird nach jedem fertigen Scan aufgerufen.
   * @param {FileInfo} fileInfo
   */
  async afterScan(fileInfo) {
    await aufsNasKopieren(fileInfo.fullname);
  },

  /**
   * Zusätzliche Aktion im Reiter "Dateien" der Weboberfläche.
   * @type {Action[]}
   */
  actions: [
    {
      name: 'Nochmal aufs NAS kopieren',
      async execute(fileInfo) {
        await aufsNasKopieren(fileInfo.fullname);
      }
    }
  ]
};
