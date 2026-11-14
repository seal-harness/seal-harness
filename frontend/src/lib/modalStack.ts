// Modal stack — extracted from ChatArea.tsx so multiple modal-bearing components
// (ChatArea's RawJsonModal, FilesView's DownloadConfirmDialog) share one
// Escape-handler stack and cannot double-fire.

/** A stack of currently-open modal ids. The topmost entry owns Escape. */
export const openModalStack: symbol[] = []
