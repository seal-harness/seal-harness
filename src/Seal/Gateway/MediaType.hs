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
-- = Why SVG is excluded
--
-- @image\/svg+xml@ is a scriptable document format. Navigated to directly it
-- executes script in the serving origin — precisely the class of risk the
-- @nosniff@ + @attachment@ default exists to prevent. It can be previewed
-- safely only inside a sandbox, which is a separate design decision; until
-- then an @.svg@ falls through to the normal download path (a broken image
-- in the viewer, never a script execution).
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
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeExtension, takeFileName)

-- | An image type cleared for inline rendering, and the @Content-Type@
-- header value it must be served with. The constructor is exported so the
-- spec can assert the exact header text.
newtype InlineMediaType = InlineMediaType
  { imtContentType :: Text
  } deriving stock (Eq, Show)

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
      ".png"  -> Just (InlineMediaType "image/png")
      ".jpg"  -> Just (InlineMediaType "image/jpeg")
      ".jpeg" -> Just (InlineMediaType "image/jpeg")
      ".gif"  -> Just (InlineMediaType "image/gif")
      ".webp" -> Just (InlineMediaType "image/webp")
      ".avif" -> Just (InlineMediaType "image/avif")
      ".bmp"  -> Just (InlineMediaType "image/bmp")
      ".ico"  -> Just (InlineMediaType "image/x-icon")
      _       -> Nothing
  where
    name = T.pack (takeFileName path)
    ext  = T.pack (takeExtension path)
    stem = T.take (T.length name - T.length ext) name
