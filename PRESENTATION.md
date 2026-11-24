# Making [Client]'s Global Application Faster — Options Review

Topics and talking points only, one `##` heading per slide. Written for a
client with a worldwide user base, an existing EKS cluster, and static
content, evaluating three AWS tools.

**This same narrative is now built into the interactive page itself**
(`site/index.html`): it opens on a title slide and scrolls through the exact
sequence below, with each tool's live test sitting right where its slide
would go in a deck — the client can scroll through the whole pitch and run
every test inline, without switching between slides and a demo. Use this
file to export the talking points into slide software, print a leave-behind,
or rehearse; use the page itself to actually present and demo live.

Each tool-specific slide below has a **Try it live** link that jumps the demo
page straight to the matching tab (and, where noted, straight to the cost
simulator or straight into a running test). Replace `DEMO_URL` with wherever
`terraform output -raw interactive_page_url` points once deployed — for a
local walkthrough before that, use the preview server
(`python3 site/preview_server.py`, then `http://127.0.0.1:8751`).

| Link | What it opens |
| --- | --- |
| `DEMO_URL/#tab=static` | Static assets tab, top |
| `DEMO_URL/#tab=static&focus=cost` | Static assets tab, scrolled to the cost comparison |
| `DEMO_URL/#tab=static&run=1` | Static assets tab, race starts automatically |
| `DEMO_URL/#tab=api` | API tab, top |
| `DEMO_URL/#tab=api&focus=cost` | API tab, scrolled to the cost comparison |
| `DEMO_URL/#tab=api&run=1` | API tab, race starts automatically |
| `DEMO_URL/#tab=db` | Database tab, top (all four route maps) |
| `DEMO_URL/#tab=db&focus=cost` | Database tab, scrolled to the cost comparison |
| `DEMO_URL/#tab=db&run=1` | Database tab, all four paths start automatically |

---

## 1. Title

**Making [Client]'s application faster for a global user base**
Three AWS tools, three different trade-offs — demonstrated live, not just
described.

---

## 2. The situation today

- Users are spread around the world; the application and its data currently
  sit in one region.
- Every user far from that region pays the physical distance in latency —
  no amount of server tuning removes that.
- The client runs an **EKS cluster** for its API/application layer and has
  **static assets** (web content, downloads, media) served from the same
  region.
- Three AWS tools are on the table, each solving a *different part* of the
  distance problem. They are not interchangeable, and not all of them apply
  to all workloads — that's the core message of this review.

---

## 3. The three tools, one line each

| Tool | What it actually does | Applies to |
| --- | --- | --- |
| **CloudFront** | Caches a copy of content at edge locations near the user | Static assets |
| **Global Accelerator** | Routes traffic onto AWS's private backbone via the nearest entry point | EKS / API traffic |
| **Aurora Global Database** | Replicates the data itself to a region near the user | Database reads |

The common thread: each tool moves something closer to the user — a cached
copy, a network path, or the data itself. None of them make the origin
server itself faster; they all work around distance in a different way.

---

## 4. Tool 1 — CloudFront, for static assets

**Try it live:** `DEMO_URL/#tab=static&run=1`

- **What it is:** a CDN. The first request for an object is a cache miss and
  still pays the full trip to the origin; every request after that is served
  from the nearest edge location, often in single-digit milliseconds.
- **Why it fits here:** [Client]'s static assets (images, downloads, JS/CSS,
  public pages) are exactly the kind of content a CDN is built for —
  identical bytes served to many users, rarely changing.
- **How we'd wire it in:** keep the origin bucket/server private, put
  CloudFront in front of it with Origin Access Control (OAC) so the origin
  is never reachable directly — only through the CDN.
- **In the live demo:** the *Static assets* tab races a direct fetch against
  a CloudFront fetch of the same file, from your own browser, right now.

---

## 5. CloudFront — trade-offs, cost, maintainability

**Try it live:** `DEMO_URL/#tab=static&focus=cost`

- **Trade-off:** only helps *cacheable* content. Anything personalized or
  frequently changing still pays the origin round trip on every miss. Cache
  invalidation becomes a step in the deploy process.
- **Cost:** priced per request and per GB served, with a permanent 1 TB/month
  free tier. At real traffic volumes this is typically **far cheaper** than
  serving the same traffic directly from the origin, because most requests
  never reach the origin at all.
- **Maintainability:** low. Fully managed; the main ongoing task is
  cache-control headers / invalidations when content changes. No servers to
  patch.
- **Bottom line:** close to a "yes, do this" for any static content — the
  question is scope (which assets), not whether it's worth it.

---

## 6. CloudFront — code at the edge (optional add-on)

- **What it is:** CloudFront can run your code on requests and responses as
  they pass through. Two options: **CloudFront Functions** (lightweight
  JavaScript, runs at the edge location) and **Lambda@Edge** (Node.js or
  Python, full Lambda features).
- **Use CloudFront Functions for:** cache-key normalization, header changes,
  redirects and rewrites, token checks. Submillisecond, 10 KB of code, one
  network call to an origin on the same distribution, millions of requests
  per second.
- **Use Lambda@Edge for:** third-party libraries or the AWS SDK, more than
  one network call, request body or file system access. Up to 30 s, up to
  50 MB of code, any network destination, up to 10,000 requests per second
  per Region.
- **It sits in the request path:** viewer-side functions run on every
  request, including cache hits; origin-side ones run only on a miss.
  CloudFront waits for the function, so each one adds latency.
- **Cost (AWS list prices):** CloudFront Functions $0.10 per million
  invocations, 2 million free per month. Lambda@Edge $0.60 per million
  requests plus duration, no free tier. Example, 10 million requests with one
  5 ms / 128 MB function each: about $0.80 vs about $6.30 (our arithmetic).
- **Operational strings on Lambda@Edge:** must be created in us-east-1 and
  attached as a numbered version; no environment variables, VPC access,
  layers or arm64; it can't be deleted until CloudFront removes its replicas,
  which community reports put at up to several hours.
- **Our advice:** start with CloudFront Functions; move to Lambda@Edge only
  when the job needs something the lighter option can't do.
- **Not part of this demo:** no edge function is deployed, so nothing here is
  measured. The slide reflects AWS's published behavior and pricing.

---

## 7. CloudFront — flat-rate plans (cost option)

- **What it is:** a distribution can subscribe to a monthly plan that bundles
  the CDN with WAF and DDoS protection, Route 53 DNS, a TLS certificate and
  logging, with no overage charges.
- **Plans (per distribution per month):** Free $0 (1 M requests, 100 GB),
  Pro $15 (10 M, 50 TB), Business $200 (125 M, 50 TB), Premium $1,000
  (500 M, 50 TB; larger allowances at higher prices). S3 storage credit of
  5 GB, 50 GB, 1 TB and 5 TB.
- **What each tier adds:** Pro adds logs, cache-tag invalidation, 25 WAF
  rules and CAPTCHA. Business adds custom caching and response-header rules,
  VPC origins, bot management, advanced DDoS protection and an uptime SLA.
  Premium adds Origin Shield, origin failover and mutual TLS.
- **Not unlimited:** allowances are not hard limits. A first spike up to 3x
  doesn't affect service that month; sustained excess, judged over 2-3 months
  or more, can lead AWS to adjust delivery. Blocked attacks never count.
- **Cost example (our arithmetic from AWS list prices):** 5 TB out and
  8 million requests a month is about $340-350 pay-as-you-go versus $15 on
  Pro. At low volume the free tier makes pay-as-you-go cheap, so a plan buys
  the bundle more than cheaper delivery.
- **Check fit first:** a WAF web ACL is required, one apex domain per plan,
  and some features are unsupported (legacy forwarded values, origin access
  identity, real-time logs, Shield Advanced, staging distributions).
  Lambda@Edge is still billed pay-as-you-go.

---

## 8. CloudFront — price classes and invalidations

- **Price classes:** All (this demo) uses every edge location. Class 200
  leaves out South America, Australia and New Zealand. Class 100 keeps only
  the US, Canada, Mexico, Europe, Israel and Turkiye.
- **Why it saves money:** delivery costs more in some regions (next 9 TB:
  $0.085/GB US and Europe, $0.110 South America, $0.114 Japan and Australia,
  $0.120 Singapore and similar). **What it costs you:** viewers in left-out
  regions are served from farther edges, so latency rises. Use a lower class
  for an audience concentrated in the US and Europe; keep All for global
  speed.
- **Invalidations:** the first 1,000 paths a month are free, then $0.005 per
  path. A wildcard path counts as one. AWS's example: 2,000 paths a month
  costs $5.
- **Often avoidable:** versioned file names (for example `app.3f2a.js`)
  make a changed file a new URL, so nothing needs invalidating.

---

## 9. CloudFront — custom domain

- **Three pieces:** an alternate domain name on the distribution, a TLS
  certificate that covers it, and a Route 53 ALIAS record pointing at the
  distribution.
- **Certificate region:** for CloudFront the ACM certificate must be
  requested or imported in us-east-1, wherever the rest of the stack runs.
  A load-balancer origin's certificate can be in any region. ACM renews its
  own certificates; imported ones must be renewed at least 24 hours early.
- **ALIAS vs CNAME:** a plain CNAME can't sit at a domain's root; an ALIAS
  record can. With a flat-rate plan, ALIAS queries to CloudFront don't count
  against the DNS allowance and CNAME queries do.
- **In this demo:** everything uses AWS-generated names and CloudFront's
  default certificate. Adding a domain would need a us-east-1 provider alias
  (the project has none), a validated ACM certificate, the alias and
  certificate on the distribution, and a Route 53 record.

---

## 10. Tool 2 — Global Accelerator, for the EKS API layer

**Try it live:** `DEMO_URL/#tab=api&run=1`

- **What it is:** a set of static anycast IPs. A user's connection enters
  AWS's network at whichever edge location is physically closest to them,
  then rides AWS's own private backbone the rest of the way to the EKS
  ingress/load balancer — instead of the public internet's unpredictable
  routing.
- **Why it fits here:** API responses from an application are generated per
  request and usually **can't be cached** — CloudFront doesn't help there.
  Global Accelerator helps with the network path itself, not the content.
- **How we'd wire it in:** point Global Accelerator at the existing ALB/NLB
  in front of EKS. No application changes required — this is purely a
  network-layer change.
- **In the live demo:** the *API* tab races a direct call to a load balancer
  against the same call through Global Accelerator.

---

## 11. Global Accelerator — trade-offs, cost, maintainability

**Try it live:** `DEMO_URL/#tab=api&focus=cost`

- **Trade-off:** the win shows up mainly as **consistency** — fewer slow
  outliers caused by internet congestion or bad routing — more than a large
  average-latency drop. The benefit shrinks the closer a user already is to
  the origin region. It's a **fixed cost whether or not there's traffic.**
- **Cost:** a flat per-accelerator hourly fee (≈ $18/month) **plus** premium
  per-GB data transfer, on top of whatever the load balancer already costs.
  In our demo numbers, the direct path was actually *cheaper* than the
  accelerated one — speed and cost are not the same axis here.
- **Maintainability:** low — it's a managed service layered in front of
  infrastructure that already exists; no new servers, no code changes.
- **Bottom line:** worth it where **consistency under load/congestion**
  matters (e.g. transactional API calls, live interactions) more than raw
  cost — not a blanket "turn it on everywhere."

---

## 12. Tool 3 — Aurora Global Database, for the data layer

**Try it live:** `DEMO_URL/#tab=db&run=1`

- **What it is:** one writer region, with read replicas kept in sync in
  other regions. Reads in a replica region are served locally; writes are
  automatically forwarded back to the writer, wherever they originate.
- **Why it fits here:** a database connection is "chatty" — every single
  query is its own round trip. No network-layer trick (not even Global
  Accelerator) can fix that, because the distance to the data itself hasn't
  changed. The only real fix is moving **the data**, not the network path.
- **How we'd wire it in:** this is the option that requires **part of the
  application to move** — specifically, the read path for a given region
  needs to run close to that region's replica to get the benefit. A
  read-only reporting service or a regional API tier are natural
  candidates; write-heavy paths don't benefit the same way.
- **In the live demo:** the *Database* tab shows four ways to reach the same
  database — direct, Global Accelerator, private peering, and a local
  replica — so you can see directly that only the replica actually moves the
  needle on latency.

---

## 13. Aurora Global Database — trade-offs, cost, maintainability

**Try it live:** `DEMO_URL/#tab=db&focus=cost`

- **Trade-off:** this is the **highest-commitment** option of the three.
  - Reads get fast once the application's read path runs near the replica
    — but that's an application/deployment change, not just infrastructure.
  - Writes still always travel to the original writer region, no matter
    where they're issued from — there's no way around that with this
    architecture.
  - Replicated data can be briefly stale (replication lag) — the
    application needs to tolerate that for the read path to be safe.
- **Cost:** roughly **doubles** the database compute bill (a second set of
  capacity units running in the replica region, in addition to the writer).
  There's no way to get the latency benefit without paying for that second
  copy of compute.
- **Maintainability:** the highest of the three tools — replication lag
  needs monitoring, and some application logic may need to be
  region-aware (which replica to read from, how to handle forwarded
  writes). This is an architecture decision, not a toggle.
- **Bottom line:** worth it only where there's a genuinely **read-heavy**,
  latency-sensitive workload in that other region — and only once the team
  is ready to also move the relevant part of the application there.

---

## 14. Putting it together — what applies to what

**Try it live:** `DEMO_URL/#tab=overview` (the summary cards link straight
into each tool's own test)

| [Client]'s workload | Recommended tool | Why |
| --- | --- | --- |
| Static assets (images, downloads, public pages) | **CloudFront** | Cacheable, identical to every user, cheapest and fastest option |
| EKS API traffic (no app changes wanted) | **Global Accelerator** | Pure network-layer fix, no code or data changes |
| Database reads, if an app tier moves near the user | **Aurora Global Database** | Only option that actually shortens the data's travel distance |
| Database writes | *(none of these fix it)* | Writes always return to the writer region by design |

These three can be adopted **independently and incrementally** — they don't
depend on each other. A natural order: CloudFront first (lowest cost,
lowest risk, fastest win), Global Accelerator next (drop-in for EKS), Aurora
Global Database last (requires the application-move decision).

---

## 15. Cost summary (ballpark, for comparison only)

| Tool | Approx. monthly cost driver | Where it saves |
| --- | --- | --- |
| CloudFront | Per-GB served + requests (1 TB/mo free) | Usually cheaper than direct origin traffic at scale |
| Global Accelerator | ~$18/mo fixed + premium transfer | No cost saving — pure latency/consistency investment |
| Aurora Global Database | Roughly 2× database compute | No cost saving — pure latency investment, for read-heavy regional traffic |

Only CloudFront is likely to **reduce** cost while also improving latency.
The other two are latency investments with a real, ongoing price tag — the
decision is about value to the business (user experience, conversion,
SLAs), not about saving money.

---

## 16. Honest caveats

- Global Accelerator and Aurora Global Database add **fixed, ongoing cost**
  regardless of traffic — they should be justified by a real latency
  problem, not adopted speculatively.
- Aurora Global Database requires an **application change** (routing reads
  to the correct replica) to deliver its benefit — it is not a
  flip-a-switch improvement like the other two.
- None of the three tools reduce **write** latency to a far-away database —
  that is a hard architectural limit, not a configuration gap.
- The live demo's numbers are lab-measured; the
  client's actual gains depend on their real traffic patterns, payload
  sizes, and user geography — this review is the basis for a follow-up
  measurement against their real workload.

---

## 17. The live demo — what it proves

- A working, deployable Terraform setup with all three tools wired up
  exactly as described, between two real AWS regions.
- An interactive page that **measures live**, from your own browser (static
  and API) or from a regional probe (database) — not canned numbers.
- Real traceroutes from an actual client in the second region, so the
  network path claims are observable, not just asserted.
- A cost simulator on each tab, so the price trade-off can be explored at
  the client's own traffic volumes, live, during the meeting.

---

## 18. Recommended next steps

1. Confirm which static assets, API endpoints, and database read paths are
   actually latency-sensitive for [Client]'s real users (measure, don't
   assume).
2. Pilot **CloudFront** first — lowest cost, lowest risk, fastest to show
   value.
3. Pilot **Global Accelerator** in front of the existing EKS ingress — no
   application changes required.
4. Scope the **Aurora Global Database** option as a separate project once a
   specific read-heavy, region-local workload is identified, including the
   application changes it requires.
5. Re-run this same demo against [Client]'s actual regions and traffic
   shapes before committing budget.
