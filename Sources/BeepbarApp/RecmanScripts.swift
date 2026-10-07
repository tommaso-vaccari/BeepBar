import Foundation

/// The JavaScript `RecmanWebSession` runs in Polimi's pages. Each script only reads the page or
/// presses one of its own controls, and reports in plain values (a status word or a JSON string);
/// every decision about what the values mean lives in Core (`PolimiPage`, `RecmanArchiveListing`),
/// where it is tested without a browser.
///
/// They run in an isolated content world (`WKContentWorld.defaultClient`): the page's own scripts
/// share the DOM with them but can't replace the functions they call. Recman has no ids on its
/// table, so the selectors follow its layout as observed on the live archive; the fixtures in
/// `RecmanScriptsTests` copy that layout, and `scripts/recman-probe.sh` checks it against the real
/// site.
enum RecmanScripts {
    /// What kind of page this is, as JSON for `PolimiPageFacts.decode`. "Asks for credentials"
    /// counts only visible fields, because Polimi's self-submitting pages carry hidden ones.
    static let pageFacts = #"""
    (() => {
      const visible = e => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
      return JSON.stringify({
        hasArchiveForm: !!document.querySelector('select[name="aa"]') && !!document.querySelector('input[name="contesto"]') && !!document.querySelector('[name="EVN_SEARCH"]'),
        hasAutomaticRedirectForm: !!document.querySelector('form#automaticaRedirectForm'),
        asksForCredentials: Array.from(document.querySelectorAll('input')).some(i => visible(i) && (i.type === 'password' || i.autocomplete === 'one-time-code'))
      });
    })()
    """#

    /// Clears the results table's own column filters, which Recman keeps in its session, so they
    /// can't narrow the next search. "clean" when there was nothing to clear (no navigation),
    /// "submitted" when the filter form was sent (a page load follows), "missing" if the form
    /// has filled filters but no button to apply the change.
    static let clearColumnFilters = #"""
    (() => {
      const fields = Array.from(document.querySelectorAll('[name^="search_transfers__CAMPO_"]'));
      if (!fields.some(f => f.value && f.value.trim())) return 'clean';
      const apply = document.querySelector('[name^="evn_ricerca_recordset"]');
      if (!apply) return 'missing';
      fields.forEach(f => { f.value = ''; });
      apply.click();
      return 'submitted';
    })()
    """#

    /// The search for one course and year, as a function body for `callAsyncJavaScript` with
    /// `code` and `year` (both strings) as arguments, so nothing from outside is spliced into the
    /// source. Every other filter is emptied first: a date range or a kind left over from an
    /// earlier search would silently shorten the list. "submitted" (a page load follows),
    /// "missingForm", or "missingYear" when the archive doesn't offer that academic year.
    static let search = #"""
    const aa = document.querySelector('select[name="aa"]');
    const course = document.querySelector('input[name="contesto"]');
    const submit = document.querySelector('[name="EVN_SEARCH"]');
    if (!aa || !course || !submit) return 'missingForm';
    if (!Array.from(aa.options).some(o => o.value === year)) return 'missingYear';
    for (const name of ['fromDateReg', 'fromDateReg_day', 'fromDateReg_month', 'fromDateReg_year', 'toDateReg', 'toDateReg_day', 'toDateReg_month', 'toDateReg_year', 'argomento', 'tipologia']) {
      document.querySelectorAll('[name="' + name + '"]').forEach(f => { f.value = ''; });
    }
    aa.value = year;
    course.value = code;
    submit.click();
    return 'submitted';
    """#

    /// One page of results, as JSON for `RecmanResultsPage.decode`.
    ///
    /// A result row is an innermost `tr` with a preview link or a date cell. A row with a date but
    /// no preview link is still reported (with an empty link), so it fails the page in Core instead
    /// of vanishing here. `searchedCode`/`searchedYear` are what the form holds after the search,
    /// which is how Core tells this search's results from a page the archive started over on.
    static let resultsPage = #"""
    (() => {
      const clean = t => (t || '').trim().replace(/\s+/g, ' ');
      const previewOf = r => Array.from(r.querySelectorAll('a[href]')).map(a => a.href).find(h => h.includes('evn_preview_link') && h.includes('transfer_id=')) || '';
      const rows = Array.from(document.querySelectorAll('tr')).filter(r => !r.querySelector('tr') && (previewOf(r) || Array.from(r.cells).some(c => /\b\d{2}\/\d{2}\/\d{4}\b/.test(c.innerText))));
      const text = document.body ? document.body.innerText : '';
      const total = text.match(/totale\s*:\s*([0-9]+)/i);
      const aa = document.querySelector('select[name="aa"]');
      const course = document.querySelector('input[name="contesto"]');
      return JSON.stringify({
        rows: rows.map(r => ({ cells: Array.from(r.cells).map(c => clean(c.innerText)), previewURL: previewOf(r) })),
        total: total ? Number(total[1]) : null,
        hasNext: Array.from(document.querySelectorAll('a[href]')).some(a => clean(a.innerText).toLowerCase() === 'prossima' && !a.classList.contains('disabled') && a.getAttribute('aria-disabled') !== 'true'),
        saysEmpty: /nessun[ao]?\s+(registrazion|risultat|element|record)/i.test(text),
        searchedCode: course ? course.value.trim() : '',
        searchedYear: aa ? aa.value : ''
      });
    })()
    """#

    /// Follows the enabled "prossima" link: "submitted" (a page load follows) or "missing".
    ///
    /// The link's address is loaded rather than the link clicked. Recman's own script takes over
    /// clicks on its pager links and swaps the table in place, so a click changes the page with
    /// no page load for `RecmanWebSession` to wait for: every course with more than one page of
    /// recordings sat for the whole load timeout and then failed as "Polimi isn't responding"
    /// (live check of 2026-10-06). Loading the address gets the same page as a real load.
    static let nextPage = #"""
    (() => {
      const next = Array.from(document.querySelectorAll('a[href]')).find(a => (a.innerText || '').trim().replace(/\s+/g, ' ').toLowerCase() === 'prossima' && !a.classList.contains('disabled') && a.getAttribute('aria-disabled') !== 'true');
      if (!next) return 'missing';
      location.href = next.href;
      return 'submitted';
    })()
    """#

    /// Asks for a hundred results a page when the search runs over more than one page, so nearly
    /// every course is read in one load instead of one per ten recordings. "submitted" (a page
    /// load follows, back on page one) or "unchanged": everything already fits on this page, or
    /// there is no "100" link because that is the size already shown (Recman prints the current
    /// size as plain text). "prossima" still reads whatever doesn't fit. The link is loaded, not
    /// clicked, for the reason `nextPage` gives.
    static let hundredPerPage = #"""
    (() => {
      const clean = t => (t || '').trim().replace(/\s+/g, ' ');
      const enabled = a => !a.classList.contains('disabled') && a.getAttribute('aria-disabled') !== 'true';
      const links = Array.from(document.querySelectorAll('a[href]')).filter(enabled);
      if (!links.some(a => clean(a.innerText).toLowerCase() === 'prossima')) return 'unchanged';
      const hundred = links.find(a => clean(a.innerText) === '100');
      if (!hundred) return 'unchanged';
      location.href = hundred.href;
      return 'submitted';
    })()
    """#

    /// The Webex player a preview page links or embeds, or "" when there is none. The address is
    /// still checked by `RecmanURLPolicy.playbackURL` before anything opens it.
    static let playbackLink = #"""
    (() => {
      const links = Array.from(document.querySelectorAll('a[href], iframe[src]')).map(e => e.href || e.src || '');
      return links.find(h => h.startsWith('https://politecnicomilano.webex.com/')) || '';
    })()
    """#
}
