import { createRootRoute, HeadContent, Outlet, Scripts } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { Footer } from "../components/Footer";
import { Header } from "../components/Header";
import { NotFound } from "../components/NotFound";
import { links, notFound, site } from "../content";
import fontUrl from "../fonts/newsreader.woff2?url";
import stylesUrl from "../styles/global.css?url";

const socialImage = new URL("og.png", links.site).href;

export const Route = createRootRoute({
  head: ({ matches }) => {
    // The 404 page: prerendered from /404, and shown wherever nothing but the root matches.
    const missing = matches.length < 2 || matches.some((match) => match.pathname === "/404");
    const title = missing ? `${notFound.title} · ${site.name}` : site.title;
    return {
      meta: [
        { charSet: "utf-8" },
        { name: "viewport", content: "width=device-width, initial-scale=1" },
        { title },
        { name: "description", content: site.description },
        ...(missing ? [{ name: "robots", content: "noindex" }] : []),
        { name: "theme-color", content: "#ffffff", media: "(prefers-color-scheme: light)" },
        { name: "theme-color", content: "#0d0d0d", media: "(prefers-color-scheme: dark)" },
        { property: "og:type", content: "website" },
        { property: "og:site_name", content: site.name },
        { property: "og:title", content: title },
        { property: "og:description", content: site.description },
        { property: "og:url", content: links.site },
        { property: "og:image", content: socialImage },
        { property: "og:image:width", content: "1200" },
        { property: "og:image:height", content: "630" },
        { property: "og:image:alt", content: site.socialImageAlt },
        { name: "twitter:card", content: "summary_large_image" },
        { name: "twitter:title", content: title },
        { name: "twitter:description", content: site.description },
        { name: "twitter:image", content: socialImage },
        { name: "twitter:image:alt", content: site.socialImageAlt },
      ],
      links: [
        ...(missing ? [] : [{ rel: "canonical", href: links.site }]),
        { rel: "preload", href: fontUrl, as: "font", type: "font/woff2", crossOrigin: "anonymous" },
        { rel: "stylesheet", href: stylesUrl },
        { rel: "icon", href: "/favicon.ico", sizes: "32x32" },
        { rel: "icon", href: "/icon.png", type: "image/png", sizes: "192x192" },
        { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
      ],
    };
  },
  shellComponent: Document,
  component: Layout,
  notFoundComponent: () => (
    <Layout>
      <NotFound />
    </Layout>
  ),
});

/** The HTML document around every page. */
function Document({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body className="min-h-dvh">
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function Layout({ children = <Outlet /> }: { children?: ReactNode }) {
  return (
    <>
      <a href="#main" className="button sr-only h-10 px-4 focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-20">
        Skip to the content
      </a>
      <Header />
      {children}
      <Footer />
    </>
  );
}
