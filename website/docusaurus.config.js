// @ts-check
/* eslint-env node */

const { themes } = require("prism-react-renderer");

const repositoryUrl = "https://github.com/avala-ai/4dgs";

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "4dgs",
  tagline: "An open container format for 4D gaussian splat scenes",
  favicon: "img/favicon.svg",

  // GitHub Pages serves this project site from a subpath of the organization domain.
  url: "https://4dgs.dev",
  baseUrl: "/",

  // The docs cross-reference each other with relative paths, and a link that no longer
  // resolves is a documentation bug rather than a cosmetic one — fail the build on it.
  onBrokenLinks: "throw",
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: "throw",
    },
  },

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          path: "docs",
          routeBasePath: "docs",
          sidebarPath: "./sidebars.js",
          editUrl: `${repositoryUrl}/tree/main/website/`,
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
        // No analytics: the site collects nothing and loads nothing from a third party.
        gtag: undefined,
        googleTagManager: undefined,
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      navbar: {
        title: "4dgs",
        logo: {
          alt: "4dgs",
          src: "img/logo.svg",
        },
        items: [
          {
            type: "docSidebar",
            sidebarId: "guidesSidebar",
            position: "left",
            label: "Guides",
          },
          {
            type: "docSidebar",
            sidebarId: "specSidebar",
            position: "left",
            label: "Specification",
          },
          {
            type: "docSidebar",
            sidebarId: "referenceSidebar",
            position: "left",
            label: "Reference",
          },
          {
            href: repositoryUrl,
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Documentation",
            items: [
              { label: "Guides", to: "/docs/guides/" },
              { label: "Specification", to: "/docs/spec/" },
              { label: "Feature support matrix", to: "/docs/reference/" },
              { label: "Conformance suite", to: "/docs/reference/conformance" },
            ],
          },
          {
            title: "Source",
            items: [
              { label: "Repository", href: repositoryUrl },
              { label: "Releases", href: `${repositoryUrl}/releases` },
              {
                label: "Contributing",
                href: `${repositoryUrl}/blob/main/CONTRIBUTING.md`,
              },
              {
                label: "License",
                href: `${repositoryUrl}/blob/main/LICENSE`,
              },
            ],
          },
        ],
        copyright: "The 4dgs format specification and SDKs are licensed under Apache-2.0.",
      },
      prism: {
        theme: themes.github,
        darkTheme: themes.dracula,
        additionalLanguages: ["rust", "swift", "cpp", "bash", "json"],
      },
      colorMode: {
        respectPrefersColorScheme: true,
      },
    }),
};

module.exports = config;
