{-# LANGUAGE OverloadedStrings #-}
-- | Extension-allowlisted MIME typing for in-browser image preview.
--
-- The file explorer's download endpoint serves every file as
-- @application\/octet-stream@ with @Content-Disposition: attachment@ and
-- @X-Content-Type-Options: nosniff@. That is deliberate: content from the
-- agent's execution machine must never be rendered in the gateway's own
-- origin, because that origin holds the operator's passkey session.
--
-- Image preview needs the opposite on exactly one endpoint variant: a
-- correct @Content-Type@ and @nosniff@ (so the browser decodes the bytes
-- as the type we declare, not as whatever they sniff). 'inlineMediaTypeFor'
-- is the single gate deciding which files may take that path.
--
-- = Why an allowlist and not @mimeTypeFor@
--
-- A denylist of dangerous types is unbounded; a browser's renderer set is
-- not. Only the handful of raster image formats below may be inlined.
--
-- = SVG: allowed, but only with a hardening CSP
--
-- @image\/svg+xml@ is a scriptable document format, so its inclusion is
-- conditional. Two facts decide the design, both verified in a real browser
-- (see 'svgHardeningCsp'):
--
-- * Inside an @<img>@ the browser decodes the file in a restricted mode —
--   scripts never run and subresources never load. So rendering an SVG
--   preview is safe *as a preview*.
-- * The file stays fetchable at its own URL, and navigating there loads it
--   as a DOCUMENT with scripting enabled, in this gateway's
--   passkey-authenticated origin. A malicious @.svg@ fetched that way runs
--   its script and can act as the operator.
--
-- The second fact is why 'inlineMediaTypeFor' returning an SVG is not
-- enough on its own: the response also carries 'svgHardeningCsp', which
-- neutralises the document-navigation path. A caller that serves SVG
-- without that header has reintroduced the vulnerability.
--
-- = Why the extension, not the file's magic bytes
--
-- Sniffing content would mean reading the file before deciding how to serve
-- it (an extra round trip, and on the remote arm an extra SSH command) and
-- would make the served type depend on bytes the caller controls anyway. The
-- extension is what the request is keyed on, and it is what the human sees
-- in the file listing. A mis-named file yields a broken image — never a
-- content-type escape, because 'nsniff' pins the type to our declaration.
module Seal.Gateway.MediaType
  ( InlineMediaType (..)
  , inlineMediaTypeFor
  , svgHardeningCsp
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeExtension, takeFileName)

-- | An image type cleared for inline rendering, and the @Content-Type@
-- header value it must be served with.
--
-- 'imtNeedsSvgCsp' distinguishes SVG, which is a *document* rather than a
-- bitmap. Only SVG sets it, and the serving code must then attach
-- 'svgHardeningCsp' — that header is what makes the document-navigation
-- path safe. Splitting this out as a field (rather than string-matching
-- @image\/svg+xml@ at the call site) keeps the requirement visible in the
-- type instead of in a comment.
data InlineMediaType = InlineMediaType
  { imtContentType :: Text
  , imtNeedsSvgCsp :: Bool
  } deriving stock (Eq, Show)

-- | A raster image type: rendered as pixels, no document semantics.
rasterType :: Text -> InlineMediaType
rasterType ct = InlineMediaType { imtContentType = ct, imtNeedsSvgCsp = False }

-- | The @Content-Type@ to serve @path@ with inline, or 'Nothing' when the
-- extension is not on the allowlist (the caller then keeps the hardened
-- @octet-stream@ + @attachment@ behaviour).
--
-- Matching is case-insensitive: @PHOTO.JPG@ and @photo.jpg@ are the same
-- format, and a camera that writes upper-case extensions must not silently
-- lose preview.
inlineMediaTypeFor :: FilePath -> Maybe InlineMediaType
inlineMediaTypeFor path
  -- A file whose whole name is the suffix (`.png`) is a hidden dotfile, not
  -- an image: `takeExtension "/home/u/.png"` yields @".png"@, so without
  -- this guard the stem would be empty and a dotfile would be typed as an
  -- image purely because of its name.
  | T.null stem = Nothing
  | otherwise = case T.toLower ext of
      ".png"  -> Just (rasterType "image/png")
      ".jpg"  -> Just (rasterType "image/jpeg")
      ".jpeg" -> Just (rasterType "image/jpeg")
      ".gif"  -> Just (rasterType "image/gif")
      ".webp" -> Just (rasterType "image/webp")
      ".avif" -> Just (rasterType "image/avif")
      ".bmp"  -> Just (rasterType "image/bmp")
      ".ico"  -> Just (rasterType "image/x-icon")
      -- SVG is a document, not a bitmap. Allowed here because the response
      -- also carries 'svgHardeningCsp'; the '<img>' render context alone is
      -- not sufficient (the file is reachable as a document too).
      ".svg"  -> Just InlineMediaType
        { imtContentType = "image/svg+xml"
        , imtNeedsSvgCsp = True
        }
      _       -> Nothing
  where
    name = T.pack (takeFileName path)
    ext  = T.pack (takeExtension path)
    stem = T.take (T.length name - T.length ext) name

-- | The @Content-Security-Policy@ that makes serving an SVG inline safe.
--
-- Every directive is load-bearing, and the combination was chosen by
-- measurement rather than by copying a snippet:
--
-- * @sandbox@ — no tokens. Strips scripting and gives the document an
--   opaque origin, so even if a payload slipped through it cannot read
--   cookies, storage, or make same-origin requests.
-- * @default-src 'none'@ / @script-src 'none'@ / @object-src 'none'@ —
--   defence in depth against script, @javascript:@ URLs, and
--   @<object>@/@<embed>@ re-embedding.
-- * @style-src 'unsafe-inline'@ — REQUIRED for fidelity, not a concession.
--   @default-src 'none'@ alone drops an SVG's own @<style>@ block, and
--   design tools routinely style by class rather than by presentation
--   attribute. Measured: without this, a styled SVG renders with default
--   BLACK fills (47k pixels changed). With it, byte-identical to no-CSP.
--   Inline *styles* are not a script vector; @style-src@ is unrelated to
--   execution.
-- * @img-src data:@ — permits only inline (data-URI) images inside the
--   SVG, so a drawing can embed a raster without phoning home.
-- * @base-uri@ / @form-action 'none'@ — close the remaining document
--   behaviours (link rewriting, form submission).
--
-- 'sandbox' cannot be delivered via @<meta http-equiv>@, so this must be a
-- real response header.
svgHardeningCsp :: Text
svgHardeningCsp = T.intercalate "; "
  [ "sandbox"
  , "default-src 'none'"
  , "script-src 'none'"
  , "object-src 'none'"
  , "base-uri 'none'"
  , "form-action 'none'"
  , "style-src 'unsafe-inline'"
  , "img-src data:"
  ]

