{-# LANGUAGE FlexibleContexts #-}
-- | Aeson encoding helpers shared across Seal's JSON serializations.
--
-- This module is now a thin re-export from 'Seal.Gateway.Types.AesonUtils'
-- (the canonical home in the 'seal-gateway-types' library stanza).
module Seal.Util.AesonUtils
  ( -- * Original lensy helpers (underscore-prefixed convention)
    lensyLenToJSON
  , lensyLenParseJSON
  , lensyLenOptions
  , lensySnakeToJSON
  , lensySnakeParseJSON
  , lensySnakeOptions
  , lensyToJSON
  , lensyParseJSON
  , lensyOptions
  , lensyKebabToJSON
  , lensyKebabParseJSON
  , lensyKebabOptions
  , lensyFieldNameToNiceJson
  , lensyFieldNameToSnakeJson
  , lensyFieldNameToKebabJson
  , lensyConstructorToNiceJson
  , lensyLenConstructorToNiceJson
    -- * Strip-leading-lowercase-prefix helpers (Seal's convention)
  , stripPrefixToJSON
  , stripPrefixParseJSON
  , stripPrefixOptions
  , stripLensPrefixCamel
  ) where

import Seal.Gateway.Types.AesonUtils