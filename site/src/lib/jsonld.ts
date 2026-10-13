import { GITHUB_URL, MIN_MACOS, SITE_DESCRIPTION, SITE_NAME, SITE_URL, abs } from "../config/site";

const ORG_ID = `${SITE_URL}/#organization`;
const SITE_ID = `${SITE_URL}/#website`;
const APP_ID = `${SITE_URL}/#software`;

export const organization = () => ({
  "@type": "Organization",
  "@id": ORG_ID,
  name: SITE_NAME,
  url: `${SITE_URL}/`,
  logo: abs("/icon-512.png"),
  sameAs: [GITHUB_URL],
});

export const website = () => ({
  "@type": "WebSite",
  "@id": SITE_ID,
  name: SITE_NAME,
  url: `${SITE_URL}/`,
  description: SITE_DESCRIPTION,
  publisher: { "@id": ORG_ID },
  inLanguage: "en",
});

export const FEATURES = [
  "Share link copied the moment you stop recording",
  "Update link replaces the video and keeps the URL",
  "Auto-zoom planned from clicks, with a smooth redrawn cursor",
  "Share links point at your own S3-compatible bucket, such as Cloudflare R2",
  "Auto level, on-device voice enhance and ducking of system audio",
  "On-device captions and Cut Long Silences",
  "Crash-safe recording in 2-second segments with live warnings",
  "reelbird command-line tool and MCP server for coding agents",
];

export const softwareApplication = () => ({
  "@type": "SoftwareApplication",
  "@id": APP_ID,
  name: SITE_NAME,
  alternateName: "Reelbird screen recorder",
  description: SITE_DESCRIPTION,
  url: `${SITE_URL}/`,
  downloadUrl: GITHUB_URL,
  installUrl: abs("/download/"),
  applicationCategory: "MultimediaApplication",
  applicationSubCategory: "Screen recorder",
  operatingSystem: `${MIN_MACOS} or later`,
  softwareRequirements: "To build: Command Line Tools for Xcode 26 or later (Swift 6.2, macOS 26 SDK), on macOS 15.6 or later",
  license: "https://opensource.org/licenses/MIT",
  isAccessibleForFree: true,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  featureList: FEATURES,
  screenshot: abs("/og/home.png"),
  image: abs("/icon-512.png"),
  author: { "@id": ORG_ID },
  publisher: { "@id": ORG_ID },
  sameAs: [GITHUB_URL],
});

export const softwareSourceCode = () => ({
  "@type": "SoftwareSourceCode",
  "@id": `${SITE_URL}/#source`,
  name: `${SITE_NAME} source code`,
  codeRepository: GITHUB_URL,
  programmingLanguage: "Swift",
  runtimePlatform: `${MIN_MACOS} or later`,
  license: "https://opensource.org/licenses/MIT",
  targetProduct: { "@id": APP_ID },
  author: { "@id": ORG_ID },
});

export const techArticle = (o: { title: string; description: string; path: string; dateModified: string }) => ({
  "@type": "TechArticle",
  headline: o.title,
  description: o.description,
  url: abs(o.path),
  dateModified: o.dateModified,
  inLanguage: "en",
  about: { "@id": APP_ID },
  publisher: { "@id": ORG_ID },
});

export const article = (o: { title: string; description: string; path: string; datePublished: string; dateModified?: string }) => ({
  "@type": "Article",
  headline: o.title,
  description: o.description,
  url: abs(o.path),
  datePublished: o.datePublished,
  dateModified: o.dateModified ?? o.datePublished,
  inLanguage: "en",
  about: { "@id": APP_ID },
  author: { "@id": ORG_ID },
  publisher: { "@id": ORG_ID },
  image: abs("/og/home.png"),
});

export const faqPage = (items: { q: string; a: string }[]) => ({
  "@type": "FAQPage",
  mainEntity: items.map(({ q, a }) => ({
    "@type": "Question",
    name: q,
    acceptedAnswer: { "@type": "Answer", text: a },
  })),
});

export const breadcrumbs = (trail: { name: string; path: string }[]) => ({
  "@type": "BreadcrumbList",
  itemListElement: trail.map((t, i) => ({ "@type": "ListItem", position: i + 1, name: t.name, item: abs(t.path) })),
});

export const graph = (...nodes: object[]) => ({ "@context": "https://schema.org", "@graph": nodes });
