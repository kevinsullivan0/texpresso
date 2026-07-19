# Focused Preview: Implementation and Test Specification

## Status

Proposed. This document specifies the smallest useful experiment; it does not
authorize a general Beamer parser or isolated-frame compiler.

## Problem

After an edit, TeXpresso rolls back to a saved TeX process and continues
compiling the document. The page being edited may become usable before later
pages finish, but TeXpresso currently keeps advancing the engine.

For long homework documents and presentations, later pages may contain costly
TikZ, PGFPlots, or other work irrelevant to the current edit. The editor should
be able to ask TeXpresso to stop once one source location has a renderable page.

The user must not need to add `\includeonly`, wrappers, markers, or other
TeXpresso-specific LaTeX.

## Design boundary

TeXpresso may skip work **after** the requested page. It must not pretend that
pages or Beamer frames before the request are independent.

Earlier input can define macros, mutate counters, create labels, change section
or navigation state, and perform global assignments. On a cold start TeXpresso
must execute that input. During an incremental run it should reuse its existing
forked process checkpoints and roll back to the newest valid checkpoint before
the edit.

No source parser will try to extract a frame and compile `preamble + frame`.
That output would be fast but observably wrong for valid documents.

## Goals

1. Make the page at a requested source file and line renderable as soon as the
   existing engine permits.
2. Stop engine stepping once that page and its SyncTeX data are available.
3. Resume automatically when a new preview location or page navigation requires
   more output.
4. Preserve the existing rollback, VFS, diagnostics, and manual pause behavior.
5. Work without document changes for ordinary LaTeX and Beamer.

## Non-goals

- Compiling an arbitrary page or Beamer frame in isolation.
- Inferring whether TeX input has local or global effects.
- Generating every overlay belonging to a Beamer frame before stopping.
- Replacing VimTeX, `latexmk`, or an authoritative full PDF build.
- Adding TikZ caching, automatic `\includeonly`, or auxiliary-file orchestration.
- Guaranteeing that references or navigation data are current before the
  canonical build has produced current auxiliary files.

## User-visible behavior

The existing forward-search request also selects the focused preview target:

```scheme
(synctex-forward "path" line)
```

`path` and zero-based `line` use the same rules as `synctex-forward`.

TeXpresso then:

1. stores the source location as the active preview target;
2. permits engine stepping, unless an explicit `(pause)` is active;
3. applies normal VFS changes and rollback;
4. advances until SyncTeX maps the target to a complete output page;
5. displays that page; and
6. suspends automatic engine stepping.

When satisfied, TeXpresso emits:

```scheme
(preview-ready "path" line page)
```

`page` is zero-based. The message is useful to editor clients and makes the
behavior testable without inspecting the SDL window.

If the target cannot yet be resolved, compilation continues normally. If TeX
terminates first, existing diagnostics remain authoritative and no
`preview-ready` message is emitted.

Sending another `synctex-forward` replaces the previous target and resumes
stepping. `next-page` and `previous-page` cancel the source target. If
navigation requests output that does not exist yet, stepping resumes until the
requested output exists.

Explicit `(pause)` and `(resume)` remain manual controls. Manual pause has
priority over focused preview: `synctex-forward` records its target but does
not override an explicit pause. `(resume)` clears only the manual pause and
allows the pending focused request to run.

## Internal state

Replace the single conceptual pause condition with two reasons:

- `manual_paused`: controlled by `(pause)` and `(resume)`;
- `preview_satisfied`: true after the active target becomes renderable.

Engine stepping is allowed when:

```text
!manual_paused && !preview_satisfied
```

The active preview target contains only:

- normalized source path;
- zero-based source line;
- request generation; and
- optional resolved page.

No frame table, page ownership table, or TeX source AST is introduced.

The request generation prevents an already-rendered page from satisfying a new
request after an edit. Any change transaction that causes rollback marks the
active target unresolved for the new document generation.

## Completion condition

After each engine step that changes XDV or SyncTeX state, check the target:

1. SyncTeX resolves its path and line to page `p`.
2. The XDV parser reports more than `p` complete pages.
3. SyncTeX reports more than `p` pages for the current generation.

Only then display `p`, emit `preview-ready`, and set `preview_satisfied`.

Do not stop at `\begin{frame}` or the first XDV `BOP`. A page is usable only
after its matching `EOP` has been received and parsed.

For Beamer, one source line may map to one overlay even when its frame produces
several overlays. Version 1 stops after the resolved overlay. Navigating to a
later overlay resumes compilation. Producing all overlays for a frame would
require reliable frame ownership and is deliberately deferred.

## Viewer anchoring

While a focused `synctex-forward` request is active, its source path and line—not the old
numeric page—are the logical viewer anchor. When rollback changes page indices,
display the newly resolved page.

When no source target is active, retain current numeric-page behavior. Do not
attempt to infer a source anchor from arbitrary rendered content in version 1.

## Expected code changes

Keep the change in the frontend unless tests prove that an engine API is
missing:

- `EDITOR-PROTOCOL.md`: document the focused `synctex-forward` behavior and
  `preview-ready`.
- `src/frontend/editor.h`: add the parsed command and target fields.
- `src/frontend/editor.c`: parse the command.
- `src/frontend/driver.h`: separate manual pause from preview satisfaction.
- `src/frontend/main.c`: own the target state, completion check, display, and
  readiness message.
- `src/frontend/synctex.[ch]`: add at most one query helper if the existing
  forward-search interface cannot return a resolved page without mutating UI
  state.
- `test/`: add fixtures and a shell-level protocol regression test.

Do not modify the XeTeX engine, checkpoint selection, XDV parser, or DVI renderer
for the first implementation.

## Test fixtures

### Ordinary LaTeX

Create a document with:

1. a preamble macro used on every page;
2. three pages sourced from separate `\input` files; and
3. an intentionally slow or easily observed final page.

The source files must not contain TeXpresso-specific commands.

### Beamer

Create a deck with:

1. a preamble theme or macro;
2. an earlier frame that advances normal Beamer state;
3. a target frame using `\pause`, `\only`, and an overlay-aware list; and
4. a later frame that is distinguishable in the log or page count.

Also include a variant where editing the target frame adds or removes an
overlay.

## Automated tests

Add one shell test using the existing stream/protocol test style. It must cover:

1. **Cold start:** request a location on page 2, resume, receive
   `preview-ready`, and verify page 3 has not completed.
2. **Incremental edit:** change text on the target page, verify rollback occurs,
   then receive a new `preview-ready` for the same source location.
3. **Replacement:** send two targets quickly and verify readiness is emitted
   only for the newest generation.
4. **Manual pause:** send `pause`, then `synctex-forward`; verify no readiness
   until `resume`.
5. **Navigation:** after focused suspension, request the next unavailable page
   and verify compilation resumes.
6. **Error:** introduce a syntax error before the target; verify no false
   readiness and no crash.
7. **Beamer overlays:** target an overlay line, change the overlay count, and
   verify the resolved page is renderable and later frames remain uncompiled.

Use bounded polling like the existing integration tests. Do not add a test
framework or timing sleeps as correctness assertions.

## Performance evaluation

Performance is an acceptance gate, not an automated pass/fail test.

For one representative homework document and one representative presentation,
record:

- edit receipt to target page complete;
- target page complete to full document complete;
- pages emitted before focused suspension; and
- whether an expensive later TikZ frame begins execution.

Implement focused preview only if the second interval or avoided work is
material in a real document. If the requested page is not available sooner or
background completion has negligible cost, keep the regression fixtures and do
not ship the feature.

## Acceptance criteria

- No LaTeX source changes are required.
- Output through the focused page matches an uninterrupted TeXpresso run.
- No page after the focused page is completed before suspension, allowing for
  bytes already received in the same engine protocol transaction.
- A changed target produces a new readiness event; stale output cannot satisfy
  it.
- Manual pause remains authoritative.
- Beamer overlay insertion or removal does not leave stale pages visible.
- Existing stream, register, lookup-file, pause/resume, and initialization tests
  continue to pass.
- The implementation adds no TeX parser and no new dependency.

## Deferred extensions

Consider these only after version 1 is useful in practice:

- an explicit command to finish the document in the background;
- preserving a relative overlay within a frame;
- reporting provisional versus canonical auxiliary state.

Automatic frame extraction and `\includeonly` injection remain out of scope
unless concrete measurements show checkpointed execution is insufficient.
