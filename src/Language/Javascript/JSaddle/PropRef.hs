-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.PropRef
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- | Implements a reference to a property
--
-----------------------------------------------------------------------------

module Language.Javascript.JSaddle.PropRef (
    JSPropRef(..)
) where

import Language.Javascript.JSaddle.Types
       (JSStringRef, Object, Index)

-- | A reference to a property.
--   Implemented as a reference to an object and something to find the property.
data JSPropRef = JSPropRef      Object JSStringRef -- ^ Object and property name.
               | JSPropIndexRef Object Index       -- ^ Object and property index.


