{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the image-preview allowlist ('Seal.Gateway.MediaType').
--
-- The allowlist is the single security gate deciding which files may be
-- served with a renderable @Content-Type@ instead of the hardened
-- @octet-stream@ default, so every dangerous case gets an explicit
-- negative test.
module Seal.Gateway.MediaTypeSpec (spec) where

import Test.Hspec

import Data.Text qualified as T

import Seal.Gateway.MediaType
  ( InlineMediaType (..), inlineMediaTypeFor, svgHardeningCsp )

spec :: Spec
spec = describe "Seal.Gateway.MediaType" $ do
  describe "inlineMediaTypeFor — allowlisted raster images" $ do
    it "types PNG as image/png" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/photo.png")
        `shouldBe` Just "image/png"

    it "types JPEG as image/jpeg for both .jpg and .jpeg" $ do
      fmap imtContentType (inlineMediaTypeFor "/home/u/photo.jpg") `shouldBe` Just "image/jpeg"
      fmap imtContentType (inlineMediaTypeFor "/home/u/photo.jpeg") `shouldBe` Just "image/jpeg"

    it "types GIF, WebP, AVIF, BMP and ICO" $ do
      fmap imtContentType (inlineMediaTypeFor "a.gif") `shouldBe` Just "image/gif"
      fmap imtContentType (inlineMediaTypeFor "a.webp") `shouldBe` Just "image/webp"
      fmap imtContentType (inlineMediaTypeFor "a.avif") `shouldBe` Just "image/avif"
      fmap imtContentType (inlineMediaTypeFor "a.bmp") `shouldBe` Just "image/bmp"
      fmap imtContentType (inlineMediaTypeFor "a.ico") `shouldBe` Just "image/x-icon"

  describe "inlineMediaTypeFor — case insensitivity" $ do
    it "matches an upper-case extension" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/PHOTO.JPG")
        `shouldBe` Just "image/jpeg"

    it "matches a mixed-case extension" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/Photo.PnG")
        `shouldBe` Just "image/png"

  describe "inlineMediaTypeFor — SVG is allowed, typed as a document" $ do
    -- SVG is scriptable, but it is allowed precisely because the response
    -- also carries 'svgHardeningCsp'. The type must be the SVG MIME type,
    -- not a raster one: the browser needs to know it is a document to
    -- render it at all.
    it "types .svg as image/svg+xml" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/logo.svg")
        `shouldBe` Just "image/svg+xml"

    it "matches an upper-case .SVG" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/LOGO.SVG")
        `shouldBe` Just "image/svg+xml"

    -- .svgz is gzip-compressed SVG. It cannot be served uncompressed under
    -- image/svg+xml, and adding Content-Encoding negotiation is out of
    -- scope, so it stays on the attachment path.
    it "refuses .svgz (compressed; needs Content-Encoding)" $
      inlineMediaTypeFor "/home/u/logo.svgz" `shouldBe` Nothing

  describe "inlineMediaTypeFor — non-image and executable formats are refused" $ do
    it "refuses HTML, which would execute script if rendered" $ do
      inlineMediaTypeFor "/home/u/page.html" `shouldBe` Nothing
      inlineMediaTypeFor "/home/u/page.htm" `shouldBe` Nothing
      inlineMediaTypeFor "/home/u/page.xhtml" `shouldBe` Nothing

    it "refuses script and document formats" $ do
      inlineMediaTypeFor "/home/u/app.js" `shouldBe` Nothing
      inlineMediaTypeFor "/home/u/doc.pdf" `shouldBe` Nothing

    it "refuses plain text and source files" $ do
      inlineMediaTypeFor "/home/u/notes.txt" `shouldBe` Nothing
      inlineMediaTypeFor "/home/u/Main.hs" `shouldBe` Nothing

    it "refuses a file with no extension" $
      inlineMediaTypeFor "/home/u/LICENSE" `shouldBe` Nothing

    it "refuses a dotfile whose whole name starts with a dot" $
      inlineMediaTypeFor "/home/u/.png" `shouldBe` Nothing

  describe "inlineMediaTypeFor — extension matching is on the final suffix only" $ do
    -- `takeExtension` looks at the last suffix, so a compound name resolves
    -- by its real type rather than an earlier decoy.
    it "matches by the final suffix" $
      fmap imtContentType (inlineMediaTypeFor "/home/u/archive.tar.png")
        `shouldBe` Just "image/png"

    it "does not match when an image name is only a prefix" $
      inlineMediaTypeFor "/home/u/photo.png.exe" `shouldBe` Nothing

  describe "inlineMediaTypeFor — directory-ish input" $ do
    it "refuses an empty path" $ inlineMediaTypeFor "" `shouldBe` Nothing

  -- The CSP is what makes serving an SVG safe: the file remains reachable as
  -- a document at its own URL, where scripts WOULD run without it. These
  -- assertions pin the directives that carry that weight.
  describe "svgHardeningCsp" $ do
    let csp = svgHardeningCsp
        directives = T.splitOn "; " csp

    it "sandboxes the document with no allow-* tokens" $ do
      -- `sandbox` with no tokens is the maximal restriction. `allow-scripts`
      -- here would hand back the key and is the one token that must never
      -- appear.
      directives `shouldSatisfy` elem "sandbox"
      csp `shouldNotSatisfy` T.isInfixOf "allow-scripts"
      csp `shouldNotSatisfy` T.isInfixOf "allow-same-origin"

    it "denies script execution" $
      directives `shouldSatisfy` elem "script-src 'none'"

    it "denies plugin re-embedding" $
      directives `shouldSatisfy` elem "object-src 'none'"

    it "denies all unlisted fetches by default" $
      directives `shouldSatisfy` elem "default-src 'none'"

    it "denies form submission and base-uri rewriting" $ do
      directives `shouldSatisfy` elem "form-action 'none'"
      directives `shouldSatisfy` elem "base-uri 'none'"

    -- This one is required for correct RENDERING, not security: without it
    -- `default-src 'none'` drops the SVG's own <style> block and a
    -- class-styled drawing renders with default black fills.
    it "permits inline styles so styled SVGs render faithfully" $
      directives `shouldSatisfy` elem "style-src 'unsafe-inline'"

    it "permits only inline data-URI images" $
      directives `shouldSatisfy` elem "img-src data:"

    it "is a single header value (newlines would be stripped or split)" $
      csp `shouldNotSatisfy` T.isInfixOf "\n"
