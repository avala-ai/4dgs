# Website

The documentation site, published to <https://avala-ai.github.io/4dgs/> by
[`.github/workflows/website.yml`](../.github/workflows/website.yml) on every push to `main` that
touches `website/`.

`docs/` is the documentation itself, and it is not site-only: the repository README, the per-package
READMEs and the conformance suite all link into it with relative paths, and it reads correctly on
GitHub without the site. Treat it as markdown that happens to be rendered, not as site content — in
particular, `docs/spec/` is the normative specification.

## Running it

This directory is a workspace of the root `package.json`, so install from the repository root:

```sh
corepack enable
yarn install
yarn workspace website start   # http://localhost:3000/4dgs/
yarn workspace website build   # static output in website/build/, which is not committed
```

The build fails on a broken internal link rather than publishing one, so a renamed or moved page
must be fixed everywhere it is referenced.

## Conventions

- **Navigation lives in `sidebars.js`**, listed explicitly. Ordering and sidebar labels are set
  there so the documents themselves stay plain markdown with no front matter.
- **Nothing is loaded from a third party** — no analytics, no fonts, no scripts, no images from
  anywhere but `static/`. The site works offline and behind a proxy.
- **Light and dark are both supported** and follow the reader's system preference by default.
