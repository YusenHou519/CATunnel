#!/usr/bin/env python3
"""Check an already-running website preview with an existing Playwright install."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Preview URL, including its project path")
    parser.add_argument("--output", type=Path, help="Optional directory for screenshots and JSON report")
    args = parser.parse_args()
    target = urlsplit(args.url)
    if target.scheme not in {"http", "https"} or not target.netloc or target.username or target.password:
        parser.error("--url must be an HTTP(S) preview URL without credentials")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        parser.error("Requires an existing Playwright Python installation and Chromium browser")

    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    checks = []
    errors = []
    missing = []
    external = []
    report = {"status": "failed", "checks": checks,
              "scope": "Browser-only website checks; document visibility is simulated. No application or server changes."}

    def check(name, passed):
        checks.append({"name": name, "passed": bool(passed)})
        if not passed:
            raise AssertionError(name)

    def url(language):
        query = dict(parse_qsl(target.query))
        query["lang"] = language
        return urlunsplit(target._replace(query=urlencode(query), fragment=""))

    def screenshot(page, filename, full_page=False):
        if args.output:
            page.screenshot(path=str(args.output / filename), full_page=full_page)

    def monitor(page):
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("response", lambda response: missing.append(response.url) if response.status >= 400 else None)

    def allow_local_assets(route):
        request = urlsplit(route.request.url)
        if request.scheme in {"http", "https"} and (request.scheme, request.netloc) != (target.scheme, target.netloc):
            external.append(route.request.url)
            route.abort()
        else:
            route.continue_()

    def state(page, key):
        return page.locator("#traffic-demo").get_attribute("data-" + key)

    def wait_state(page, key, value):
        page.wait_for_function("([key, value]) => document.getElementById('traffic-demo').dataset[key] === value",
                               arg=[key, str(value)], timeout=10000)

    def step(page, value):
        wait_state(page, "step", value)
        nodes = page.locator(".route li")
        expected = [0, 1, 2, 3, 4, 3, 2, 1, 0][value]
        return (nodes.count() == 5 and page.locator('.route li[aria-current="step"]').count() == 1
                and nodes.nth(expected).get_attribute("aria-current") == "step")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            context = browser.new_context(viewport={"width": 1440, "height": 1000}, locale="zh-CN",
                                          permissions=["clipboard-read", "clipboard-write"])
            context.route("**/*", allow_local_assets)
            # Headless tabs need a deterministic visibility event, without relying on window focus.
            context.add_init_script("""
              window.__siteTestHidden = false;
              Object.defineProperty(document, 'hidden', {get: () => window.__siteTestHidden});
              Object.defineProperty(document, 'visibilityState', {
                get: () => window.__siteTestHidden ? 'hidden' : 'visible'
              });
            """)
            page = context.new_page()
            monitor(page)
            page.clock.install()
            page.goto(url("zh"), wait_until="networkidle")
            check("Chinese initial page", page.locator("html").get_attribute("lang") == "zh-CN")
            check("Cover decoded", page.locator(".hero-art").evaluate("i => i.complete && i.naturalWidth > 0"))
            cover = page.locator(".hero-art").bounding_box()
            check("Desktop cover is centered and no wider than 1000px",
                  cover is not None and cover["width"] <= 1000.5 and cover["x"] > 0
                  and abs(cover["x"] - (1440 - cover["width"]) / 2) < 2)
            screenshot(page, "desktop-cover.png")

            demo = page.locator("#traffic-demo")
            demo.scroll_into_view_if_needed()
            wait_state(page, "running", "true")
            check("Visible animation starts automatically", state(page, "playing") == "true")
            before = state(page, "step")
            page.wait_for_function("old => document.getElementById('traffic-demo').dataset.step !== old",
                                   arg=before, timeout=10000)
            check("Playback advances the route", state(page, "step") != before)
            page.locator("#traffic-toggle").click()
            wait_state(page, "running", "false")
            before = state(page, "step")
            page.clock.fast_forward(30000)
            check("Pause retains the current step", state(page, "playing") == "false" and state(page, "step") == before)
            page.evaluate("window.scrollTo({top: 0, behavior: 'instant'})")
            demo.scroll_into_view_if_needed()
            page.clock.fast_forward(30000)
            check("Returning to view preserves a manual pause", state(page, "playing") == "false"
                  and state(page, "running") == "false" and state(page, "step") == before)

            page.locator("#traffic-restart").click()
            check("Restart returns to the remote tool", step(page, 0))
            if state(page, "playing") == "true":
                page.locator("#traffic-toggle").click()
            explanations = []
            for index in range(9):
                if index:
                    page.locator("#traffic-next").click()
                check("Request/response step %d highlights the correct node" % index, step(page, index))
                check("Manual step %d remains paused" % index, state(page, "playing") == "false")
                explanations.append(page.locator("#traffic-status").inner_text().strip())
            check("Every request/response step has its own explanation", all(explanations) and len(set(explanations)) == 9)
            page.locator("#traffic-next").click()
            check("Single-step wraps to a new request", step(page, 0))
            page.locator("#traffic-next").click()
            chinese_status = page.locator("#traffic-status").inner_text()
            page.locator("#language-button").click()
            english_status = page.locator("#traffic-status").inner_text()
            check("Language switch preserves the step and translates its explanation",
                  step(page, 1) and english_status != chinese_status and bool(english_status.strip())
                  and not re.search(r"[\u4e00-\u9fff]", english_status))
            check("English document link is selected", page.locator("[data-href-en]").first.get_attribute("href").endswith("USAGE.en.md"))
            demo.scroll_into_view_if_needed()
            screenshot(page, "desktop-animation.png")
            page.locator("#traffic-toggle").click()
            wait_state(page, "running", "true")
            page.evaluate("window.scrollTo({top: 0, behavior: 'instant'})")
            wait_state(page, "running", "false")
            before = state(page, "step")
            page.clock.fast_forward(30000)
            check("Offscreen animation pauses while retaining playback intent",
                  state(page, "playing") == "true" and state(page, "step") == before)
            demo.scroll_into_view_if_needed()
            wait_state(page, "running", "true")
            check("Returning to the animation resumes it", state(page, "playing") == "true")
            page.evaluate("window.__siteTestHidden = true; document.dispatchEvent(new Event('visibilitychange'))")
            wait_state(page, "running", "false")
            before = state(page, "step")
            page.clock.fast_forward(30000)
            check("Simulated hidden document pauses the animation", state(page, "step") == before)
            page.evaluate("window.__siteTestHidden = false; document.dispatchEvent(new Event('visibilitychange'))")
            wait_state(page, "running", "true")
            check("Simulated visible document resumes playback", state(page, "playing") == "true")
            page.locator("#traffic-toggle").click()

            page.locator("[data-lightbox]").first.click()
            check("Screenshot dialog opens", page.locator("#image-dialog").evaluate("d => d.open"))
            page.keyboard.press("Escape")
            check("Escape closes screenshot dialog", not page.locator("#image-dialog").evaluate("d => d.open"))
            page.locator("#copy-button").click()
            check("Copy command retains its contents", page.evaluate("navigator.clipboard.readText()") == page.locator("#proxy-command").text_content())
            for width in [320, 390, 768, 1440]:
                page.set_viewport_size({"width": width, "height": 1000})
                for language in ["zh", "en"]:
                    page.goto(url(language), wait_until="networkidle")
                    page.locator("#traffic-demo").scroll_into_view_if_needed()
                    check("No horizontal overflow at %dpx in %s" % (width, language),
                          page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
                    box = page.locator(".hero-art").bounding_box()
                    check("Cover fits %dpx in %s" % (width, language), box["x"] >= 0 and box["x"] + box["width"] <= width + 1)
                    check("Animation controls are usable at %dpx in %s" % (width, language),
                          all(page.locator(selector).is_visible() and page.locator(selector).is_enabled()
                              for selector in ["#traffic-toggle", "#traffic-next", "#traffic-restart"]))
                    if width == 390:
                        screenshot(page, "mobile-animation-%s.png" % language)
                if width <= 768:
                    page.locator("#menu-button").click()
                    check("Mobile navigation opens at %dpx" % width, page.locator("#main-nav").is_visible())
                    page.locator('#main-nav a[href="#how-it-works"]').click()
                    check("Mobile navigation closes at %dpx" % width, page.locator("#menu-button").get_attribute("aria-expanded") == "false")
            context.close()

            reduced = browser.new_context(viewport={"width": 390, "height": 1000}, reduced_motion="reduce", locale="en-US")
            reduced.route("**/*", allow_local_assets)
            rp = reduced.new_page()
            monitor(rp)
            rp.goto(url("en"), wait_until="networkidle")
            rp.locator("#traffic-demo").scroll_into_view_if_needed()
            check("Reduced motion disables initial autoplay", state(rp, "playing") == "false" and state(rp, "running") == "false")
            rp.locator("#traffic-next").click()
            check("Reduced motion retains manual explanation steps", step(rp, 1))
            check("Reduced motion disables smooth scrolling", rp.locator("html").evaluate("h => getComputedStyle(h).scrollBehavior") == "auto")
            reduced.close()

            plain = browser.new_context(viewport={"width": 390, "height": 844}, java_script_enabled=False)
            plain.route("**/*", allow_local_assets)
            pp = plain.new_page()
            monitor(pp)
            pp.goto(url("zh"), wait_until="networkidle")
            check("No-JS route remains readable", pp.locator(".route li").count() == 5
                  and all(pp.locator(".route li").nth(index).inner_text().strip() for index in range(5)))
            check("No-JS animation controls remain hidden", all(not pp.locator(selector).is_visible()
                  for selector in ["#traffic-toggle", "#traffic-next", "#traffic-restart"]))
            check("No-JS navigation and downloads remain usable", pp.locator("#main-nav").is_visible()
                  and pp.locator("#download-title").count() == 1)
            check("No-JS page has no horizontal overflow", pp.evaluate("document.documentElement.scrollWidth <= innerWidth"))
            plain.close()
            browser.close()
            check("No browser JavaScript errors", not errors)
            check("No missing website resources", not missing)
            check("No third-party runtime requests", not external)
        report["status"] = "passed"
    except Exception as error:
        report["error"] = str(error)
    report.update({"javascriptErrors": errors, "missingResources": missing, "externalRequests": external})
    if args.output:
        (args.output / "browser-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "checks": len(checks), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
