/** Inline image preview for the file explorer.
 *
 *  The backend serves these bytes from `GET /api/files/download?inline=1`,
 *  which swaps the hardened `application/octet-stream` + `attachment`
 *  contract for a real `Content-Type` + `inline` — but only for extensions
 *  on its allowlist (`Seal.Gateway.MediaType`). So the `<img>` here must
 *  only ever be pointed at a path the backend will accept, or the browser
 *  receives an attachment and renders a broken image.
 *
 *  That gate lives in `isPreviewableImage`; this component is the rendering
 *  half and stays deliberately dumb: one `<img>`, one size cap, and an
 *  error state for the cases the `<img>` cannot report on its own.
 */
import { useEffect, useState } from 'react'

export interface MediaViewProps {
  /** Absolute path of the image on the execution machine. */
  path: string
  /** Called when the user dismisses the preview. */
  onBack: () => void
  /** Called to run the full (chunked) download flow. */
  onDownload: () => void
}

/** The URL the `<img>` loads. `inline=1` selects the renderable response;
 *  without it the backend returns an attachment and the image would not
 *  decode. */
export function mediaPreviewUrl(path: string): string {
  return `/api/files/download?path=${encodeURIComponent(path)}&inline=1`
}

export function MediaView({ path, onBack, onDownload }: MediaViewProps) {
  // A 413 (over the preview ceiling) surfaces as an image load failure with
  // no other signal, so it is called out explicitly rather than left to look
  // like a corrupt file.
  const [failed, setFailed] = useState(false)

  // A new path is a new image: clear a stale failure from the previous one.
  useEffect(() => { setFailed(false) }, [path])

  return (
    <div data-testid="media-view">
      <div className="files-viewer-actions">
        <a
          className="btn btn-ghost files-btn-sm"
          href={`/api/files/download?path=${encodeURIComponent(path)}`}
          data-testid="media-download"
          onClick={(e) => { e.preventDefault(); onDownload() }}
        >
          Download
        </a>
        <button
          type="button"
          className="btn btn-ghost files-btn-sm"
          data-testid="media-back"
          onClick={onBack}
        >
          Back to directory
        </button>
      </div>
      {failed ? (
        <div data-testid="media-error" className="files-media-error">
          This image could not be previewed. It may be larger than the preview
          limit, or not a valid image file. Use Download to save it.
        </div>
      ) : (
        <div className="files-media-container">
          <img
            src={mediaPreviewUrl(path)}
            alt={path.slice(path.lastIndexOf('/') + 1)}
            data-testid="media-image"
            className="files-media-image"
            onError={() => setFailed(true)}
          />
        </div>
      )}
    </div>
  )
}
