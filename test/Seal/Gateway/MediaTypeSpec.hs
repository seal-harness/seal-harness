{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the image-preview allowlist ('Seal.Gateway.MediaType').
--
-- The allowlist is the single security gate deciding which files may be
-- served with a renderable @Content-Type@ instead of the hardened
-- @octet-stream@ default, so every dangerous case gets an explicit
-- negative test.
module Seal.Gateway.MediaTypeSpec (spec) where

import Test.Hspec

import Seal.Gateway.MediaType (InlineMediaType (..), inlineMediaTypeFor)

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

  describe "inlineMediaTypeFor — SVG is refused" $ do
    -- SVG is a scriptable document format: served inline and navigated to
    -- directly, it executes script in the gateway's authenticated origin.
    -- It must fall through to the hardened download path.
    it "refuses .svg" $
      inlineMediaTypeFor "/home/u/logo.svg" `shouldBe` Nothing

    it "refuses .svgz" $
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
