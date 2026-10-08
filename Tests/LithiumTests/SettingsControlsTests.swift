import Foundation
import Testing
import WebKit
@testable import Lithium

/// Settings' controls share one look: dropdowns, text fields and colour wells take the segmented
/// control's and the swatches' measures. Hover and the keyboard focus ring need a pointer and a
/// focused window, so the snapshots show those.
@MainActor
struct SettingsControlsTests {
    private static let probe = """
        const until = async (test) => { for (let i = 0; i < 200 && !test(); i++) await new Promise((r) => setTimeout(r, 50)); };
        await until(() => $('#version').textContent && $('#interface-font').options.length > 1);
        const problems = [];
        const check = (name, actual, expected) => { if (actual !== expected) problems.push(`${name}: ${actual}, not ${expected}`); };
        const segmented = $('#start-kind'), seg = getComputedStyle(segmented);
        const height = segmented.getBoundingClientRect().height;
        const text = getComputedStyle(segmented.querySelector('button')).fontSize;
        for (const hash of ['appearance', 'max', 'permissions', 'site/www.example.com']) {
          location.hash = hash;
          await until(() => document.querySelector('section.active select'));
          const selects = document.querySelectorAll('section.active select');
          if (!selects.length) problems.push(`${hash}: no dropdown`);
          for (const select of selects) {
            const name = `${hash} ${select.id || 'permission'}`;
            const style = getComputedStyle(select), caret = getComputedStyle(select.parentElement, '::after');
            const box = select.getBoundingClientRect();
            check(`${name} wrapper`, select.parentElement.className, 'select');
            check(`${name} appearance`, style.appearance || style.webkitAppearance, 'none');
            check(`${name} height`, box.height, height);
            check(`${name} radius`, style.borderTopLeftRadius, seg.borderTopLeftRadius);
            check(`${name} border`, `${style.borderTopWidth} ${style.borderTopColor}`, `${seg.borderTopWidth} ${seg.borderTopColor}`);
            check(`${name} text size`, style.fontSize, text);
            check(`${name} caret`, /caret-down/.test(caret.webkitMaskImage || caret.maskImage), true);
            const row = select.closest('.row');
            if (row) check(`${name} right edge`, box.right, row.getBoundingClientRect().right);
          }
        }
        location.hash = 'appearance';
        await until(() => $('#appearance').classList.contains('active'));
        const [interfaceFont, websiteFont] = [$('#interface-font'), $('#website-family')].map((s) => s.getBoundingClientRect().width);
        check('font pickers line up', interfaceFont, websiteFont);
        if (interfaceFont < 200) problems.push(`font picker ${interfaceFont}px wide`);
        // A long family name widens both pickers rather than being clipped under the caret.
        const long = 'Noto Sans Egyptian Hieroglyphs', picker = $('#interface-font'), picked = picker.value;
        const added = [picker, $('#website-family')].map((s) => s.appendChild(new Option(long, long)));
        picker.value = long;
        const pickerStyle = getComputedStyle(picker), ruler = document.body.appendChild(document.createElement('span'));
        Object.assign(ruler.style, { position: 'absolute', whiteSpace: 'nowrap', fontFamily: pickerStyle.fontFamily,
          fontSize: pickerStyle.fontSize, fontWeight: pickerStyle.fontWeight, letterSpacing: pickerStyle.letterSpacing });
        ruler.textContent = long;
        const room = picker.clientWidth - parseFloat(pickerStyle.paddingLeft) - parseFloat(pickerStyle.paddingRight);
        if (room < ruler.getBoundingClientRect().width) problems.push(`long font name clipped: ${room}px for ${ruler.getBoundingClientRect().width}px`);
        ruler.remove();
        added.forEach((option) => option.remove());
        picker.value = picked;

        const select = $('#summary-language');
        select.disabled = true;
        check('disabled dropdown', getComputedStyle(select).opacity, '0.5');
        check('disabled caret', getComputedStyle(select.parentElement, '::after').opacity, '0.5');
        select.disabled = false;

        const field = $('#site-font-site').getBoundingClientRect(), add = $('#site-font-form button');
        check('text field height', field.height, add.getBoundingClientRect().height);
        check('text field radius', getComputedStyle($('#site-font-site')).borderTopLeftRadius, getComputedStyle(add).borderTopLeftRadius);
        check('button radius', getComputedStyle(add).borderTopLeftRadius, seg.borderTopLeftRadius);
        // The sample state shows one start page background at a time: show every well's row to measure them all.
        for (const row of ['#color-row', '#start-color-row', '#start-gradient-row']) $(row).style.display = '';
        const swatch = $('#swatches .swatch').getBoundingClientRect();
        for (const well of document.querySelectorAll('#appearance input[type=color]')) {
          const box = well.getBoundingClientRect();
          check(`${well.id} size`, `${box.width}x${box.height}`, `${swatch.width}x${swatch.height}`);
          check(`${well.id} shape`, getComputedStyle(well).borderTopLeftRadius, '50%');
        }
        return problems;
        """

    @Test func dropdownsAndFieldsMatchTheOtherControls() async throws {
        let configuration = WKWebViewConfiguration()
        InternalSchemeHandler.shared.install(on: configuration)
        configuration.userContentController.addScriptMessageHandler(SampleBridge(), contentWorld: .page, name: InternalBridge.name)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), configuration: configuration)
        let loaded = PageLoad()
        webView.navigationDelegate = loaded
        webView.load(URLRequest(url: URL(string: "lithium://settings#appearance")!))
        try await loaded.wait()
        let problems = try #require(try await webView.callAsyncJavaScript(Self.probe, contentWorld: .page) as? [String])
        for problem in problems { Issue.record("\(problem)") }
    }
}
