# Sessions and working directories

Every Seal Harness session gets its own working directory. Understanding this one
rule explains most of the surprising behaviour you will otherwise hit — why a new
session cannot see yesterday's files, why two agents can work on the same repo at
once, and why branching a conversation does not branch its files.

## One fresh directory per session

A session's files live at:

```
~/.seal/cache/workdirs/<session-id>
```

Each session gets its own. Nothing is shared between them.

That is the whole isolation model for file operations. When an agent reads or
writes a file, the path is resolved inside its own workdir, and a path that tries
to climb out is rejected. Session A writing `out.txt` cannot touch session B's
`out.txt`, because they are different files in different directories.

Two consequences worth knowing:

- **Parallel sessions are safe.** Run four agents on the same repo and they will
  not clobber each other, because they are not in the same directory.
- **The directory is fresh.** A new session starts empty. It does not inherit
  files from any earlier session, including one on the same repo.

## It persists when the session ends

The workdir is **not** deleted when you stop talking to a session. It stays on
disk so you can go and look at what the agent did.

This is what the **Open session workdir in Files** link in the chat header opens:
the real directory, with the real files. If an agent says it fixed a bug, that is
where you check.

If you want the other behaviour, `cleanup_on_exit = true` under `[workdir]` in
`~/.seal/config/config.toml` removes a session's workdir when the session ends.
The default is to keep it.

## Repos are cloned into the workdir

A repo is not mounted, and it is not symlinked. It is **cloned into** the
session's own directory.

That is why registering a repo does not make its files appear anywhere: the
registry only records the URL and which credential to use. The clone happens when
a session asks for it, and it lands in that session's workdir. A second session on
the same repo clones again, separately.

The upside is complete freedom to let agents do destructive things in a checkout:
`git reset --hard`, branch surgery, deleting files. They are wrecking a private
copy, not your working tree. The cost is disk — workdirs accumulate, and clearing
them out is currently a manual `rm -rf`.

## Branching: transcript yes, files no

You can branch a session from any point in its transcript. The branch inherits the
conversation up to that row.

It does **not** inherit the files. The new session gets a fresh, empty workdir.

This is not an oversight. A past workdir state cannot be reconstructed — files
were changed, deleted, and rewritten by tools that kept no snapshot, so there is
nothing to roll back to. Rather than hand you a half-restored directory that looks
like the past but is not, a branch starts clean.

In practice: if you branch to try a different approach, re-clone the repo. The
composer takes a repo URL before the first turn, so paste it there.

## When the workdir is somewhere else

Everything above describes the default, where untrusted operations run on your own
machine.

In `mode=remote`, those operations run on a separate machine over SSH, and the
workdir moves with them. The directory is still per-session and still isolated;
it just lives in the remote workspace instead:

```
<remote-workspace>/workdirs/<session-id>
```

The Files link follows it. The isolation guarantee does not change — but note what
`mode=remote` buys you: a compromised model cannot reach the control plane, even
though it fully controls its own workdir.

## Related

- **[Getting started](getting-started.md)** — the setup walkthrough, if you have
  not read it yet.
- **[README](https://github.com/seal-harness/seal-harness#readme)** — trust levels,
  the opcode catalog, and the two-plane split.
