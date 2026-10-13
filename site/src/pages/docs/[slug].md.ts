// Markdown twins of the docs pages (/docs/mcp.md) for agents and LLM tools.
import type { APIRoute, GetStaticPaths } from "astro";
import { getCollection, type CollectionEntry } from "astro:content";
import { SITE_URL } from "../../config/site";

export const getStaticPaths: GetStaticPaths = async () => {
  const docs = await getCollection("docs");
  return docs.map((entry) => ({ params: { slug: entry.id }, props: { entry } }));
};

export const GET: APIRoute = ({ props }) => {
  const { entry } = props as { entry: CollectionEntry<"docs"> };
  const body = (entry.body ?? "").replace(/<!--[\s\S]*?-->\n*/g, "").replace(/\]\(\//g, `](${SITE_URL}/`);
  const md = `# ${entry.data.title}\n\n> ${entry.data.description}\n\nSource: ${SITE_URL}/docs/${entry.id}/\n\n${body.trim()}\n`;
  return new Response(md, { headers: { "Content-Type": "text/markdown; charset=utf-8" } });
};
