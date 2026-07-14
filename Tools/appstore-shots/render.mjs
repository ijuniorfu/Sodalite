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
  const outPath = `out/${locale}/${target.platform}/${shot}.png`;
  mkdirSync(dirname(outPath), { recursive: true });
  const el = await page.$('.canvas');
  await el.screenshot({ path: outPath });
  await page.close();
  return outPath;
}
