/**
 * App Store スクリーンショット生成スクリプト
 *
 * HTMLテンプレートから各スクリーンショットを個別にPNG画像として切り出す。
 * 各要素を1つずつ表示し、ビューポートサイズを正確に合わせて撮影する。
 */

const { chromium } = require('playwright');
const path = require('path');

const SCREENSHOTS = [
  { id: 'iphone-01', filename: 'iphone_01_home.png', width: 1284, height: 2778 },
  { id: 'iphone-02', filename: 'iphone_02_gallery.png', width: 1284, height: 2778 },
  { id: 'iphone-03', filename: 'iphone_03_edit.png', width: 1284, height: 2778 },
  { id: 'iphone-04', filename: 'iphone_04_postinfo.png', width: 1284, height: 2778 },
  { id: 'iphone-05', filename: 'iphone_05_search.png', width: 1284, height: 2778 },
  { id: 'iphone-06', filename: 'iphone_06_profile.png', width: 1284, height: 2778 },
  { id: 'ipad-01', filename: 'ipad_01_home.png', width: 2048, height: 2732 },
  { id: 'ipad-02', filename: 'ipad_02_gallery.png', width: 2048, height: 2732 },
  { id: 'ipad-03', filename: 'ipad_03_edit.png', width: 2048, height: 2732 },
  { id: 'ipad-04', filename: 'ipad_04_postinfo.png', width: 2048, height: 2732 },
  { id: 'ipad-05', filename: 'ipad_05_search.png', width: 2048, height: 2732 },
  { id: 'ipad-06', filename: 'ipad_06_profile.png', width: 2048, height: 2732 },
];

async function generateScreenshots() {
  const browser = await chromium.launch();
  const templatePath = path.resolve(__dirname, 'screenshot_template.html');
  const outputDir = path.resolve(__dirname, '../appstore');

  const fs = require('fs');
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  for (const ss of SCREENSHOTS) {
    console.log(`Generating ${ss.filename}...`);

    const context = await browser.newContext({
      viewport: { width: ss.width, height: ss.height },
      deviceScaleFactor: 1,
    });
    const page = await context.newPage();

    await page.goto(`file://${templatePath}`, { waitUntil: 'networkidle' });

    // 全要素を非表示にし、対象のみ表示、bodyのpadding/gap除去
    await page.evaluate((targetId) => {
      document.body.style.padding = '0';
      document.body.style.margin = '0';
      document.body.style.gap = '0';
      document.body.style.display = 'block';
      document.body.style.background = 'transparent';

      const allScreenshots = document.querySelectorAll('.screenshot');
      allScreenshots.forEach(el => {
        el.style.display = 'none';
      });

      const target = document.getElementById(targetId);
      if (target) {
        target.style.display = 'block';
      }
    }, ss.id);

    // ページ全体のスクリーンショットを撮影（ビューポートサイズで正確にクリッピング）
    await page.screenshot({
      path: path.join(outputDir, ss.filename),
      type: 'png',
      clip: { x: 0, y: 0, width: ss.width, height: ss.height },
    });

    await context.close();
    console.log(`  -> Saved to appstore/${ss.filename} (${ss.width}x${ss.height})`);
  }

  await browser.close();
  console.log('\nAll screenshots generated successfully!');
}

generateScreenshots().catch(console.error);
