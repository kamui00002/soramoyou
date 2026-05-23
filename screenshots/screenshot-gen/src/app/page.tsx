"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { toPng } from "html-to-image";

// ─── Constants ───────────────────────────────────────────
const IPHONE_W = 1320;
const IPHONE_H = 2868;

const IPHONE_SIZES = [
  { label: '6.9"', w: 1320, h: 2868 },
  { label: '6.5"', w: 1284, h: 2778 },
  { label: '6.3"', w: 1206, h: 2622 },
  { label: '6.1"', w: 1125, h: 2436 },
] as const;

// Mockup measurements
const MK_W = 1022;
const MK_H = 2082;
const SC_L = (52 / MK_W) * 100;
const SC_T = (46 / MK_H) * 100;
const SC_W = (918 / MK_W) * 100;
const SC_H = (1990 / MK_H) * 100;
const SC_RX = (126 / 918) * 100;
const SC_RY = (126 / 1990) * 100;

// ─── Image preloading ────────────────────────────────────
const IMAGE_PATHS = [
  "/mockup.png",
  "/app-icon.png",
  "/screenshots/home.png",
  "/screenshots/gallery.png",
  "/screenshots/edit.png",
  "/screenshots/postinfo.png",
  "/screenshots/search.png",
  "/screenshots/profile.png",
];

const imageCache: Record<string, string> = {};

async function preloadAllImages() {
  await Promise.all(
    IMAGE_PATHS.map(async (path) => {
      const resp = await fetch(path);
      const blob = await resp.blob();
      const dataUrl = await new Promise<string>((resolve) => {
        const reader = new FileReader();
        reader.onloadend = () => resolve(reader.result as string);
        reader.readAsDataURL(blob);
      });
      imageCache[path] = dataUrl;
    })
  );
}

function img(path: string): string {
  return imageCache[path] || path;
}

// ─── Components ──────────────────────────────────────────

function Phone({
  src,
  alt,
  style,
  className = "",
}: {
  src: string;
  alt: string;
  style?: React.CSSProperties;
  className?: string;
}) {
  return (
    <div
      className={`relative ${className}`}
      style={{ aspectRatio: `${MK_W}/${MK_H}`, ...style }}
    >
      <img
        src={img("/mockup.png")}
        alt=""
        className="block w-full h-full"
        draggable={false}
      />
      <div
        className="absolute z-10 overflow-hidden"
        style={{
          left: `${SC_L}%`,
          top: `${SC_T}%`,
          width: `${SC_W}%`,
          height: `${SC_H}%`,
          borderRadius: `${SC_RX}% / ${SC_RY}%`,
        }}
      >
        <img
          src={src}
          alt={alt}
          className="block w-full h-full object-cover object-top"
          draggable={false}
        />
      </div>
    </div>
  );
}

// Headline with line breaks rendered as separate divs
function HeadlineText({
  text,
  fontSize,
  color,
  shadow,
}: {
  text: string;
  fontSize: number;
  color: string;
  shadow: string;
}) {
  const lines = text.split("\n");
  return (
    <div>
      {lines.map((line, i) => (
        <div
          key={i}
          style={{
            fontSize,
            fontWeight: 700,
            lineHeight: 1.15,
            color,
            textShadow: shadow,
          }}
        >
          {line}
        </div>
      ))}
    </div>
  );
}

function Caption({
  label,
  headline,
  canvasW,
  color = "#fff",
  align = "center",
}: {
  label?: string;
  headline: string;
  canvasW: number;
  color?: string;
  align?: "center" | "left";
}) {
  const shadow =
    color === "#fff"
      ? "0 2px 20px rgba(0,0,0,0.15)"
      : "0 2px 20px rgba(255,255,255,0.3)";
  return (
    <div
      style={{
        textAlign: align,
        padding: `0 ${canvasW * 0.06}px`,
      }}
    >
      {label && (
        <div
          style={{
            fontSize: canvasW * 0.032,
            fontWeight: 500,
            color:
              color === "#fff"
                ? "rgba(255,255,255,0.75)"
                : "rgba(0,0,0,0.5)",
            marginBottom: canvasW * 0.015,
            letterSpacing: "0.05em",
          }}
        >
          {label}
        </div>
      )}
      <HeadlineText
        text={headline}
        fontSize={canvasW * 0.09}
        color={color}
        shadow={shadow}
      />
    </div>
  );
}

// ─── Decorative Elements ─────────────────────────────────

function CloudBlob({ style }: { style: React.CSSProperties }) {
  return (
    <div
      style={{
        position: "absolute",
        borderRadius: "50%",
        background: "rgba(255,255,255,0.12)",
        filter: "blur(60px)",
        ...style,
      }}
    />
  );
}

function SunGlow({ style }: { style: React.CSSProperties }) {
  return (
    <div
      style={{
        position: "absolute",
        borderRadius: "50%",
        background:
          "radial-gradient(circle, rgba(255,200,100,0.3) 0%, rgba(255,150,50,0.1) 50%, transparent 70%)",
        ...style,
      }}
    />
  );
}

// ─── Slide Components ────────────────────────────────────

// Slide 1: Hero — 電話なし、アイコン＋キャッチコピー (C案採用、個人情報露出回避)
function Slide1() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(180deg, #1a4a8a 0%, #2d7dd2 25%, #5ba8e8 50%, #a8d8f0 72%, #e8f4fd 100%)",
      }}
    >
      {/* 雲装飾 */}
      <CloudBlob style={{ top: "8%", left: "-12%", width: 600, height: 350 }} />
      <CloudBlob style={{ top: "5%", right: "-8%", width: 500, height: 300 }} />
      <CloudBlob style={{ top: "38%", left: "-5%", width: 400, height: 250 }} />
      <CloudBlob style={{ top: "42%", right: "-10%", width: 450, height: 280 }} />
      <SunGlow
        style={{
          top: "10%",
          left: "50%",
          transform: "translateX(-50%)",
          width: 800,
          height: 800,
        }}
      />

      {/* ヘッドライン — 上部 */}
      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"今日の空、\nみんなの空"}
          label="そらもよう"
          color="#fff"
        />
      </div>

      {/* App Icon — 大きく中央 */}
      <div
        style={{
          position: "absolute",
          top: IPHONE_H * 0.32,
          left: "50%",
          transform: "translateX(-50%)",
          width: IPHONE_W * 0.52,
          height: IPHONE_W * 0.52,
          borderRadius: IPHONE_W * 0.115,
          overflow: "hidden",
          boxShadow:
            "0 24px 100px rgba(0,0,0,0.3), 0 0 0 8px rgba(255,255,255,0.25)",
        }}
      >
        <img
          src={img("/app-icon.png")}
          alt="そらもよう"
          style={{ width: "100%", height: "100%", objectFit: "cover" }}
        />
      </div>

      {/* サブテキスト */}
      <div
        style={{
          position: "absolute",
          top: IPHONE_H * 0.76,
          width: "100%",
          textAlign: "center",
          padding: `0 ${IPHONE_W * 0.1}px`,
        }}
      >
        <div
          style={{
            fontSize: IPHONE_W * 0.058,
            color: "rgba(255,255,255,0.8)",
            lineHeight: 1.6,
            fontWeight: 400,
          }}
        >
          空の写真を撮って、編集して、
          <br />
          みんなとシェアしよう
        </div>
      </div>
    </div>
  );
}

// Slide 2: Gallery — Deep blue gradient, phone offset right
function Slide2() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(160deg, #1a3a5c 0%, #2d6a9f 40%, #5b9fd4 70%, #a8d4e6 100%)",
      }}
    >
      <CloudBlob
        style={{ bottom: "20%", right: "-15%", width: 600, height: 400 }}
      />
      <CloudBlob
        style={{ top: "10%", left: "-8%", width: 350, height: 250 }}
      />

      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"空のコレクションを\n作ろう"}
          label="ギャラリー"
        />
      </div>

      <Phone
        src={img("/screenshots/gallery.png")}
        alt="Gallery"
        style={{
          position: "absolute",
          bottom: 0,
          right: "-4%",
          transform: "translateY(10%)",
          width: "82%",
        }}
      />
    </div>
  );
}

// Slide 3: Edit — Contrast slide with sunset gradient
function Slide3() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(180deg, #2d1b4e 0%, #8b3a62 30%, #e07050 60%, #f5b870 90%, #fde8c8 100%)",
      }}
    >
      <SunGlow
        style={{
          bottom: "30%",
          left: "50%",
          transform: "translateX(-50%)",
          width: 800,
          height: 800,
        }}
      />
      <CloudBlob
        style={{
          top: "5%",
          right: "-10%",
          width: 400,
          height: 300,
          background: "rgba(255,100,150,0.1)",
        }}
      />

      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"27のツールで\n空を彩る"}
          label="フィルター & 編集"
          color="#fff"
        />
      </div>

      <Phone
        src={img("/screenshots/edit.png")}
        alt="Edit"
        style={{
          position: "absolute",
          bottom: 0,
          left: "50%",
          transform: "translateX(-50%) translateY(14%)",
          width: "86%",
        }}
      />
    </div>
  );
}

// Slide 4: Post Info — Warm sunset-to-purple gradient, phone offset left
function Slide4() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(180deg, #f8a430 0%, #f07030 35%, #d04080 65%, #6030a0 100%)",
      }}
    >
      <CloudBlob
        style={{
          top: "15%",
          left: "-10%",
          width: 500,
          height: 350,
          background: "rgba(255,255,255,0.08)",
        }}
      />
      <SunGlow
        style={{ top: "-10%", right: "-10%", width: 500, height: 500 }}
      />

      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"空の色・時間帯を\n自動で分析"}
          label="スマート投稿"
        />
      </div>

      <Phone
        src={img("/screenshots/postinfo.png")}
        alt="Post Info"
        style={{
          position: "absolute",
          bottom: 0,
          left: "-2%",
          transform: "translateY(10%)",
          width: "82%",
        }}
      />
    </div>
  );
}

// Slide 5: Search — Light blue, two phones layered
function Slide5() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(180deg, #e8f4fd 0%, #a8d8ea 30%, #60a5d4 60%, #3d7ab8 100%)",
      }}
    >
      <CloudBlob
        style={{ top: "8%", right: "-5%", width: 400, height: 280 }}
      />
      <CloudBlob
        style={{
          bottom: "25%",
          left: "-8%",
          width: 350,
          height: 250,
          background: "rgba(255,255,255,0.18)",
        }}
      />

      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"色や時間帯で\n空を探そう"}
          label="検索"
          color="#1a3a5c"
        />
      </div>

      <Phone
        src={img("/screenshots/home.png")}
        alt="Home (back)"
        style={{
          position: "absolute",
          bottom: 0,
          left: "-8%",
          width: "65%",
          transform: "translateY(8%) rotate(-4deg)",
          opacity: 0.45,
        }}
      />
      <Phone
        src={img("/screenshots/search.png")}
        alt="Search"
        style={{
          position: "absolute",
          bottom: 0,
          right: "-4%",
          width: "82%",
          transform: "translateY(10%)",
        }}
      />
    </div>
  );
}

// Slide 6: Profile — Night-to-day gradient closing slide
function Slide6() {
  return (
    <div
      style={{
        width: IPHONE_W,
        height: IPHONE_H,
        position: "relative",
        overflow: "hidden",
        background:
          "linear-gradient(180deg, #0c1a3a 0%, #1a3a6e 30%, #3a6ea8 55%, #7ab8e0 80%, #c8e8f8 100%)",
      }}
    >
      <CloudBlob
        style={{
          top: "3%",
          left: "20%",
          width: 500,
          height: 300,
          background: "rgba(120,180,255,0.1)",
        }}
      />
      <SunGlow
        style={{ bottom: "40%", right: "-5%", width: 400, height: 400 }}
      />

      <div
        style={{ position: "absolute", top: IPHONE_H * 0.06, width: "100%" }}
      >
        <Caption
          canvasW={IPHONE_W}
          headline={"あなただけの\n空ギャラリー"}
          label="プロフィール"
        />
      </div>

      {/* App icon + tagline at bottom */}
      <div
        style={{
          position: "absolute",
          bottom: IPHONE_H * 0.04,
          left: "50%",
          transform: "translateX(-50%)",
          textAlign: "center",
          zIndex: 20,
        }}
      >
        <div
          style={{
            width: IPHONE_W * 0.1,
            height: IPHONE_W * 0.1,
            borderRadius: IPHONE_W * 0.022,
            overflow: "hidden",
            margin: "0 auto",
            marginBottom: 16,
            boxShadow: "0 4px 20px rgba(0,0,0,0.3)",
          }}
        >
          <img
            src={img("/app-icon.png")}
            alt=""
            style={{ width: "100%", height: "100%", objectFit: "cover" }}
          />
        </div>
        <div
          style={{
            fontSize: IPHONE_W * 0.035,
            fontWeight: 500,
            color: "rgba(255,255,255,0.8)",
          }}
        >
          そらもよう — 空の写真SNS
        </div>
      </div>

      <Phone
        src={img("/screenshots/profile.png")}
        alt="Profile"
        style={{
          position: "absolute",
          bottom: IPHONE_H * 0.1,
          left: "50%",
          transform: "translateX(-50%) translateY(12%)",
          width: "82%",
        }}
      />
    </div>
  );
}

// ─── Slide Registry ──────────────────────────────────────

const SLIDES = [
  { id: "hero", label: "ヒーロー", component: Slide1 },
  { id: "gallery", label: "ギャラリー", component: Slide2 },
  { id: "edit", label: "編集", component: Slide3 },
  { id: "postinfo", label: "投稿分析", component: Slide4 },
  { id: "search", label: "検索", component: Slide5 },
  { id: "profile", label: "プロフィール", component: Slide6 },
];

// ─── Preview + Export ────────────────────────────────────

function ScreenshotPreview({
  slide,
  index,
  sizeIdx,
  onExport,
}: {
  slide: (typeof SLIDES)[number];
  index: number;
  sizeIdx: number;
  onExport: (el: HTMLDivElement, name: string) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const slideRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(0.2);

  useEffect(() => {
    if (!containerRef.current) return;
    const obs = new ResizeObserver(([entry]) => {
      const cw = entry.contentRect.width;
      setScale(cw / IPHONE_W);
    });
    obs.observe(containerRef.current);
    return () => obs.disconnect();
  }, []);

  const SlideComponent = slide.component;

  return (
    <div className="flex flex-col items-center gap-2">
      <div
        ref={containerRef}
        className="w-full relative overflow-hidden rounded-xl border border-gray-200 bg-gray-50 cursor-pointer hover:ring-2 hover:ring-blue-400 transition-all"
        style={{ aspectRatio: `${IPHONE_W}/${IPHONE_H}` }}
        onClick={() => {
          if (slideRef.current) {
            onExport(
              slideRef.current,
              `${String(index + 1).padStart(2, "0")}-${slide.id}`
            );
          }
        }}
      >
        <div
          ref={slideRef}
          style={{
            transform: `scale(${scale})`,
            transformOrigin: "top left",
            width: IPHONE_W,
            height: IPHONE_H,
          }}
        >
          <SlideComponent />
        </div>
      </div>
      <span className="text-xs text-gray-500 font-medium">
        {slide.label} (クリックでエクスポート)
      </span>
    </div>
  );
}

// ─── Main Page ───────────────────────────────────────────

export default function ScreenshotsPage() {
  const [ready, setReady] = useState(false);
  const [sizeIdx, setSizeIdx] = useState(0);
  const [exporting, setExporting] = useState(false);
  const [exportLog, setExportLog] = useState<string[]>([]);

  useEffect(() => {
    preloadAllImages().then(() => setReady(true));
  }, []);

  const exportSlide = useCallback(
    async (el: HTMLDivElement, name: string) => {
      const size = IPHONE_SIZES[sizeIdx];
      setExporting(true);
      setExportLog((l) => [...l, `Exporting ${name}...`]);

      el.style.position = "fixed";
      el.style.left = "0px";
      el.style.top = "0px";
      el.style.zIndex = "-1";
      el.style.transform = "none";

      // 画面は IPHONE_W × IPHONE_H で描画し、出力キャンバス側で size.w × size.h に
      // 合わせる。pixelRatio だけで均一スケールすると IPHONE_H:IPHONE_W と
      // size.h:size.w の比率差で 1〜10px 程度の高さズレが発生し、
      // App Store Connect の画像サイズ検証に弾かれる（例: 1284×2789 ≠ 1284×2778）。
      const opts = {
        width: IPHONE_W,
        height: IPHONE_H,
        canvasWidth: size.w,
        canvasHeight: size.h,
        cacheBust: true,
      };

      try {
        await toPng(el, opts);
        const dataUrl = await toPng(el, opts);

        const link = document.createElement("a");
        link.download = `${name}-${size.w}x${size.h}.png`;
        link.href = dataUrl;
        link.click();
        setExportLog((l) => [...l, `✓ ${name} exported`]);
      } catch (err) {
        setExportLog((l) => [...l, `✗ ${name} failed: ${err}`]);
      } finally {
        el.style.position = "";
        el.style.left = "";
        el.style.top = "";
        el.style.zIndex = "";
        el.style.transform = "";
        setExporting(false);
      }
    },
    [sizeIdx]
  );

  const exportAll = useCallback(async () => {
    setExporting(true);
    setExportLog(["Exporting all slides..."]);

    const cards =
      document.querySelectorAll<HTMLDivElement>("[data-slide-export]");
    for (let i = 0; i < cards.length; i++) {
      const el = cards[i];
      const name = `${String(i + 1).padStart(2, "0")}-${SLIDES[i].id}`;
      const size = IPHONE_SIZES[sizeIdx];

      el.style.position = "fixed";
      el.style.left = "0px";
      el.style.top = "0px";
      el.style.zIndex = "-1";
      el.style.transform = "none";

      // 単体書き出しと同様、出力キャンバスで target size に合わせる。
      const opts = {
        width: IPHONE_W,
        height: IPHONE_H,
        canvasWidth: size.w,
        canvasHeight: size.h,
        cacheBust: true,
      };

      try {
        await toPng(el, opts);
        const dataUrl = await toPng(el, opts);
        const link = document.createElement("a");
        link.download = `${name}-${size.w}x${size.h}.png`;
        link.href = dataUrl;
        link.click();
        setExportLog((l) => [...l, `✓ ${name}`]);
      } catch (err) {
        setExportLog((l) => [...l, `✗ ${name}: ${err}`]);
      } finally {
        el.style.position = "";
        el.style.left = "";
        el.style.top = "";
        el.style.zIndex = "";
        el.style.transform = "";
      }

      await new Promise((r) => setTimeout(r, 300));
    }
    setExporting(false);
  }, [sizeIdx]);

  if (!ready) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-b from-sky-100 to-white">
        <p className="text-lg text-gray-500">画像を読み込み中...</p>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gradient-to-b from-sky-50 to-white">
      {/* Toolbar */}
      <div className="sticky top-0 z-50 bg-white/80 backdrop-blur-md border-b border-gray-200 p-4">
        <div className="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3">
          <h1 className="text-xl font-bold text-gray-800">
            そらもよう — スクリーンショット
          </h1>

          <div className="flex items-center gap-3">
            <select
              value={sizeIdx}
              onChange={(e) => setSizeIdx(Number(e.target.value))}
              className="px-3 py-1.5 rounded-lg border border-gray-300 text-sm bg-white"
            >
              {IPHONE_SIZES.map((s, i) => (
                <option key={i} value={i}>
                  iPhone {s.label} ({s.w}x{s.h})
                </option>
              ))}
            </select>

            <button
              onClick={exportAll}
              disabled={exporting}
              className="px-4 py-1.5 rounded-lg bg-blue-500 text-white text-sm font-medium hover:bg-blue-600 disabled:bg-gray-400 transition-colors"
            >
              {exporting ? "エクスポート中..." : "全てエクスポート"}
            </button>
          </div>
        </div>
      </div>

      {/* Preview Grid */}
      <div className="max-w-7xl mx-auto p-6">
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
          {SLIDES.map((slide, i) => (
            <ScreenshotPreview
              key={slide.id}
              slide={slide}
              index={i}
              sizeIdx={sizeIdx}
              onExport={exportSlide}
            />
          ))}
        </div>
      </div>

      {/* Offscreen render for export */}
      <div style={{ position: "absolute", left: -9999, top: 0, opacity: 0 }}>
        {SLIDES.map((slide) => {
          const SlideComponent = slide.component;
          return (
            <div
              key={slide.id}
              data-slide-export
              style={{ width: IPHONE_W, height: IPHONE_H }}
            >
              <SlideComponent />
            </div>
          );
        })}
      </div>

      {/* Export log */}
      {exportLog.length > 0 && (
        <div className="fixed bottom-4 right-4 bg-gray-900/90 text-white rounded-lg p-4 max-w-xs text-xs space-y-1 backdrop-blur">
          {exportLog.slice(-6).map((log, i) => (
            <div key={i}>{log}</div>
          ))}
        </div>
      )}
    </div>
  );
}
