# Security Policy

## Supported versions

Lithium has no numbered releases yet. Fixes land on `main`, and the latest `main` is the only supported version.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Report it privately with a [GitHub security advisory](https://github.com/DailyXplorer/Lithium/security/advisories/new). Please include:

- a clear description of the vulnerability;
- the steps to reproduce it, with a page or a file that shows it when you can;
- what an attacker gains (data read, code run, a protection bypassed);
- a suggested fix if you have one.

Leave real personal data out of the report: no passwords, cookies, tokens or browsing history.

## What counts

Lithium is a browser: it loads pages nobody trusts, next to data that is private. In scope:

- a website reading or changing what it should not: other sites' data, local files, history, saved state, or anything behind a `lithium://` page;
- a website reaching the bridges Lithium gives its own pages, its extensions support or its agent access;
- a way around a protection Lithium says it applies (content blocking, fingerprinting protection, HTTPS upgrades, fraudulent-site warnings, popup blocking) that goes beyond a single missed filter rule;
- an agent connected over MCP reading what Lithium hides from agents (password, card and cookie values), or another account or process on the Mac using agent access without the token;
- a flaw in how Lithium stores or protects what it keeps on disk (history, the saved session, the agent token).

Out of scope:

- vulnerabilities in WebKit itself: follow [WebKit's security policy](https://webkit.org/security-policy/);
- an ad or tracker a filter list misses: report it to the list's maintainers;
- attacks that need an unlocked Mac already under the attacker's control.
