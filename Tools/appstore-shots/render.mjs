import { chromium } from 'playwright';
import { pathToFileURL } from 'url';
import { readFileSync, mkdirSync } from 'fs';
import { dirname, resolve } from 'path';

const TEMPLATE = pathToFileURL(resolve('template.html')).href;

export function dataUri(path) {
  return 'data:image/png;base64,' + readFileSync(path).toString('base64');
}

export async function renderOne(browser, job) {
  const { target, shot, locale, kicker, headline } = job;
  const [w, h] = target.canvas;
  const cfg = {
    layout: target.layout, canvasW: w, canvasH: h,
    kicker, headline, shot: dataUri(`input/${target.platform}/${shot}.png`),
  };
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  await page.goto(TEMPLATE, { waitUntil: 'load' });
  await page.evaluate((c) => window.applyConfig(c), cfg);
  await page.waitForFunction(() => {
    const i = document.querySelector('.shot-img');
    return i && i.complete && i.naturalWidth > 0;
  });
  const shrunk = await page.evaluate(() => {
    const zone = document.querySelector('.copyblock');
    const kick = document.querySelector('.kick');
    const h = document.querySelector('.headline-text');
    const cs = getComputedStyle(zone);
    // Verfuegbare Inhaltshoehe der Zone (clientHeight enthaelt Padding).
    const avail = zone.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
    const contentH = () =>
      kick.offsetHeight + parseFloat(getComputedStyle(kick).marginBottom) + h.offsetHeight;
    let size = parseFloat(getComputedStyle(h).fontSize);
    const min = size * 0.55;
    let changed = false, guard = 0;
    // Nur relevant, wo die Zone feste Hoehe hat (Portrait: 22%). TV hat auto-Hoehe -> avail == contentH.
    while (contentH() > avail && size > min && guard < 80) {
      size -= Math.max(1, size * 0.04);
      h.style.fontSize = size + 'px';
      changed = true; guard++;
    }
    return changed;
  });
  const outPath = `out/${locale}/${target.platform}/${shot}.png`;
  mkdirSync(dirname(outPath), { recursive: true });
  const el = await page.$('.canvas');
  await el.screenshot({ path: outPath });
  await page.close();
  return { outPath, shrunk };
}
