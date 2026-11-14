# User Request — Files View Redesign

Verbatim intent from the operator across the thread, in order.

## R1 — Redesign the Files tab UI/UX

> "This branch has work that implements a new `Files` tab in the web frontend.
> The functionality seems to be working as expected, but the UI/UX doesn't
> really match the rest of the app. I'm thinking that instead of having the
> whole directory listing take up the full page, maybe it makes more sense to
> have a directory tree explorer in a left bar and then leave space open on the
> right as a place for viewing either a more detailed listing of the current
> selected directory or a file contents viewer. Can you come up with one or
> more new design ideas for the Files page that we can brainstorm to find
> something that gives a better user experience and also matches the look and
> feel established in the rest of the web frontend?"

Acceptance:
- [ ] Directory tree explorer in a left rail.
- [ ] Right pane shows either a detailed listing of the selected directory, or
      a file contents viewer.
- [ ] Matches the look and feel established in the rest of the web frontend.
- [ ] Better UX than the current full-page directory listing.

## R2 — One-path URL scheme

> "Agree that the URL model is important. I think our URL scheme should only
> require one path which defines what is being viewed in the main content
> area. If only that path is specified, then the left rail tree view needs to
> default to something standard and expected (perhaps the parent directory of
> the thing being viewed)."

Acceptance:
- [ ] The URL requires only ONE path parameter.
- [ ] That path defines what the main content area shows.
- [ ] The rail defaults to the parent directory of that path.

## R3 — One or two SSH operations, reused connection

> "In remote mode for sure (and it also probably makes sense to do this in
> local mode), I think we should try to ensure that we gather all the
> necessary data from the server in one or two remote SSH operations. If we're
> viewing a specific file, I could imagine it might be necessary to do two
> separate requests, one for the contents of the file being viewed and one for
> the directory tree information. But we should try to reuse a single SSH
> connection if possible to minimize the network / connection negotiation
> overhead."

Acceptance:
- [ ] One or two remote SSH operations per view.
- [ ] A single SSH connection is reused where possible.

## R4 — Option A confirmed

> "Option A sounds like the best to me as well."
>
> ("Option A" = rail + detail pane: a directory tree in a left rail with the
> right pane showing either the selected directory's detail listing or a file
> contents viewer, styled consistently with the other section views.)

## R5 — Security scope decision (operator's explicit call)

> "I don't think we need to do any Origin validation special for this file
> explorer work. We already have the whole frontend gated behind passkey
> authentication. I think that will be sufficient for the file explorer as
> well. The spec is probably out of date."

Acceptance:
- [ ] The plan must NOT add Origin validation to the file explorer routes.
- [ ] Reliance on the passkey gate must be justified, not assumed.

## R6 — Branch discipline

> "The PR that is currently open is for the `files/explorer` branch. Let's
> leave that branch and PR as-is. This work is on a new branch `files/explorer2`
> which branches off of `files/explorer`."

Acceptance:
- [ ] All work lands on `files/explorer2`.
- [ ] `files/explorer` is not modified.
